# راهنمای تست DTN Mesh Networking در iPhone

## قبل از تست

### 1. ✅ Build کنید

```bash
cd /Users/ahmd/hybrid_messenger
flutter clean
flutter pub get
cd ios
pod install
cd ..
flutter build ios
```

### 2. ✅ دو iPhone لازم دارید

برای تست mesh networking حداقل 2 دستگاه iPhone نیاز دارید.

---

## مرحله 1: تست Basic Initialization

### در `main.dart` یا هر جایی که می‌خواید:

```dart
import 'services/dtn_test_helper.dart';

// در یک button یا onTap:
DTNTestHelper.showTestDialog(
  context,
  currentUser.id,
  'device-id-123', // از device_info_plus بگیرید
);
```

### چک کنید:
- ✓ Bluetooth permission prompt نمایش داده می‌شه
- ✓ در logs: "DTN Initialized successfully"
- ✓ در logs: "Opportunistic scanning active"

---

## مرحله 2: تست Peer Discovery

### روی هر دو iPhone:

1. اپ را باز کنید
2. DTN را initialize کنید
3. در logs چک کنید:

```
📱 [BluetoothMesh] Discovered: iPhone-2
🔗 [BluetoothMesh] Connecting to iPhone-2...
✅ [BluetoothMesh] Connected to iPhone-2
```

### انتظار:
- بعد از 5-15 ثانیه باید به هم connect بشن
- Status باید نشون بده: "Connected Peers: 1"

---

## مرحله 3: تست Message Send

### روی iPhone A:

```dart
DTNTestHelper.instance.sendTestMessage(
  senderId: 'user-A',
  senderName: 'Alice',
  recipientId: 'user-B',
  text: 'Hello from mesh! 👋',
);
```

### روی iPhone B:

در logs باید ببینید:

```
📩 [BluetoothMesh] Received: test-1234567890
📩 [DTNRouter] Received message: test-1234567890
✅ [DTNRouter] Message is for me, delivering
✅ [DTN Test] Message delivered: test-1234567890
   From: Alice
   Text: Hello from mesh! 👋
   Hops: 0
```

---

## مرحله 4: تست Multi-Hop (3 iPhone)

### Setup:
- iPhone A, B, C
- A و C به هم نزدیک نباشند (> 10 متر)
- B در وسط باشه

### Test:
1. A پیام به C بفرسته
2. در logs iPhone B باید ببینید:

```
🔄 [DTNRouter] Relaying message test-xxx
💨 [DTNRouter] Spray phase for test-xxx (counter: 4)
📡 [BluetoothMesh] Broadcasting: test-xxx
```

3. در iPhone C:

```
✅ [DTN Test] Message delivered: test-xxx
   Hops: 1  ← از B relay شده
```

---

## مرحله 5: تست iOS Background

### روی iPhone B (relay):

1. اپ را به background ببرید
2. از iPhone A پیام بفرستید
3. بعد از 5-15 ثانیه، iPhone C باید پیام را دریافت کنه

### انتظار:
- iOS باید iPhone B را wake کنه
- Relay اتفاق بیفته
- در logs iPhone B (وقتی برمی‌گردید به foreground):

```
📱 [BluetoothMesh] Discovered: iPhone-A
🔄 [DTNRouter] Relaying message...
```

---

## Troubleshooting

### "Bluetooth is OFF"
- Settings → Bluetooth → روشن کنید

### "No peers connected"
- هر دو iPhone در فاصله < 10 متر باشند
- Bluetooth روشن باشه
- Wait 15-20 ثانیه

### "Permission denied"
- Settings → Privacy → Bluetooth → اپ شما را enable کنید

### Background relay کار نمی‌کنه
- Info.plist را چک کنید (bluetooth-central, bluetooth-peripheral)
- Location services روشن باشه (گاهی iOS نیاز داره)

---

## Logs مهم

برای دیدن logs در Xcode:
1. اپ را از Xcode run کنید
2. Debug area → Console
3. فیلتر: "DTN" یا "BluetoothMesh"

---

## مثال کامل تست

```dart
// در main.dart:
FloatingActionButton(
  onPressed: () {
    DTNTestHelper.showTestDialog(
      context,
      AppModel.currentUser!.id,
      'iphone-test-1',
    );
  },
  child: const Icon(Icons.network_check),
)
```

موفق باشید! 🚀
