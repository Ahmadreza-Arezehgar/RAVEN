import 'package:flutter_test/flutter_test.dart';
import 'package:hybrid_messenger/models/message_model.dart';

void main() {
  group('DTN Message Tests', () {
    test('ChatMessage has DTN fields with defaults', () {
      final msg = ChatMessage(
        id: 'test-123',
        roomId: 'room-1',
        senderId: 'alice',
        senderName: 'Alice',
        recipientId: 'bob',
        text: 'Hello!',
        timestamp: DateTime.now(),
      );
      
      // Check default DTN field values
      expect(msg.ttl, equals(10));
      expect(msg.hopCount, equals(0));
      expect(msg.hopLimit, equals(10));
      expect(msg.sprayCounter, equals(5));
      expect(msg.routePath, isEmpty);
      expect(msg.deliveryAuthority, equals(DeliveryAuthority.server));
    });
    
    test('ChatMessage.toMeshEnvelope creates valid envelope', () {
      final msg = ChatMessage(
        id: 'test-456',
        roomId: 'room-1',
        senderId: 'alice',
        senderName: 'Alice',
        recipientId: 'bob',
        text: 'Hello via mesh!',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        ttl: 8,
        hopCount: 2,
        sprayCounter: 3,
        routePath: ['device-1', 'device-2'],
        originDeviceId: 'device-origin',
      );
      
      final envelope = msg.toMeshEnvelope();
      
      expect(envelope['v'], equals(1));
      expect(envelope['id'], equals('test-456'));
      expect(envelope['type'], equals('chat'));
      expect(envelope['ts'], equals(1700000000000));
      expect(envelope['to'], equals('bob'));
      expect(envelope['ttl'], equals(8));
      expect(envelope['hop'], equals(2));
      expect(envelope['spray'], equals(3));
      expect(envelope['route'], equals(['device-1', 'device-2']));
      
      // Check nested from object
      final from = envelope['from'] as Map<String, dynamic>;
      expect(from['userId'], equals('alice'));
      expect(from['fingerprint'], equals('device-origin'));
      expect(from['nickname'], equals('Alice'));
      
      // Check payload
      final payload = envelope['payload'] as Map<String, dynamic>;
      expect(payload['text'], equals('Hello via mesh!'));
      expect(payload['roomId'], equals('room-1'));
    });
    
    test('ChatMessage.fromMeshEnvelope parses envelope correctly', () {
      final envelope = {
        'v': 1,
        'id': 'msg-789',
        'type': 'chat',
        'ts': 1700000000000,
        'from': {
          'userId': 'charlie',
          'fingerprint': 'fp-charlie',
          'nickname': 'Charlie',
        },
        'to': 'david',
        'ttl': 5,
        'hop': 3,
        'maxHop': 10,
        'spray': 2,
        'route': ['node-a', 'node-b', 'node-c'],
        'sig': 'hmac-signature',
        'payload': {
          'text': 'DTN message!',
          'roomId': 'room-2',
          'type': 0,
        },
      };
      
      final msg = ChatMessage.fromMeshEnvelope(envelope);
      
      expect(msg.id, equals('msg-789'));
      expect(msg.senderId, equals('charlie'));
      expect(msg.senderName, equals('Charlie'));
      expect(msg.recipientId, equals('david'));
      expect(msg.text, equals('DTN message!'));
      expect(msg.roomId, equals('room-2'));
      expect(msg.ttl, equals(5));
      expect(msg.hopCount, equals(3));
      expect(msg.hopLimit, equals(10));
      expect(msg.sprayCounter, equals(2));
      expect(msg.routePath, equals(['node-a', 'node-b', 'node-c']));
      expect(msg.messageSignature, equals('hmac-signature'));
      expect(msg.originDeviceId, equals('fp-charlie'));
      expect(msg.deliveryAuthority, equals(DeliveryAuthority.mesh));
      expect(msg.via, equals('mesh'));
    });
    
    test('ChatMessage roundtrip: toMeshEnvelope -> fromMeshEnvelope', () {
      final original = ChatMessage(
        id: 'roundtrip-test',
        roomId: 'room-rt',
        senderId: 'sender-1',
        senderName: 'Sender One',
        recipientId: 'recipient-1',
        text: 'Roundtrip test message',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        ttl: 7,
        hopCount: 1,
        sprayCounter: 4,
        routePath: ['hop-1'],
        originDeviceId: 'origin-device',
        messageSignature: 'original-sig',
      );
      
      final envelope = original.toMeshEnvelope();
      final parsed = ChatMessage.fromMeshEnvelope(envelope);
      
      expect(parsed.id, equals(original.id));
      expect(parsed.senderId, equals(original.senderId));
      expect(parsed.senderName, equals(original.senderName));
      expect(parsed.recipientId, equals(original.recipientId));
      expect(parsed.text, equals(original.text));
      expect(parsed.ttl, equals(original.ttl));
      expect(parsed.hopCount, equals(original.hopCount));
      expect(parsed.sprayCounter, equals(original.sprayCounter));
      expect(parsed.routePath, equals(original.routePath));
      expect(parsed.originDeviceId, equals(original.originDeviceId));
      expect(parsed.messageSignature, equals(original.messageSignature));
    });
    
    test('isAlive returns correct value based on TTL', () {
      final aliveMsg = ChatMessage(
        id: 'alive',
        roomId: 'room',
        senderId: 's',
        senderName: 's',
        recipientId: 'r',
        text: 't',
        timestamp: DateTime.now(),
        ttl: 5,
      );
      expect(aliveMsg.isAlive(), isTrue);
      
      final deadMsg = ChatMessage(
        id: 'dead',
        roomId: 'room',
        senderId: 's',
        senderName: 's',
        recipientId: 'r',
        text: 't',
        timestamp: DateTime.now(),
        ttl: 0,
      );
      expect(deadMsg.isAlive(), isFalse);
    });
    
    test('isForMe returns correct value', () {
      final msg = ChatMessage(
        id: 'test',
        roomId: 'room',
        senderId: 'alice',
        senderName: 'Alice',
        recipientId: 'bob',
        text: 'Hi',
        timestamp: DateTime.now(),
      );
      
      expect(msg.isForMe('bob'), isTrue);
      expect(msg.isForMe('alice'), isFalse);
      expect(msg.isForMe('charlie'), isFalse);
    });
    
    test('hasPassedThrough detects loop', () {
      final msg = ChatMessage(
        id: 'test',
        roomId: 'room',
        senderId: 's',
        senderName: 's',
        recipientId: 'r',
        text: 't',
        timestamp: DateTime.now(),
        routePath: ['device-a', 'device-b', 'device-c'],
      );
      
      expect(msg.hasPassedThrough('device-b'), isTrue);
      expect(msg.hasPassedThrough('device-x'), isFalse);
    });
    
    test('ChatMessage media fields roundtrip: toJson -> fromJson', () {
      final original = ChatMessage(
        id: 'media-test',
        roomId: 'room-1',
        senderId: 'sender',
        senderName: 'Sender',
        recipientId: 'recipient',
        text: 'photo_2024.jpg',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        type: MessageType.image,
        audioUrl: 'https://cdn.example.com/photo.jpg',
        fileName: 'photo_2024.jpg',
        mimeType: 'image/jpeg',
        fileSize: 1024000,
        thumbnailUrl: 'https://cdn.example.com/thumb.jpg',
      );
      
      final json = original.toJson();
      final parsed = ChatMessage.fromJson(json);
      
      expect(parsed.fileName, equals('photo_2024.jpg'));
      expect(parsed.mimeType, equals('image/jpeg'));
      expect(parsed.fileSize, equals(1024000));
      expect(parsed.thumbnailUrl, equals('https://cdn.example.com/thumb.jpg'));
      expect(parsed.audioUrl, equals('https://cdn.example.com/photo.jpg'));
      expect(parsed.type, equals(MessageType.image));
    });
    
    test('ChatMessage media fields roundtrip: toMeshEnvelope -> fromMeshEnvelope', () {
      final original = ChatMessage(
        id: 'mesh-media-test',
        roomId: 'room-2',
        senderId: 'alice',
        senderName: 'Alice',
        recipientId: 'bob',
        text: 'document.pdf',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        type: MessageType.file,
        audioUrl: 'https://cdn.example.com/doc.pdf',
        fileName: 'document.pdf',
        mimeType: 'application/pdf',
        fileSize: 2048000,
        originDeviceId: 'device-alice',
      );
      
      final envelope = original.toMeshEnvelope();
      final parsed = ChatMessage.fromMeshEnvelope(envelope);
      
      expect(parsed.fileName, equals('document.pdf'));
      expect(parsed.mimeType, equals('application/pdf'));
      expect(parsed.fileSize, equals(2048000));
      expect(parsed.audioUrl, equals('https://cdn.example.com/doc.pdf'));
      expect(parsed.type, equals(MessageType.file));
    });
  });
}
