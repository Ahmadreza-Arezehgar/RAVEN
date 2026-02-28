import 'package:flutter_test/flutter_test.dart';
import 'package:hybrid_messenger/services/message_router.dart';
import 'package:hybrid_messenger/services/security_service.dart';
import 'package:hybrid_messenger/models/message_model.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  setUpAll(() {
    // Initialize FFI for SQLite tests on desktop/mock
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // Note: SecurityService encryption methods were removed in refactor.
  // Encryption is now handled natively in BLEMeshService (Noise Protocol).
  
  // Note: Testing MessageRouter requires mocking DatabaseHelper and Connectivity.
  // Since we don't have dependency injection fully set up for DB, we will rely on integration/logic checks
  // or just test the Security logic which is a critical part of the new feature.
  
  test('Message Model Serialization', () {
    final msg = ChatMessage(
        id: '123',
        roomId: 'general',
        senderId: 'A',
        senderName: 'Alice',
        recipientId: 'B',
        text: 'Hi',
        timestamp: DateTime.now(),
        needsForwarding: true
    );
    
    final json = msg.toJson();
    expect(json['id'], '123');
    expect(json['needsForwarding'], 1);
    
    final parsed = ChatMessage.fromJson(json);
    expect(parsed.id, '123');
    expect(parsed.needsForwarding, true);
  });
}
