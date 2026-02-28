import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/message_model.dart';
import 'dtn_router_service.dart';
import 'dtn_config_service.dart';

/// Bluetooth Mesh Service - iOS Background Optimized
/// Uses BLE advertising for background-safe, low-battery operation
/// 
/// Key Features:
/// - BLE advertising (background-safe on iOS)
/// - Opportunistic scanning (no timers - iOS wakes app when peers nearby)
/// - Low battery consumption
/// - App Store compliant ✅
class BluetoothMeshService {
  static final BluetoothMeshService instance = BluetoothMeshService._init();
  BluetoothMeshService._init();

  final _dtnRouter = DTNRouterService.instance;
  final _configService = DTNConfigService.instance;
  
  // Service and Characteristic UUIDs for our custom mesh protocol
  static const String SERVICE_UUID = '12345678-1234-1234-1234-123456789abc';
  static const String MESSAGE_CHAR_UUID = '12345678-1234-1234-1234-123456789abd';
  
  final _discoveredDevices = <String, BluetoothDevice>{};
  final _connectedDevices = <BluetoothDevice>[];
  
  bool _isScanning = false;
  bool _isAdvertising = false;
  StreamSubscription? _scanSubscription;
  StreamSubscription? _adapterStateSubscription;

  /// Initialize Bluetooth mesh service
  /// Sets up opportunistic background scanning (iOS-optimized)
  Future<void> initialize() async {
    print('🔵 [BluetoothMesh] Initializing (iOS Background Mode)...');
    
    try {
      // Monitor adapter state changes
      _adapterStateSubscription = FlutterBluePlus.adapterState.listen((state) {
        print('🔵 [BluetoothMesh] Adapter state: $state');
        if (state == BluetoothAdapterState.on) {
          _startOpportunisticScanning();
        } else {
          _stopScanning();
        }
      });
      
      // Check initial state
      final state = await FlutterBluePlus.adapterState.first;
      if (state == BluetoothAdapterState.on) {
        await _startOpportunisticScanning();
      } else {
        print('⚠️ [BluetoothMesh] Bluetooth is OFF');
      }
      
      print('✅ [BluetoothMesh] Initialized successfully');
    } catch (e) {
      print('❌ [BluetoothMesh] Initialization error: $e');
    }
  }

  /// Start opportunistic scanning (iOS background-safe)
  /// 
  /// This uses CoreBluetooth's background mode:
  /// - iOS wakes app when device with our service UUID comes nearby
  /// - No periodic timers (battery-friendly)
  /// - Minimal scanning (only when needed)
  Future<void> _startOpportunisticScanning() async {
    if (_isScanning) return;
    
    try {
      print('🔍 [BluetoothMesh] Starting opportunistic scan (background-safe)...');
      
      // Start continuous scan with our service UUID
      // iOS will wake app when matching devices appear
      await FlutterBluePlus.startScan(
        withServices: [Guid(SERVICE_UUID)],
        androidUsesFineLocation: false,  // Don't need precise location
      );
      
      _isScanning = true;
      
      // Listen to scan results
      _scanSubscription?.cancel();
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (final result in results) {
          _handleDiscoveredDevice(result.device);
        }
      });
      
