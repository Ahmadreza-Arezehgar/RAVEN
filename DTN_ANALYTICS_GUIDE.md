# DTN Analytics & Debug Guide

## Analytics Service

DTN Analytics Service همه metrics مهم رو track می‌کنه.

---

## Metrics Tracked

### 📤 Message Metrics
- **Total Sent**: تعداد کل پیام‌های ارسال شده
- **Delivered**: پیام‌های تحویل داده شده
- **Failed**: پیام‌های ناموفق
- **Success Rate**: نرخ موفقیت (delivered / total * 100)

### 🔄 Relay Metrics
- **Messages Relayed**: تعداد پیام‌هایی که relay شدن
- **Bluetooth Broadcasts**: تعداد broadcast های Bluetooth

### ⚡ Performance Metrics
- **Average Delivery Time**: میانگین زمان تحویل
- **Average Hop Count**: میانگین تعداد hops

### 🔋 Battery Metrics
- **Estimated Impact**: تخمین مصرف باتری (% per hour)

---

## Usage

### Initialize

```dart
import 'services/dtn_analytics_service.dart';

// Initialize analytics
DTNAnalyticsService.instance.initialize();
```

### Track Events (Automatic)

Analytics به صورت خودکار در DTN Router track می‌شه:

```dart
// همه اینها خودکار هستن:
_analytics.trackMessageSent(msg, 'wifi');
_analytics.trackMessageDelivered(msg);
_analytics.trackRelay(msgId, hopCount);
_analytics.trackBluetoothBroadcast(msgId);
```

### View Stats

```dart
final stats = DTNAnalyticsService.instance.getStats();

print('Success Rate: ${stats.successRate}%');
print('Avg Delivery: ${stats.averageDeliveryTime.inSeconds}s');
print('Avg Hops: ${stats.averageHopCount}');
```

### Print Full Report

```dart
DTNAnalyticsService.instance.printReport();
```

**Console Output:**
```
═══════════════════════════════════════
📊 DTN ANALYTICS REPORT
═══════════════════════════════════════
Session Duration: 1h 23m

📤 MESSAGES:
   Total Sent: 45
   Delivered: 42
   Failed: 3
   Success Rate: 93.3%

🔄 RELAY:
   Messages Relayed: 15
   Bluetooth Broadcasts: 28

⚡ PERFORMANCE:
   Avg Delivery Time: 4s
   Avg Hop Count: 1.2

🔋 BATTERY:
   Estimated Impact: 3.5%/hour
═══════════════════════════════════════
```

### Export JSON

```dart
final json = DTNAnalyticsService.instance.exportJson();
print(jsonEncode(json));
```

---

## Debug Panel UI

### Show Debug Panel

```dart
import 'screens/dtn_debug_panel.dart';

// در app:
Navigator.push(
  context,
  MaterialPageRoute(builder: (_) => DTNDebugPanel()),
);
```

### Features:
- ⏱️ Session duration
- 📤 Message stats با color coding
- 🔄 Relay metrics
- ⚡ Performance با thresholds
- 🔋 Battery impact
- Auto-refresh هر 2 ثانیه
- Reset button
- Print report button

### Debug Button (FAB)

```dart
import 'screens/dtn_debug_panel.dart';

// در صفحه اصلی:
floatingActionButton: DTNDebugButton(),
```

---

## Interpretation Guide

### Success Rate ✅
- **> 90%**: عالی! 🟢
- **70-90%**: خوب 🟡
- **< 70%**: نیاز به بهینه‌سازی 🔴

### Delivery Time ⚡
- **< 5s**: سریع 🟢
- **5-15s**: متوسط 🟡
- **> 15s**: کند 🔴

### Hop Count 🔄
- **0-1**: Direct یا یک hop 🟢
- **2-3**: چند hop 🟡
- **> 3**: زیاد (ممکنه inefficient باشه) 🔴

### Battery Impact 🔋
- **< 5%/hour**: عالی 🟢
- **5-10%/hour**: قابل قبول 🟡
- **> 10%/hour**: زیاد، نیاز به optimization 🔴

---

## Example Integration

```dart
// در main.dart:
void main() {
  runApp(MyApp());
  
  // Initialize analytics
  DTNAnalyticsService.instance.initialize();
}

// Debug menu:
PopupMenuButton(
  itemBuilder: (context) => [
    PopupMenuItem(
      child: Text('📊 Analytics'),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => DTNDebugPanel()),
        );
      },
    ),
    PopupMenuItem(
      child: Text('🖨️ Print Report'),
      onTap: () {
        DTNAnalyticsService.instance.printReport();
      },
    ),
  ],
)
```

---

## Testing Scenarios

### Test 1: WiFi Performance
1. فقط WiFi
2. چند پیام بفرستید
3. چک کنید: delivery time < 2s

### Test 2: Bluetooth Performance
1. بدون WiFi، با Bluetooth peer
2. چند پیام بفرستید
3. چک کنید: delivery time < 5s, hop count = 0

### Test 3: Multi-Hop
1. 3 گوشی (A-B-C)
2. A به C پیام بده
3. چک کنید: hop count = 1

### Test 4: Battery Impact
1. 1 ساعت استفاده
2. Battery drop را measure کنید
3. Target: < 5%/hour

---

## Monitoring Best Practices

1. **Regular Checks**: هر چند وقت یک بار analytics رو چک کنید
2. **Compare**: قبل و بعد از تغییرات مقایسه کنید
3. **Export**: برای analysis طولانی مدت export کنید
4. **Optimize**: اگر metrics بد بود، بهینه‌سازی کنید

---

## آماده! 📊

حالا می‌تونید performance DTN رو کاملاً monitor کنید! 🚀
