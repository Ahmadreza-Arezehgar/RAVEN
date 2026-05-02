// BleEngine.cs
//
// Windows BLE engine — runs both as central (scan + connect to peers) and
// peripheral (advertise + serve GATT) so a Windows machine is a FULL mesh
// peer, not a client-only.
//
// Mirror of `ios-native/RAVEN/RAVEN/Core/Mesh/BLEMeshEngine.swift`.
//
// IMPLEMENTATION STATUS:
//   - Central (scan + receive notifications): implemented end-to-end via WinRT.
//   - Peripheral (advertise + GATT server): implemented via GattServiceProvider.
//   - LIMITATION: Windows does not let an app override the BLE LocalName per
//     advertisement easily; we publish the device fingerprint via ServiceData
//     instead, in the manufacturer-data slot. The iOS LocalName parser at
//     BLEMeshEngine.swift:2447 needs a small extension to also read the
//     manufacturer-data slot — see TODO in iOS code.
//   - This file requires net8.0-windows10.0.19041.0 to compile (uses
//     Windows.Devices.Bluetooth namespaces). The unit-test project links
//     ChunkFramer/MeshEnvelope/MeshCrypto separately so tests stay
//     cross-platform.

#if WINDOWS

using System;
using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Logging;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Storage.Streams;
using RAVEN.Windows.Crypto;

namespace RAVEN.Windows.Mesh;

public sealed record DiscoveredPeer(string Fingerprint, ulong BluetoothAddress, DateTime LastSeenUtc);
public sealed record InboundPacketEvent(string SenderFingerprint, byte[] Payload);

public sealed class BleEngine : IAsyncDisposable
{
    private readonly ILogger<BleEngine> _log;
    private readonly string _localFingerprint;
    private readonly byte[] _localFingerprintBytes;
    private readonly ChunkFramer.Reassembler _reassembler = new();

    // Peers we've seen advertising.
    private readonly ConcurrentDictionary<ulong, DiscoveredPeer> _peers = new();

    // Active GATT connections (we are central).
    private readonly ConcurrentDictionary<ulong, ConnectedPeer> _connectedAsCentral = new();

    // Subscribed centrals (devices that connected to OUR peripheral).
    private readonly ConcurrentDictionary<ulong, GattSubscribedClient> _subscribedAsPeripheral = new();

    private BluetoothLEAdvertisementWatcher? _watcher;
    private GattServiceProvider? _serviceProvider;
    private GattLocalCharacteristic? _messageCharacteristic;
    private GattLocalCharacteristic? _deviceInfoCharacteristic;

    private CancellationTokenSource? _cts;
    private bool _started;

    public BleEngine(ILogger<BleEngine> log, byte[] localEd25519PublicKey)
    {
        _log = log;
        _localFingerprint = MeshCrypto.ComputeFingerprint(localEd25519PublicKey);
        _localFingerprintBytes = System.Text.Encoding.UTF8.GetBytes(_localFingerprint);
    }

    public string LocalFingerprint => _localFingerprint;
    public IReadOnlyCollection<DiscoveredPeer> Peers => _peers.Values.ToArray();

    public event Action<InboundPacketEvent>? OnInboundPacket;
    public event Action<DiscoveredPeer>? OnPeerDiscovered;
    public event Action<string>? OnPeerLost;

    // ─── Lifecycle ───────────────────────────────────────────────────

    public async Task StartAsync(CancellationToken ct = default)
    {
        if (_started) return;
        _started = true;
        _cts = CancellationTokenSource.CreateLinkedTokenSource(ct);

        await StartPeripheralAsync().ConfigureAwait(false);
        StartCentral();
        StartPeriodicGc();

        _log.LogInformation("BleEngine started. Fingerprint={Fp}", _localFingerprint);
    }

    public async Task StopAsync()
    {
        if (!_started) return;
        _started = false;
        _cts?.Cancel();

        StopCentral();
        await StopPeripheralAsync().ConfigureAwait(false);

        foreach (var (_, peer) in _connectedAsCentral)
        {
            peer.Dispose();
        }
        _connectedAsCentral.Clear();

        _log.LogInformation("BleEngine stopped.");
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync().ConfigureAwait(false);
        _cts?.Dispose();
    }

