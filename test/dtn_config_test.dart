import 'package:flutter_test/flutter_test.dart';
import 'package:hybrid_messenger/models/message_model.dart';
import 'package:hybrid_messenger/services/dtn_config_service.dart';

void main() {
  group('DTN Config Tests', () {
    test('DTNConfigService initializes with normal scenario by default', () {
      final config = DTNConfigService.instance;
      config.initialize();
      
      expect(config.scenario, equals(DTNScenario.normal));
    });
    
    test('DTNConfig.normal returns expected defaults', () {
      final config = DTNConfig.normal();
      
      expect(config.sprayCounter, equals(5));
      expect(config.ttl, equals(10));
      expect(config.maxBluetoothConnections, equals(3));
      expect(config.preferBluetoothOverServer, isFalse);
    });
    
    test('DTNConfig.event prioritizes Bluetooth', () {
      final config = DTNConfig.event();
      
      expect(config.sprayCounter, equals(8));
      expect(config.ttl, equals(15));
      expect(config.preferBluetoothOverServer, isTrue);
    });
    
    test('DTNConfig.camp has highest spray counter and TTL', () {
      final config = DTNConfig.camp();
      
      expect(config.sprayCounter, equals(10));
      expect(config.ttl, equals(20));
      expect(config.preferBluetoothOverServer, isTrue);
      expect(config.maxRelayQueueSize, equals(200));
    });
    
    test('DTNConfig.crowded has reduced spray to prevent congestion', () {
      final config = DTNConfig.crowded();
      
      expect(config.sprayCounter, equals(3));
      expect(config.preferBluetoothOverServer, isFalse);
    });
  });
  
  group('Message DTN Operations', () {
    test('copyWith updates DTN fields correctly', () {
      final original = ChatMessage(
        id: 'test',
        roomId: 'room',
        senderId: 's',
        senderName: 'Sender',
        recipientId: 'r',
        text: 'Hello',
        timestamp: DateTime.now(),
        ttl: 10,
        hopCount: 0,
        sprayCounter: 5,
      );
      
      // Simulate relay: decrement TTL, increment hop, add to route
      final relayed = original.copyWith(
        ttl: original.ttl - 1,
        hopCount: original.hopCount + 1,
        routePath: [...original.routePath, 'relay-device'],
        sprayCounter: original.sprayCounter - 1,
      );
      
      expect(relayed.ttl, equals(9));
      expect(relayed.hopCount, equals(1));
      expect(relayed.routePath, equals(['relay-device']));
      expect(relayed.sprayCounter, equals(4));
      
      // Original unchanged
      expect(original.ttl, equals(10));
      expect(original.hopCount, equals(0));
    });
    
    test('Message serialization preserves DTN fields', () {
      final msg = ChatMessage(
        id: 'ser-test',
        roomId: 'room',
        senderId: 's',
        senderName: 'Sender',
        recipientId: 'r',
        text: 'Test',
        timestamp: DateTime.now(),
        ttl: 7,
        hopCount: 3,
        sprayCounter: 2,
        routePath: ['a', 'b', 'c'],
        messageSignature: 'sig-123',
        originDeviceId: 'origin-dev',
        hopLimit: 15,
        deliveryAuthority: DeliveryAuthority.mesh,
      );
      
      final json = msg.toJson();
      final parsed = ChatMessage.fromJson(json);
      
      expect(parsed.ttl, equals(7));
      expect(parsed.hopCount, equals(3));
      expect(parsed.sprayCounter, equals(2));
      expect(parsed.routePath, equals(['a', 'b', 'c']));
      expect(parsed.messageSignature, equals('sig-123'));
      expect(parsed.originDeviceId, equals('origin-dev'));
      expect(parsed.hopLimit, equals(15));
      expect(parsed.deliveryAuthority, equals(DeliveryAuthority.mesh));
    });
  });
}
