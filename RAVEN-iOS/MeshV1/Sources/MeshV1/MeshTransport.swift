// v1-compliant BLE transport (CBPeripheralManager + CBCentralManager).
// Mirrors `BleMeshEngine.kt` on Android. Both ports advertise the same
// service UUID, expose the same characteristics, and exchange the same
// chunked wire format.
//
// What this owns:
//   • Peripheral role: advertise service + serve characteristic writes/notifies.
//   • Central role:    scan, connect, MTU exchange, write + notification subscribe.
//   • Reassembly:      per-(sender, messageHash) buffer with timed GC.
//   • Peer count:      exposed as a Combine `Published` so SwiftUI can bind.
//
// What it does NOT own:
//   • Signing / verification — caller invokes `MeshSigner` before send,
//     verifies after `incoming` emits.
//   • Dedup — caller maintains the dedup table on top of `incoming`.
//   • Foreground state restoration — Phase 4 polish.
//
// Concurrency: callbacks dispatch off the CoreBluetooth queue; mutations
// to `connectedPeripherals`, `incomingCentrals`, `reassembler`, and the
// published peer count are serialized via a private DispatchQueue. The
// `incoming` publisher emits on the same queue.
import Combine
import CoreBluetooth
import Foundation

/// Public surface — UI/router consumes this, not the impl class.
public protocol MeshTransport: AnyObject {
    /// Hot stream of reassembled inbound JSON payloads + the device-id we
    /// derived from the advertised local name.
    var incoming: AnyPublisher<InboundPayload, Never> { get }

    /// Live count of currently-connected mesh peers (server + client roles).
    var peerCountPublisher: AnyPublisher<Int, Never> { get }

    /// Start advertising + scanning. Idempotent.
    func start(localFingerprint: String)

    /// Stop both roles and release the radio.
    func stop()

    /// Best-effort write to every connected peer. Caller pre-chunks via
    /// `Chunking.encodeUnchunked` / `encodeChunked`.
    func broadcast(_ packet: Data)

    /// Periodic housekeeping — drop stale chunk-reassembly buffers.
    func reassemblerTick()
}

public struct InboundPayload {
    public let senderDeviceId: String
    public let json: Data

    public init(senderDeviceId: String, json: Data) {
        self.senderDeviceId = senderDeviceId
        self.json = json
    }
}

public final class CoreBluetoothMeshTransport: NSObject, MeshTransport {

    // MARK: Public publishers

    public var incoming: AnyPublisher<InboundPayload, Never> { incomingSubject.eraseToAnyPublisher() }
    public var peerCountPublisher: AnyPublisher<Int, Never> { peerCountSubject.eraseToAnyPublisher() }

    // MARK: Private state (all accessed on `queue`)

    private let queue = DispatchQueue(label: "app.raven.mesh.transport")
    private lazy var central = CBCentralManager(delegate: self, queue: queue, options: [
        CBCentralManagerOptionRestoreIdentifierKey: MeshConstants.centralRestoreId,
    ])
    private lazy var peripheral = CBPeripheralManager(delegate: self, queue: queue, options: [
        CBPeripheralManagerOptionRestoreIdentifierKey: MeshConstants.peripheralRestoreId,
    ])

    private var connectedPeripherals: [UUID: CBPeripheral] = [:]
    private var deviceIdByPeripheral: [UUID: String] = [:]
    private var incomingCentrals: Set<UUID> = []
    private var advertising = false
    private var scanning = false
    private var localName: String?
    private var txRxCharacteristic: CBMutableCharacteristic?
    private let reassembler = ChunkReassembler()

    private let incomingSubject = PassthroughSubject<InboundPayload, Never>()
    private let peerCountSubject = CurrentValueSubject<Int, Never>(0)

    public override init() {
        super.init()
        // Force lazy init so the central/peripheral state callbacks fire
        // before the caller calls `start`.
        _ = central
        _ = peripheral
    }

    // MARK: Lifecycle

    public func start(localFingerprint: String) {
        queue.async { [self] in
            localName = MeshConstants.advertisementNamePrefix + String(localFingerprint.prefix(8))
            startGattServerIfPossible()
            startAdvertisingIfPossible()
            startScanningIfPossible()
        }
    }

    public func stop() {
        queue.async { [self] in
            stopAdvertising()
            stopScanning()
            for (_, p) in connectedPeripherals { central.cancelPeripheralConnection(p) }
            connectedPeripherals.removeAll()
            deviceIdByPeripheral.removeAll()
            incomingCentrals.removeAll()
            peripheral.removeAllServices()
            txRxCharacteristic = nil
            peerCountSubject.send(0)
        }
    }

    public func broadcast(_ packet: Data) {
        queue.async { [self] in
            // Peripheral role: notify all subscribed centrals.
            if let txRx = txRxCharacteristic {
                _ = peripheral.updateValue(packet, for: txRx, onSubscribedCentrals: nil)
            }
            // Central role: writeWithoutResponse to every connected peripheral.
            for (_, p) in connectedPeripherals {
                guard let service = p.services?.first(where: { $0.uuid.uuidString.lowercased() == MeshConstants.serviceUUID.uuidString.lowercased() }),
                      let char = service.characteristics?.first(where: { $0.uuid.uuidString.lowercased() == MeshConstants.characteristicMessageTxRx.uuidString.lowercased() }) else { continue }
                let type: CBCharacteristicWriteType = char.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
                p.writeValue(packet, for: char, type: type)
            }
        }
    }