    // ─── Peripheral (advertise + GATT server) ────────────────────────

    private async Task StartPeripheralAsync()
    {
        var serviceResult = await GattServiceProvider.CreateAsync(MeshConstants.ServiceUuid);
        if (serviceResult.Error != BluetoothError.Success)
        {
            _log.LogError("GattServiceProvider.CreateAsync failed: {Err}", serviceResult.Error);
            return;
        }
        _serviceProvider = serviceResult.ServiceProvider;

        // Message characteristic: notify + write + writeWithoutResponse
        var msgParams = new GattLocalCharacteristicParameters
        {
            CharacteristicProperties = GattCharacteristicProperties.Notify
                                       | GattCharacteristicProperties.Write
                                       | GattCharacteristicProperties.WriteWithoutResponse,
            ReadProtectionLevel = GattProtectionLevel.Plain,
            WriteProtectionLevel = GattProtectionLevel.Plain,
            UserDescription = "RAVEN Mesh Message",
        };
        var msgResult = await _serviceProvider.Service.CreateCharacteristicAsync(
            MeshConstants.MessageCharacteristicUuid, msgParams);
        if (msgResult.Error != BluetoothError.Success)
        {
            _log.LogError("Create message characteristic failed: {Err}", msgResult.Error);
            return;
        }
        _messageCharacteristic = msgResult.Characteristic;
        _messageCharacteristic.WriteRequested += OnIncomingWrite;
        _messageCharacteristic.SubscribedClientsChanged += OnSubscribedClientsChanged;

        // DeviceInfo characteristic: read = our fingerprint
        var infoParams = new GattLocalCharacteristicParameters
        {
            CharacteristicProperties = GattCharacteristicProperties.Read,
            ReadProtectionLevel = GattProtectionLevel.Plain,
            UserDescription = "RAVEN Device Fingerprint",
            StaticValue = ToBuffer(_localFingerprintBytes),
        };
        var infoResult = await _serviceProvider.Service.CreateCharacteristicAsync(
            MeshConstants.DeviceInfoCharacteristicUuid, infoParams);
        if (infoResult.Error != BluetoothError.Success)
        {
            _log.LogError("Create device-info characteristic failed: {Err}", infoResult.Error);
        }
        else
        {
            _deviceInfoCharacteristic = infoResult.Characteristic;
        }

        // Advertise. Embed fingerprint in ServiceData so iOS can parse it
        // (the LocalName approach iOS uses isn't easily settable from a
        // per-app GattServiceProvider on Windows).
        var advParams = new GattServiceProviderAdvertisingParameters
        {
            IsConnectable = true,
            IsDiscoverable = true,
            // The 8-char fingerprint prefix goes in service data so peers can
            // identify us before we open a GATT connection. iOS parser may
            // need a small extension; see file header.
            ServiceData = ToBuffer(System.Text.Encoding.UTF8.GetBytes(_localFingerprint[..8].Replace("-", ""))),
        };
        _serviceProvider.StartAdvertising(advParams);
        _log.LogInformation("Peripheral advertising started.");
    }

    private async Task StopPeripheralAsync()
    {
        if (_serviceProvider is null) return;
        try { _serviceProvider.StopAdvertising(); } catch { }
        if (_messageCharacteristic is not null)
        {
            _messageCharacteristic.WriteRequested -= OnIncomingWrite;
            _messageCharacteristic.SubscribedClientsChanged -= OnSubscribedClientsChanged;
        }
        _serviceProvider = null;
        _messageCharacteristic = null;
        _deviceInfoCharacteristic = null;
        await Task.CompletedTask;
    }

