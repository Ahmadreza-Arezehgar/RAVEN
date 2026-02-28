import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';

/// DTN Configuration Service
/// Adaptive configuration برای سناریوهای مختلف
/// 
/// Scenarios:
/// - دانشگاه / رویداد (high density, weak internet)
/// - کمپ / گردهمایی (no internet, many people)
/// - استفاده عادی (mixed)
class DTNConfigService {
  static final DTNConfigService instance = DTNConfigService._();
  DTNConfigService._();

  DTNScenario _currentScenario = DTNScenario.normal;
  DTNConfig _config = DTNConfig.normal();
  
  final _connectivity = Connectivity();
  Timer? _adaptiveTimer;
  
  // Peer tracking
  int _nearbyPeerCount = 0;
  bool _hasWeakInternet = false;

  /// Initialize with scenario
  void initialize({DTNScenario? scenario}) {
    _currentScenario = scenario ?? DTNScenario.normal;
    _config = _getConfigForScenario(_currentScenario);
    
    if (scenario == null) {
      // Auto-detect mode
      _startAdaptiveMonitoring();
    }
    
    print('⚙️ [Config] Initialized: ${_currentScenario.name}');
    _printConfig();
  }

  /// Auto-detect scenario based on environment
  void _startAdaptiveMonitoring() {
    _adaptiveTimer?.cancel();
    _adaptiveTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      await _detectScenario();
    });
  }

  /// Detect scenario based on:
  /// - Nearby peer count
  /// - Internet quality
  Future<void> _detectScenario() async {
    // Check internet quality
    final connectivity = await _connectivity.checkConnectivity();
    _hasWeakInternet = connectivity == ConnectivityResult.none;
    
    // Determine scenario
    DTNScenario newScenario;
    
    if (_nearbyPeerCount >= 10 && _hasWeakInternet) {
      // دانشگاه / رویداد: خیلی آدم + اینترنت ضعیف
      newScenario = DTNScenario.event;
    } else if (_nearbyPeerCount >= 5 && _hasWeakInternet) {
      // کمپ / گردهمایی: چند نفر + بدون اینترنت
      newScenario = DTNScenario.camp;
    } else if (_nearbyPeerCount >= 10) {
      // محیط شلوغ با اینترنت
      newScenario = DTNScenario.crowded;
    } else {
      // عادی
      newScenario = DTNScenario.normal;
    }
    
    if (newScenario != _currentScenario) {
      _switchScenario(newScenario);
    }
  }

  /// Switch to new scenario
  void _switchScenario(DTNScenario newScenario) {
    _currentScenario = newScenario;
    _config = _getConfigForScenario(newScenario);
    
    print('🔄 [Config] Switched to: ${newScenario.name}');
    _printConfig();
  }

  /// Update peer count from Bluetooth service
  void updatePeerCount(int count) {
    _nearbyPeerCount = count;
  }

  /// Get configuration for scenario
  DTNConfig _getConfigForScenario(DTNScenario scenario) {
    switch (scenario) {
      case DTNScenario.event:
        return DTNConfig.event();
      case DTNScenario.camp:
        return DTNConfig.camp();
      case DTNScenario.crowded:
        return DTNConfig.crowded();
      case DTNScenario.normal:
        return DTNConfig.normal();
    }
  }

  /// Get current config
  DTNConfig get config => _config;
  
  /// Get current scenario
  DTNScenario get scenario => _currentScenario;

  void _printConfig() {
    print('📋 [Config] Settings:');
    print('   Spray Counter: ${_config.sprayCounter}');
    print('   TTL: ${_config.ttl}');
    print('   Scan Interval: ${_config.scanInterval.inSeconds}s');
    print('   Prefer Bluetooth: ${_config.preferBluetoothOverServer}');
    print('   Max Connections: ${_config.maxBluetoothConnections}');
  }

  void dispose() {
    _adaptiveTimer?.cancel();
  }
}

/// DTN Scenario Types
enum DTNScenario {
  normal,    // استفاده عادی
  crowded,   // شلوغ با اینترنت
  event,     // دانشگاه/رویداد: شلوغ + اینترنت ضعیف
  camp,      // کمپ: چند نفر + بدون اینترنت
}

/// DTN Configuration
class DTNConfig {
  final int sprayCounter;           // تعداد کپی‌ها
  final int ttl;                    // Time to live
  final Duration scanInterval;      // Bluetooth scan interval
  final int maxBluetoothConnections; // حداکثر connection های همزمان
  final bool preferBluetoothOverServer; // اولویت Bluetooth به جای server
  final Duration messageTimeout;    // پیام‌های قدیمی‌تر از این حذف می‌شن
  final int maxRelayQueueSize;      // حداکثر سایز صف relay

  DTNConfig({
    required this.sprayCounter,
    required this.ttl,
    required this.scanInterval,
    required this.maxBluetoothConnections,
    required this.preferBluetoothOverServer,
    required this.messageTimeout,
    required this.maxRelayQueueSize,
  });

  /// Normal usage
  factory DTNConfig.normal() {
    return DTNConfig(
      sprayCounter: 5,
      ttl: 10,
      scanInterval: const Duration(seconds: 10),
      maxBluetoothConnections: 3,
      preferBluetoothOverServer: false,
      messageTimeout: const Duration(hours: 24),
      maxRelayQueueSize: 50,
    );
  }

  /// Crowded with internet
  factory DTNConfig.crowded() {
    return DTNConfig(
      sprayCounter: 3,  // کمتر چون احتمال congestion
      ttl: 8,
      scanInterval: const Duration(seconds: 15), // کمتر scan (battery)
      maxBluetoothConnections: 5,
      preferBluetoothOverServer: false,
      messageTimeout: const Duration(hours: 12),
      maxRelayQueueSize: 30,
    );
  }

  /// Event/University: crowded + weak internet
  factory DTNConfig.event() {
    return DTNConfig(
      sprayCounter: 8,  // بیشتر برای delivery بهتر
      ttl: 15,          // TTL بیشتر
      scanInterval: const Duration(seconds: 8), // scan بیشتر
      maxBluetoothConnections: 7,
      preferBluetoothOverServer: true, // ✨ اولویت Bluetooth
      messageTimeout: const Duration(hours: 6), // زودتر cleanup
      maxRelayQueueSize: 100,
    );
  }

  /// Camp: no internet, moderate people
  factory DTNConfig.camp() {
    return DTNConfig(
      sprayCounter: 10, // maximum spray
      ttl: 20,          // TTL خیلی بالا
      scanInterval: const Duration(seconds: 5), // scan مداوم
      maxBluetoothConnections: 10,
      preferBluetoothOverServer: true, // اینترنت نیست!
      messageTimeout: const Duration(hours: 48),
      maxRelayQueueSize: 200,
    );
  }
}
