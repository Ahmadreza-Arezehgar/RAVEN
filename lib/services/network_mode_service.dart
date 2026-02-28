import 'package:flutter/foundation.dart';

/// Network Mode: WiFi یا Bluetooth
enum NetworkMode {
  wifi,      // Internet-based, global content, media support
  bluetooth, // Local mesh, text-only, nearby devices
}

/// Service برای مدیریت Network Mode
class NetworkModeService extends ChangeNotifier {
  NetworkMode _currentMode = NetworkMode.wifi;
  
  NetworkMode get currentMode => _currentMode;
  bool get isWiFiMode => _currentMode == NetworkMode.wifi;
  bool get isBluetoothMode => _currentMode == NetworkMode.bluetooth;
  
  // Character limits
  int get characterLimit => isBluetoothMode ? 280 : 5000;
  
  // Media support
  bool get supportsMedia => isWiFiMode;
  
  /// Switch mode
  void switchMode(NetworkMode mode) {
    if (_currentMode != mode) {
      _currentMode = mode;
      notifyListeners();
      debugPrint('📡 Network mode switched to: ${mode.name}');
    }
  }
  
  /// Toggle بین WiFi و Bluetooth
  void toggle() {
    switchMode(isWiFiMode ? NetworkMode.bluetooth : NetworkMode.wifi);
  }
  
  /// Auto-detect (برای آینده)
  Future<NetworkMode> detectNetworkMode() async {
    // TODO: Check actual network connectivity
    // For now, return current mode
    return _currentMode;
  }
}