    private async void OnIncomingWrite(GattLocalCharacteristic sender, GattWriteRequestedEventArgs args)
    {
        try
        {
            using var deferral = args.GetDeferral();
            var request = await args.GetRequestAsync();
            if (request is null) return;

            var packet = FromBuffer(request.Value);

            // We don't know the sender's fingerprint at the BLE layer alone —
            // the address gives us a lookup key; if we've seen them advertising
            // we have the fingerprint, otherwise use the address as fallback.
            var senderFp = ResolveFingerprint(request.Session?.DeviceId.Id ?? "unknown");
            HandleInboundPacket(senderFp, packet);

            if (request.Option == GattWriteOption.WriteWithResponse)
                request.Respond();
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "OnIncomingWrite failed");
        }
    }

    private void OnSubscribedClientsChanged(GattLocalCharacteristic sender, object args)
    {
        if (_messageCharacteristic is null) return;
        var current = _messageCharacteristic.SubscribedClients;
        _log.LogDebug("Subscribed clients: {Count}", current.Count);
        // We could index them per address here for per-peer notifies.
    }

    // ─── Central (scan + connect) ────────────────────────────────────

    private void StartCentral()
    {
        _watcher = new BluetoothLEAdvertisementWatcher
        {
            ScanningMode = BluetoothLEScanningMode.Active,
        };
        _watcher.AdvertisementFilter.Advertisement.ServiceUuids.Add(MeshConstants.ServiceUuid);
        _watcher.Received += OnAdvertisementReceived;
        _watcher.Stopped += (_, _) => _log.LogWarning("BLE watcher stopped");
        _watcher.Start();
    }

    private void StopCentral()
    {
        if (_watcher is null) return;
        try { _watcher.Stop(); } catch { }
        _watcher.Received -= OnAdvertisementReceived;
        _watcher = null;
    }

    private async void OnAdvertisementReceived(BluetoothLEAdvertisementWatcher sender, BluetoothLEAdvertisementReceivedEventArgs args)
    {
        try
        {
            // Extract fingerprint prefix from ServiceData (our own format) or
            // LocalName (iOS format).
            var fingerprintPrefix = ExtractFingerprintFromAd(args.Advertisement);
            if (string.IsNullOrEmpty(fingerprintPrefix)) return;

            var address = args.BluetoothAddress;
            var peer = new DiscoveredPeer(fingerprintPrefix, address, DateTime.UtcNow);
            var isNew = _peers.TryAdd(address, peer);
            if (!isNew)
            {
                _peers[address] = peer with { LastSeenUtc = DateTime.UtcNow };
                return;
            }

            OnPeerDiscovered?.Invoke(peer);

            // Connect & subscribe to notifications.
            await ConnectAndSubscribeAsync(address, fingerprintPrefix).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "OnAdvertisementReceived failed");
        }
    }

    private async Task ConnectAndSubscribeAsync(ulong address, string peerFingerprint)
    {
        try
        {
            var device = await BluetoothLEDevice.FromBluetoothAddressAsync(address);
            if (device is null) return;

            var svcResult = await device.GetGattServicesForUuidAsync(MeshConstants.ServiceUuid, BluetoothCacheMode.Uncached);
            if (svcResult.Status != GattCommunicationStatus.Success || svcResult.Services.Count == 0)
            {
                _log.LogWarning("No RAVEN service on peer {Fp}", peerFingerprint);
                return;
            }
            var svc = svcResult.Services[0];
            var charResult = await svc.GetCharacteristicsForUuidAsync(MeshConstants.MessageCharacteristicUuid, BluetoothCacheMode.Uncached);
            if (charResult.Status != GattCommunicationStatus.Success || charResult.Characteristics.Count == 0)
            {
                _log.LogWarning("No message char on peer {Fp}", peerFingerprint);
                return;
            }
            var ch = charResult.Characteristics[0];

            // Subscribe to notifications.
            var cccd = await ch.WriteClientCharacteristicConfigurationDescriptorAsync(
                GattClientCharacteristicConfigurationDescriptorValue.Notify);
            if (cccd != GattCommunicationStatus.Success)
            {
                _log.LogWarning("CCCD write failed on peer {Fp}", peerFingerprint);
                return;
            }
            ch.ValueChanged += (s, e) =>
            {
                var bytes = FromBuffer(e.CharacteristicValue);
                HandleInboundPacket(peerFingerprint, bytes);
            };

            _connectedAsCentral[address] = new ConnectedPeer(device, ch, peerFingerprint);
            _log.LogInformation("Connected to peer {Fp}", peerFingerprint);
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "ConnectAndSubscribeAsync failed for {Fp}", peerFingerprint);
        }
    }

    private static string? ExtractFingerprintFromAd(BluetoothLEAdvertisement ad)
    {
        // Prefer LocalName (iOS format: "RAVEN-XXXXXXXX")
        if (!string.IsNullOrEmpty(ad.LocalName) && ad.LocalName.StartsWith(MeshConstants.AdvertisementLocalNamePrefix))
        {
            return ad.LocalName[MeshConstants.AdvertisementLocalNamePrefix.Length..];
        }
        // Fallback: ServiceData (our Windows format) — manufacturer/raw section.
        // The Windows GattServiceProviderAdvertisingParameters places it in the
        // raw service-data slot scoped under the service UUID.
        foreach (var section in ad.DataSections)
        {
            if (section.DataType == 0x16) // Service Data - 16-bit UUID; we tunnel here for pre-iOS-26 compat
            {
                var bytes = new byte[section.Data.Length];
                using var reader = DataReader.FromBuffer(section.Data);
                reader.ReadBytes(bytes);
                return System.Text.Encoding.UTF8.GetString(bytes);
            }
        }
        return null;
    }

    private string ResolveFingerprint(string deviceId)
    {
        // BluetoothAddress from deviceId if possible.
        if (ulong.TryParse(deviceId.Replace(":", "").Replace("BluetoothLE#", ""),
                System.Globalization.NumberStyles.HexNumber, null, out var addr)
            && _peers.TryGetValue(addr, out var peer))
        {
            return peer.Fingerprint;
        }
        return "unknown";
    }

    // ─── Sending ─────────────────────────────────────────────────────

    public async Task SendToPeerAsync(string peerFingerprint, byte[] payload, CancellationToken ct = default)
    {
        var connected = _connectedAsCentral.Values.FirstOrDefault(p => p.Fingerprint == peerFingerprint);
        if (connected is null)
        {
            _log.LogDebug("No connection to peer {Fp}; dropping send", peerFingerprint);
            return;
        }

        // Compute MTU. Windows: GattCharacteristic.Service.MaxPduSize (PDU) - 3 (ATT header).
        var maxPdu = (int)connected.Characteristic.Service.MaxPduSize;
        var maxPacket = Math.Max(MeshConstants.MinChunkPayload + MeshConstants.ChunkHeaderSize + 1,
                                  maxPdu - 3);

        var packets = ChunkFramer.EncodeForBle(payload, maxPacket);
        for (int i = 0; i < packets.Count; i++)
        {
            using var writer = new DataWriter();
            writer.WriteBytes(packets[i]);
            var status = await connected.Characteristic.WriteValueAsync(writer.DetachBuffer(), GattWriteOption.WriteWithoutResponse);
            if (status != GattCommunicationStatus.Success)
            {
                _log.LogWarning("Chunk {I}/{N} write failed to {Fp}: {Status}", i + 1, packets.Count, peerFingerprint, status);
            }
            if (i < packets.Count - 1) await Task.Delay(MeshConstants.InterChunkDelayMs, ct).ConfigureAwait(false);
        }
    }

    public async Task BroadcastAsync(byte[] payload, CancellationToken ct = default)
    {
        // Send via every central connection AND via peripheral notify to subscribed centrals.
        var tasks = new List<Task>();
        foreach (var peer in _connectedAsCentral.Values)
        {
            tasks.Add(SendToPeerAsync(peer.Fingerprint, payload, ct));
        }

        // Notify subscribed clients (we are peripheral).
        if (_messageCharacteristic is not null && _messageCharacteristic.SubscribedClients.Count > 0)
        {
            // Subscribed clients are notified individually; chunking based on the
            // peripheral's own MTU.
            var maxPdu = (int)_messageCharacteristic.Service.MaxPduSize;
            var maxPacket = Math.Max(MeshConstants.MinChunkPayload + MeshConstants.ChunkHeaderSize + 1, maxPdu - 3);
            var packets = ChunkFramer.EncodeForBle(payload, maxPacket);
            foreach (var packet in packets)
            {
                using var writer = new DataWriter();
                writer.WriteBytes(packet);
                tasks.Add(_messageCharacteristic.NotifyValueAsync(writer.DetachBuffer()).AsTask());
                await Task.Delay(MeshConstants.InterChunkDelayMs, ct).ConfigureAwait(false);
            }
        }

        await Task.WhenAll(tasks).ConfigureAwait(false);
    }

    // ─── Inbound + GC ────────────────────────────────────────────────

    internal void HandleInboundPacket(string senderFingerprint, byte[] packet)
    {
        try
        {
            var assembled = _reassembler.Feed(senderFingerprint, packet);
            if (assembled is not null)
            {
                OnInboundPacket?.Invoke(new InboundPacketEvent(senderFingerprint, assembled));
            }
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Failed to handle inbound packet from {Sender}", senderFingerprint);
        }
    }

    private void StartPeriodicGc()
    {
        _ = Task.Run(async () =>
        {
            while (_cts is not null && !_cts.IsCancellationRequested)
            {
                _reassembler.GcStale();
                EvictStalePeers();
                try { await Task.Delay(MeshConstants.PeriodicCleanupInterval, _cts.Token); }
                catch (OperationCanceledException) { return; }
            }
        });
    }

    private void EvictStalePeers()
    {
        var cutoff = DateTime.UtcNow - TimeSpan.FromSeconds(60);
        foreach (var (addr, peer) in _peers)
        {
            if (peer.LastSeenUtc < cutoff)
            {
                if (_peers.TryRemove(addr, out _))
                    OnPeerLost?.Invoke(peer.Fingerprint);
                if (_connectedAsCentral.TryRemove(addr, out var conn))
                    conn.Dispose();
            }
        }
    }

    // ─── Helpers ─────────────────────────────────────────────────────

    private static IBuffer ToBuffer(byte[] bytes)
    {
        using var w = new DataWriter();
        w.WriteBytes(bytes);
        return w.DetachBuffer();
    }

    private static byte[] FromBuffer(IBuffer buf)
    {
        var bytes = new byte[buf.Length];
        using var r = DataReader.FromBuffer(buf);
        r.ReadBytes(bytes);
        return bytes;
    }

    private sealed class ConnectedPeer : IDisposable
    {
        public BluetoothLEDevice Device { get; }
        public GattCharacteristic Characteristic { get; }
        public string Fingerprint { get; }

        public ConnectedPeer(BluetoothLEDevice device, GattCharacteristic ch, string fingerprint)
        {
            Device = device;
            Characteristic = ch;
            Fingerprint = fingerprint;
        }

        public void Dispose()
        {
            try { Device.Dispose(); } catch { }
        }
    }

    private sealed class GattSubscribedClient
    {
        public string Address { get; init; } = string.Empty;
    }
}

