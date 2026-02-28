import 'dart:developer';

/// Stub BLE Service - Placeholder for mesh networking
/// 
/// This is a stub implementation. Real BLE mesh requires:
/// - flutter_blue_plus package
/// - Platform-specific permissions
/// - GATT service setup
/// 
/// For now, all mesh operations return empty/false.
class BleService {
  static final BleService _instance = BleService._internal();
  static BleService get instance => _instance;
  BleService._internal();
  
  bool _isInitialized = false;
  
  /// Initialize BLE (stub - always succeeds)
  Future<void> init() async {
    log('📡 [BleService] Stub initialized - BLE mesh not implemented yet');
    _isInitialized = true;
  }
  
  /// Get nearby peers (stub - always empty)
  Future<List<BlePeer>> getNearbyPeers() async {
    log('📡 [BleService] getNearbyPeers stub - returning empty');
    return [];
  }
  
  /// Send data to peer (stub - always fails silently)
  Future<bool> sendToPeer(String peerId, String data) async {
    log('📡 [BleService] sendToPeer stub - not sending');
    return false;
  }
  
  /// Check if BLE is available
  bool get isAvailable => false;
  
  /// Check if scanning
  bool get isScanning => false;
  
  /// Start scanning (stub)
  Future<void> startScanning() async {
    log('📡 [BleService] startScanning stub');
  }
  
  /// Stop scanning (stub)
  Future<void> stopScanning() async {
    log('📡 [BleService] stopScanning stub');
  }
  
  void dispose() {
    _isInitialized = false;
  }
}

/// Bluetooth peer info
class BlePeer {
  final String id;
  final String name;
  final int rssi;
  
  BlePeer({
    required this.id,
    required this.name,
    this.rssi = -50,
  });
}