    public func reassemblerTick() { queue.async { [self] in reassembler.tick() } }

    // MARK: Peripheral helpers

    private func startGattServerIfPossible() {
        guard peripheral.state == .poweredOn, txRxCharacteristic == nil else { return }
        let txRx = CBMutableCharacteristic(
            type: CBUUID(nsuuid: MeshConstants.characteristicMessageTxRx),
            properties: [.notify, .write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable, .readable],
        )
        let info = CBMutableCharacteristic(
            type: CBUUID(nsuuid: MeshConstants.characteristicDeviceInfo),
            properties: [.read],
            value: Data((localName ?? "RAVEN").utf8),
            permissions: [.readable],
        )
        let service = CBMutableService(type: CBUUID(nsuuid: MeshConstants.serviceUUID), primary: true)
        service.characteristics = [txRx, info]
        peripheral.add(service)
        txRxCharacteristic = txRx
    }

    private func startAdvertisingIfPossible() {
        guard peripheral.state == .poweredOn, !advertising else { return }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(nsuuid: MeshConstants.serviceUUID)],
            CBAdvertisementDataLocalNameKey: localName ?? "RAVEN",
        ])
        advertising = true
    }

    private func stopAdvertising() {
        guard advertising else { return }
        peripheral.stopAdvertising()
        advertising = false
    }

    // MARK: Central helpers

    private func startScanningIfPossible() {
        guard central.state == .poweredOn, !scanning else { return }
        central.scanForPeripherals(
            withServices: [CBUUID(nsuuid: MeshConstants.serviceUUID)],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false],
        )
        scanning = true
    }

    private func stopScanning() {
        guard scanning else { return }
        central.stopScan()
        scanning = false
    }

    // MARK: Inbound

    fileprivate func ingest(senderDeviceId: String, packet: Data) {
        guard !packet.isEmpty else { return }
        switch Chunking.decode(packet) {
        case .unchunked(let json):
            incomingSubject.send(InboundPayload(senderDeviceId: senderDeviceId, json: json))
        case .chunk(let header, let payload):
            if let assembled = reassembler.accept(senderDeviceId: senderDeviceId, header: header, payload: payload) {
                incomingSubject.send(InboundPayload(senderDeviceId: senderDeviceId, json: assembled))
            }
        }
    }

    fileprivate func recomputePeerCount() {
        peerCountSubject.send(connectedPeripherals.count + incomingCentrals.count)
    }
}

// MARK: - CBCentralManagerDelegate

extension CoreBluetoothMeshTransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        queue.async { [self] in
            if central.state == .poweredOn { startScanningIfPossible() }
            else { scanning = false }
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard name.hasPrefix(MeshConstants.advertisementNamePrefix) else { return }
        let derivedDeviceId = String(name.dropFirst(MeshConstants.advertisementNamePrefix.count))
        queue.async { [self] in
            guard connectedPeripherals[peripheral.identifier] == nil else { return }
            connectedPeripherals[peripheral.identifier] = peripheral
            deviceIdByPeripheral[peripheral.identifier] = derivedDeviceId
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        queue.async { [self] in
            recomputePeerCount()
            peripheral.discoverServices([CBUUID(nsuuid: MeshConstants.serviceUUID)])
        }
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        queue.async { [self] in
            connectedPeripherals.removeValue(forKey: peripheral.identifier)
            deviceIdByPeripheral.removeValue(forKey: peripheral.identifier)
            recomputePeerCount()
        }
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // Phase 4 polish: restore subscribed peripherals from the dict. Out
        // of scope for the scaffold — left as the integration step.
    }
}

// MARK: - CBPeripheralDelegate (central role consuming a remote peripheral)

extension CoreBluetoothMeshTransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid.uuidString.lowercased() == MeshConstants.serviceUUID.uuidString.lowercased() }) else { return }
        peripheral.discoverCharacteristics([CBUUID(nsuuid: MeshConstants.characteristicMessageTxRx)], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let txRx = service.characteristics?.first(where: { $0.uuid.uuidString.lowercased() == MeshConstants.characteristicMessageTxRx.uuidString.lowercased() }) else { return }
        peripheral.setNotifyValue(true, for: txRx)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid.uuidString.lowercased() == MeshConstants.characteristicMessageTxRx.uuidString.lowercased(),
              let value = characteristic.value else { return }
        queue.async { [self] in
            let device = deviceIdByPeripheral[peripheral.identifier] ?? peripheral.identifier.uuidString
            ingest(senderDeviceId: device, packet: value)
        }
    }
}

// MARK: - CBPeripheralManagerDelegate (peripheral role)

extension CoreBluetoothMeshTransport: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        queue.async { [self] in
            if peripheral.state == .poweredOn {
                startGattServerIfPossible()
                startAdvertisingIfPossible()
            } else {
                advertising = false
            }
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        queue.async { [self] in
            incomingCentrals.insert(central.identifier)
            recomputePeerCount()
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        queue.async { [self] in
            incomingCentrals.remove(central.identifier)
            recomputePeerCount()
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard request.characteristic.uuid.uuidString.lowercased() == MeshConstants.characteristicMessageTxRx.uuidString.lowercased(),
                  let value = request.value else { continue }
            queue.async { [self] in
                let device = request.central.identifier.uuidString // best we have from this role
                ingest(senderDeviceId: device, packet: value)
            }
            peripheral.respond(to: request, withResult: .success)
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        // Phase 4 polish: restore services + subscribers; defer.
    }
}