#else

// Non-Windows stub so the project compiles for tests on macOS/Linux.
// Enables MessageRouter and the rest of the project to reference BleEngine
// without dragging in WinRT.

using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Logging;
using RAVEN.Windows.Crypto;

namespace RAVEN.Windows.Mesh;

public sealed record DiscoveredPeer(string Fingerprint, ulong BluetoothAddress, DateTime LastSeenUtc);
public sealed record InboundPacketEvent(string SenderFingerprint, byte[] Payload);

public sealed class BleEngine : IAsyncDisposable
{
    private readonly ILogger<BleEngine> _log;
    public string LocalFingerprint { get; }
    public IReadOnlyCollection<DiscoveredPeer> Peers => Array.Empty<DiscoveredPeer>();

    public event Action<InboundPacketEvent>? OnInboundPacket;
    public event Action<DiscoveredPeer>? OnPeerDiscovered;
    public event Action<string>? OnPeerLost;

    public BleEngine(ILogger<BleEngine> log, byte[] localEd25519PublicKey)
    {
        _log = log;
        LocalFingerprint = MeshCrypto.ComputeFingerprint(localEd25519PublicKey);
    }

    public Task StartAsync(CancellationToken ct = default) { _log.LogWarning("BleEngine: non-Windows stub. BLE disabled."); return Task.CompletedTask; }
    public Task StopAsync() => Task.CompletedTask;
    public Task SendToPeerAsync(string peerFingerprint, byte[] payload, CancellationToken ct = default) => Task.CompletedTask;
    public Task BroadcastAsync(byte[] payload, CancellationToken ct = default) => Task.CompletedTask;
    public ValueTask DisposeAsync() => default;

    // Helpers retained for tests — call from MessageRouter unit tests via reflection if needed.
    internal void HandleInboundPacket(string senderFingerprint, byte[] packet) =>
        OnInboundPacket?.Invoke(new InboundPacketEvent(senderFingerprint, packet));
}

#endif
