import 'package:connectivity_plus/connectivity_plus.dart';

/// Auto Network Detection Service
/// Detects best available network: WiFi → Bluetooth → Local
class NetworkDetector {
  final Connectivity _connectivity = Connectivity();

  /// Detect the best available network method
  /// Priority: WiFi > Bluetooth > Local
  Future<NetworkMethod> detectBestMethod({
    required bool hasBluetoothPeers,
  }) async {
    try {
      // Check WiFi/Mobile data first (highest priority)
      final connectivityResult = await _connectivity.checkConnectivity();
      
      if (connectivityResult == ConnectivityResult.wifi ||
          connectivityResult == ConnectivityResult.mobile) {
        return NetworkMethod.wifi;
      }
      
      // Fallback to Bluetooth if peers available
      if (hasBluetoothPeers) {
        return NetworkMethod.bluetooth;
      }
      
      // Local only (no connectivity)
      return NetworkMethod.local;
      
    } catch (e) {
      print('❌ [NetworkDetector] Error: $e');
      // Safe fallback
      return hasBluetoothPeers ? NetworkMethod.bluetooth : NetworkMethod.local;
    }
  }

  /// Get status description for UI
  String getStatusDescription(NetworkMethod method) {
    switch (method) {
      case NetworkMethod.wifi:
        return 'Sending via WiFi';
      case NetworkMethod.bluetooth:
        return 'Sending via Bluetooth';
      case NetworkMethod.local:
        return 'Offline - Local only';
    }
  }

  /// Get icon for network method
  String getMethodIcon(NetworkMethod method) {
    switch (method) {
      case NetworkMethod.wifi:
        return '🌐';
      case NetworkMethod.bluetooth:
        return '📶';
      case NetworkMethod.local:
        return '📱';
    }
  }
}

/// Network method enum
enum NetworkMethod {
  wifi,
  bluetooth,
  local,
}
