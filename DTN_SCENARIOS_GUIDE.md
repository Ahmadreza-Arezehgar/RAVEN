# High-Density Scenario Optimization Guide

## Overview

DTN رو برای سناریوهای مختلف optimize کردیم! 🎯

---

## 🎭 سناریوها

### 1. 📱 Normal (عادی)
**برای:** استفاده روزمره

**تنظیمات:**
- Spray Counter: 5
- TTL: 10
- Scan Interval: 10s
- Max Connections: 3
- **Prefer Bluetooth**: ❌ (WiFi اولویت)

---

### 2. 👥 Crowded (شلوغ با اینترنت)
**برای:** مترو، مرکز خرید (شلوغ اما اینترنت خوب)

**تنظیمات:**
- Spray Counter: 3 ⬇️ (کمتر overhead)
- TTL: 8
- Scan Interval: 15s ⬆️ (battery سیو)
- Max Connections: 5
- **Prefer Bluetooth**: ❌

**چرا این settings؟**
- اینترنت خوب → WiFi faster
- زیاد congestion → کمتر spray
- battery offset → کمتر scan

---

### 3. 🎓 Event/University (رویداد/دانشگاه)
**برای:** دانشگاه، کنفرانس، رویداد (خیلی شلوغ + اینترنت ضعیف)

**تنظیمات:**
- Spray Counter: 8 ⬆️ (بیشتر delivery chance)
- TTL: 15 ⬆️
- Scan Interval: 8s ⬇️ (بیشتر scan)
- Max Connections: 7
- **Prefer Bluetooth**: ✅ (اولویت Bluetooth)

**Scenario خاص:**
```
دانشگاه → WiFi overloaded
          ↓
    Bluetooth mesh faster!
          ↓
    Auto-prefer Bluetooth
```

---

### 4. 🏕️ Camp (کمپ/بدون اینترنت)
**برای:** کمپینگ، طبیعت، مناطق بدون پوشش

**تنظیمات:**
- Spray Counter: 10 ⬆️⬆️ (maximum)
- TTL: 20 ⬆️⬆️ (خیلی زیاد)
- Scan Interval: 5s ⬇️⬇️ (scan مداوم)
- Max Connections: 10
- **Prefer Bluetooth**: ✅ (فقط Bluetooth!)
- Message Timeout: 48h ⬆️⬆️

**چرا؟**
- اینترنت نیست!
- فقط Bluetooth
- maximum delivery effort

---

## 🤖 Auto-Detect

سیستم خودکار scenario رو تشخیص می‌ده بر اساس:

**Factors:**
1. **Nearby Peers**: تعداد دستگاه‌های Bluetooth
2. **Internet Quality**: WiFi قوی/ضعیف/نداره

**Logic:**
```
IF peers >= 10 AND no_internet:
    → Event scenario
ELSE IF peers >= 5 AND no_internet:
    → Camp scenario
ELSE IF peers >= 10:
    → Crowded scenario
ELSE:
    → Normal scenario
```

هر 30 ثانیه چک می‌شه!

---

## 📱 Usage

### Option 1: Auto-Detect (Recommended)

```dart
// Initialize without scenario → auto-detect
DTNConfigService.instance.initialize();
```

### Option 2: Manual Selection

```dart
// Show scenario selector
Navigator.push(
  context,
  MaterialPageRoute(builder: (_) => ScenarioSelectorScreen()),
);
```

**Selector UI features:**
- لیست همه scenarios
- توضیحات هر کدام
- نمایش config فعلی
- تغییر manual

### Option 3: Programmatic

```dart
DTNConfigService.instance.initialize(
  scenario: DTNScenario.event,
);
```

---

##⚡ Comparison

| Scenario | Spray | TTL | Bluetooth Priority | Best For |
|----------|-------|-----|-------------------|----------|
| Normal | 5 | 10 | ❌ | روزمره |
| Crowded | 3 | 8 | ❌ | شلوغ + اینترنت |
| Event | 8 | 15 | ✅ | دانشگاه/رویداد |
| Camp | 10 | 20 | ✅ | بدون اینترنت |

---

## 🎯 Use Cases

### دانشگاه (Event Scenario)

**مشکل:**
- 500+ دانشجو
- WiFi overloaded
- همه می‌خوان download/upload

**راه‌حل با Event mode:**
```
Prefer Bluetooth → bypass WiFi
Spray = 8 → خوب propagate می‌شه
TTL = 15 → دور می‌رسه
```

**نتیجه:** Faster + Reliable ✅

---

### کمپینگ (Camp Scenario)

**مشکل:**
- بدون signal
- 10-20 نفر
- فاصله زیاد

**راه‌حل با Camp mode:**
```
Only Bluetooth (no WiFi waste)
Spray = 10 → maximum coverage
TTL = 20 → خیلی دور می‌ره
Keep 48h → long term
```

**نتیجه:** Mesh network کامل! 🏕️

---

### کنسرت/رویداد (Event Scenario)

**مشکل:**
- هزاران نفر
- Cellular overload
- WiFi نداریم

**راه‌حل:**
```
Event mode → Bluetooth priority
Peer count high → good mesh density
```

---

## 📊 Monitoring

با Analytics می‌تونید ببینید:

```dart
final stats = DTNAnalyticsService.instance.getStats();

// در Event scenario انتظار داریم:
// - Bluetooth broadcasts بالا
// - Avg hop count: 1-3
// - Success rate: > 85%
```

---

## 🔧 Advanced: Custom Config

اگر خودتون می‌خواید customize کنید:

```dart
final customConfig = DTNConfig(
  sprayCounter: 7,
  ttl: 12,
  scanInterval: Duration(seconds: 6),
  maxBluetoothConnections: 8,
  preferBluetoothOverServer: true,
  messageTimeout: Duration(hours: 36),
  maxRelayQueueSize: 150,
);
```

---

## ✅ Best Practices

1. **دانشگاه/کنفرانس:**
   - Event scenario
   - Monitor success rate
   - اگر < 80% → افزایش spray

2. **کمپینگ:**
   - Camp scenario
   - Battery monitoring
   - Adjust scan interval if needed

3. **روزمره:**
   - Auto-detect
   - Let system optimize

---

## 🚀 Ready!

حالا DTN برای همه سناریوها optimize شده! 

**تست کنید:**
1. دانشگاه: Event mode
2. خونه: Normal mode  
3. کمپ: Camp mode

Analytics می‌گه چقدر بهتر شدیم! 📊