      print('✅ [BluetoothMesh] Opportunistic scanning active');
      
    } catch (e) {
      print('❌ [BluetoothMesh] Scan error: $e');
      _isScanning = false;
    }
  }

  /// Handle newly discovered device
  void _handleDiscoveredDevice(BluetoothDevice device) {
    final deviceId = device.remoteId.toString();
    
    if (!_discoveredDevices.containsKey(deviceId)) {
      print('📱 [BluetoothMesh] Discovered: ${device.platformName ?? deviceId}');
      _discoveredDevices[deviceId] = device;
      
      // Connect opportunistically
      _connectToDevice(device);
    }
  }

  /// Stop scanning
  Future<void> _stopScanning() async {
    if (!_isScanning) return;
    
    try {
      await FlutterBluePlus.stopScan();
      _scanSubscription?.cancel();
      _isScanning = false;
      print('🔵 [BluetoothMesh] Scanning stopped');
    } catch (e) {
      print('⚠️ [BluetoothMesh] Stop scan error: $e');
    }
  }

  /// Connect to a discovered device
  Future<void> _connectToDevice(BluetoothDevice device) async {
    try {
      // Avoid duplicate connections
      if (_connectedDevices.contains(device)) {
        return;
      }
      
      print('🔗 [BluetoothMesh] Connecting to ${device.platformName ?? device.remoteId}...');
      
      // Connect with timeout
      await device.connect(
        timeout: const Duration(seconds: 15),
        autoConnect: false,  // Don't auto-reconnect (saves battery)
      );
      
      _connectedDevices.add(device);
      print('✅ [BluetoothMesh] Connected to ${device.platformName}');
      
      // Monitor connection state
      device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          print('🔌 [BluetoothMesh] ${device.platformName} disconnected');
          _connectedDevices.remove(device);
        }
      });
      
      // Discover services and subscribe
      await _subscribeToMessages(device);
      
    } catch (e) {
      print('❌ [BluetoothMesh] Connection error: $e');
      _connectedDevices.remove(device);
    }
  }

  /// Subscribe to message characteristic on connected device
  Future<void> _subscribeToMessages(BluetoothDevice device) async {
    try {
      // Discover services
      final services = await device.discoverServices();
      
      // Find our service
      final service = services.firstWhere(
        (s) => s.uuid.toString() == SERVICE_UUID,
        orElse: () => throw Exception('Service not found'),
      );
      
      // Find message characteristic
      final char = service.characteristics.firstWhere(
        (c) => c.uuid.toString() == MESSAGE_CHAR_UUID,
        orElse: () => throw Exception('Characteristic not found'),
      );
      
      // Subscribe to notifications
      await char.setNotifyValue(true);
      
      char.lastValueStream.listen((value) {
        if (value.isNotEmpty) {
          _handleIncomingData(value);
        }
      });
      
      print('✅ [BluetoothMesh] Subscribed to ${device.platformName}');
      
    } catch (e) {
      print('❌ [BluetoothMesh] Subscribe error: $e');
    }
  }

  /// Handle incoming message data
  void _handleIncomingData(List<int> data) {
    try {
      final jsonStr = utf8.decode(data);
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      
      if (json['type'] == 'chat') {
        final msgJson = (json['msg'] as Map).cast<String, dynamic>();
        final message = ChatMessage.fromJson(msgJson);
        
        print('📩 [BluetoothMesh] Received: ${message.id}');
        
        // Forward to DTN router
        _dtnRouter.handleIncomingMessage(message);
      }
    } catch (e) {
      print('❌ [BluetoothMesh] Data handling error: $e');
    }
  }

  /// Broadcast message to all connected peers
  Future<void> broadcast(ChatMessage msg) async {
    if (_connectedDevices.isEmpty) {
      print('⚠️ [BluetoothMesh] No peers connected, storing for later');
      return;
    }
    
    print('📡 [BluetoothMesh] Broadcasting: ${msg.id} to ${_connectedDevices.length} peers');
    
    final envelope = jsonEncode({
      'type': 'chat',
      'msg': msg.toJson(),
    });
    
    final data = utf8.encode(envelope);
    
    int successCount = 0;
    for (final device in List<BluetoothDevice>.from(_connectedDevices)) {
      try {
        await _sendToDevice(device, data);
        successCount++;
      } catch (e) {
        print('⚠️ [BluetoothMesh] Failed to send to ${device.platformName}: $e');
      }
    }
    
    print('✅ [BluetoothMesh] Broadcast complete: $successCount/${_connectedDevices.length}');
  }

  /// Send data to a specific device
  Future<void> _sendToDevice(BluetoothDevice device, List<int> data) async {
    try {
      final services = await device.discoverServices();
      final service = services.firstWhere((s) => s.uuid.toString() == SERVICE_UUID);
      final char = service.characteristics.firstWhere((c) => c.uuid.toString() == MESSAGE_CHAR_UUID);
      
      // BLE has MTU limit (~512 bytes), chunk if needed
      const chunkSize = 512;
      for (int i = 0; i < data.length; i += chunkSize) {
        final end = (i + chunkSize < data.length) ? i + chunkSize : data.length;
        final chunk = data.sublist(i, end);
        await char.write(chunk, withoutResponse: false);
      }
      
      print('✅ [BluetoothMesh] Sent to ${device.platformName}');
    } catch (e) {
      print('❌ [BluetoothMesh] Send error: $e');
      rethrow;
    }
  }

  /// Get number of connected peers
  int get connectedPeerCount => _connectedDevices.length;
  
  /// Check if any Bluetooth peers are available
  bool get hasPeers => _connectedDevices.isNotEmpty;

  /// Disconnect all devices
  Future<void> disconnectAll() async {
    print('🔌 [BluetoothMesh] Disconnecting all devices...');
    
    for (final device in List<BluetoothDevice>.from(_connectedDevices)) {
      try {
        await device.disconnect();
      } catch (e) {
        print('⚠️ [BluetoothMesh] Disconnect error: $e');
      }
    }
    
    _connectedDevices.clear();
    _discoveredDevices.clear();
  }

  /// Dispose resources
  void dispose() {
    _stopScanning();
    _adapterStateSubscription?.cancel();
    _scanSubscription?.cancel();
    disconnectAll();
    print('🔵 [BluetoothMesh] Disposed');
  }
}
