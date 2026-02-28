# RAVEN - راهنمای کامل

---

# 📖 بخش ۱: نحوه استفاده (How to Use)

## 📱 شروع کار با RAVEN

### What is RAVEN?

RAVEN is an advanced communication platform that combines traditional cloud-based messaging with innovative Delay-Tolerant Networking (DTN) technology. The application provides seamless communication through both WiFi/cellular networks and Bluetooth Low Energy mesh networking, ensuring you can stay connected even in environments with limited or no internet connectivity.

### How do I create an account?

1. Launch the application and select **Sign Up**
2. Choose one of three methods:
   - **Traditional Sign-Up**: Enter username, email, and password
   - **Google Sign-In**: Authenticate with your Google account, then choose a unique username
   - **Apple ID Sign-In**: Authenticate with your Apple ID, then choose a unique username
3. Complete account verification
4. Customize your profile (optional)

### Can I sign up using social accounts?

Yes! RAVEN supports authentication through **Google Sign-In** and **Apple ID Sign-In**. After authenticating with a social provider, you'll be prompted to create a unique username for in-app interactions. This combines the convenience of OAuth with the personalization of a custom username.

### How do I customize my profile?

Navigate to **Account Settings** to:
- Upload a profile picture (with screenshot protection)
- Edit your bio
- Adjust search privacy settings
- Configure news interests
- Set language preferences
- Customize font size for accessibility

---

## 💬 Messaging & Communication

### How does the Dual-Transport Architecture work?

RAVEN intelligently routes your messages using two transport methods:

1. **WiFi/Cellular (Primary)**: When internet is available, messages are sent via secure cloud servers for instant delivery
2. **Bluetooth Mesh (Fallback)**: When offline, messages automatically switch to Bluetooth Low Energy mesh networking with multi-hop relay

The app seamlessly switches between these modes without user intervention.

### How does offline messaging work?

When internet connectivity is unavailable, RAVEN automatically switches to Bluetooth mesh networking:

1. Your message is encrypted and stored locally
2. The app broadcasts the message to nearby Bluetooth-enabled devices running RAVEN
3. Intermediate devices relay (hop) the message toward the destination
4. The message continues hopping until it reaches the recipient
5. Each hop is authenticated using HMAC to prevent tampering

This is powered by the **Spray-and-Wait** routing algorithm for efficient message propagation.

### What is the Outbox?

The Outbox is a queue that stores messages awaiting delivery. This includes:
- Messages pending WiFi/cellular connection
- Messages being transmitted via Bluetooth mesh
- Messages queued for relay through intermediate devices

You can monitor message delivery status in the Outbox interface, which shows whether messages are pending, in transit, or delivered.

### How many hops can a message make?

Messages can hop through multiple intermediate devices. The system implements intelligent routing to minimize hops while ensuring delivery. Each hop is cryptographically authenticated to maintain security and prevent tampering.

### Can I send images?

Yes! RAVEN supports image posting in the social feed. Images are:
- Stored securely on the server (not just locally)
- Compressed for efficient transmission
- Displayed inline in posts
- Protected by the same encryption as text messages

---

## 🎨 قابلیت‌های اجتماعی (Social Features)

### What social features does RAVEN offer?

RAVEN includes a Twitter/X-style social platform with:
- **Posts**: Share text and images (up to 280 characters)
- **Likes**: Express appreciation with animated heart reactions
- **Reposts**: Share others' content with your followers
- **Comments**: Engage in conversations on posts
- **Friend System**: Connect with users to enable direct messaging
- **Real-Time Feed**: Auto-refreshes every 10 seconds for latest content

### What is the AI Comment Assistant?

The AI Comment Assistant is a Gemini-powered feature that provides intelligent, context-aware responses to comments. To use it:

1. Mention `@time_ask` in a comment
2. Ask your question (e.g., "@time_ask What's the weather like?")
3. The AI will generate a thoughtful, relevant response
4. Responses appear as regular comments in the thread

This feature enhances engagement and provides helpful information directly in conversations.

### How does screenshot protection work for profile pictures?

When you set a profile picture:
- The app detects screenshot attempts on supported devices
- The profile owner receives an instant notification if someone tries to screenshot their picture
- A "📸 Screenshot detected!" alert appears to both users
- This helps protect your privacy and control over your image

### How do friend requests work?

1. After exchanging 3 messages with someone, you're prompted to add them as a friend
2. Send a friend request to continue unlimited messaging
3. Once accepted, both users appear in each other's Friends list
4. Friend status persists across app restarts and device changes
5. You can view all friends in the **Friends** tab

---

## 🔒 حریم خصوصی و امنیت (Privacy & Security)

### How are my messages encrypted?

RAVEN implements military-grade encryption:

- **End-to-End Encryption (E2EE)**: All messages are encrypted on your device before transmission
- **AES-256 Encryption**: Industry-standard symmetric encryption for message content
- **Message Signing**: Each message is cryptographically signed to verify authenticity and prevent spoofing
- **HMAC Authentication**: Bluetooth mesh messages include Hash-based Message Authentication Codes
- **Secure Key Storage**: Private keys are stored in iOS Keychain (never in plain text)

### Can someone intercept my Bluetooth messages?

No. Bluetooth mesh messages are protected by:
- **Encryption**: All content is encrypted end-to-end
- **Authentication**: Each hop is verified using HMAC
- **Integrity Checks**: Tampered messages are automatically discarded
- **Public Key Fingerprinting**: Sender identity is verified to prevent spoofing

Even if intercepted, messages cannot be decrypted or modified.

### What is App Lock?

App Lock protects your conversations with:
- **Passcode Protection**: 4-digit PIN required to open the app
- **Biometric Authentication**: Face ID or Touch ID support
- **Auto-Lock**: App locks when minimized or after inactivity
- **Failed Attempt Tracking**: Monitors unauthorized access attempts

Set up via **Account Settings → Privacy and Security → Passcode & Face ID**.

### What is Two-Step Verification (2FA)?

Two-Step Verification adds an extra layer of security by requiring a verification code from your email when signing in from a new device. 

To enable:
1. Navigate to **Account Settings → Privacy and Security → Two-Step Verification**
2. Choose verification method (Email or SMS - SMS coming soon)
3. Confirm with verification code
4. Your account is now protected with 2FA

### Can I auto-delete messages?

Yes! Enable Auto-Delete Messages to automatically remove old conversations:

1. Go to **Account Settings → Privacy and Security → Auto-Delete Messages**
2. Choose deletion period: 24 hours, 7 days, or 30 days
3. Messages older than the selected period are automatically deleted
4. **Warning**: Deleted messages cannot be recovered

### How do I block users?

To block a user:
1. Visit their profile
2. Tap the block icon
3. Blocked users cannot message you or see your posts
4. View blocked users in **Account Settings → Privacy and Security → Blocked Users**
5. Unblock anytime from the same menu

---

## ☁️ پشتیبان‌گیری و داده‌ها (Backup & Data)

### How do I backup my chats to iCloud?

1. Navigate to **Account Settings**
2. Select **Backup & Restore**
3. Tap **Create Backup**
4. Wait for confirmation (progress bar shows status)
5. Your encrypted chat history is uploaded to your iCloud account

Backups include all messages, conversation metadata, and friend lists.

### How do I restore from backup?

1. Navigate to **Account Settings → Backup & Restore**
2. Tap **Restore from Backup**
3. Select the backup you want to restore
4. Confirm restoration
5. Wait for the process to complete
6. Your conversations will reappear in the app

### Is iCloud backup secure?

Yes! Backup security includes:
- **End-to-End Encryption**: Messages remain encrypted in backup files
- **Transport Security**: Apple provides encryption for data in transit and at rest
- **Access Control**: Backups are tied to your Apple ID and cannot be accessed by others
- **No Plaintext Storage**: Keys and sensitive data are never stored unencrypted

### Can I export my data?

Yes. The iCloud Backup system allows you to:
- Export all conversations to iCloud
- Download backup files (encrypted JSON format)
- Transfer data between devices
- Maintain full ownership of your data

---

## 📰 اخبار و کشف (News & Discovery)

### How does GPS-based news work?

RAVEN provides personalized news based on your location:
- Automatically detects your GPS coordinates
- Fetches relevant local and regional news
- Sources from trusted providers (BBC, Bloomberg, CNN, Reuters, etc.)
- Updates in real-time with your movement

### Can I customize my news interests?

Yes! Customize news categories in **Account Settings → News Interests**:
- Technology
- Business
- Science
- Health
- Sports
- Entertainment
- General

Selected categories are prioritized in your news feed.

### Is my location data stored?

Location data is used only for real-time news fetching and is not permanently stored. RAVEN respects your privacy and does not track or share your location history.

---

---

# 🔮 بخش ۲: درباره RAVEN (About RAVEN)

RAVEN یک پلتفرم ارتباطی پیشرفته است که پیام‌رسانی ابری سنتی را با فناوری شبکه‌های مقاوم به تأخیر (DTN) ترکیب می‌کند.

## 🌟 ویژگی‌های اصلی

| ویژگی | توضیحات |
|-------|--------|
| **پیام‌رسانی ترکیبی** | ارسال پیام از طریق WiFi/Cellular و Bluetooth Mesh |
| **رمزنگاری قوی** | AES-256 + E2EE برای امنیت کامل |
| **شبکه DTN** | ارتباط حتی بدون اینترنت |
| **شبکه اجتماعی** | پست، لایک، ریپست مثل X/Twitter |
| **چت گروهی** | مکالمات چند نفره با پشتیبانی Mesh |
| **پیام صوتی** | ضبط و ارسال صدا |
| **تماس ویدیویی** | تماس رمزنگاری شده |
| **اشتراک فایل** | ارسال تصاویر، PDF و اسناد |

## 🛡️ امنیت در RAVEN

```
┌─────────────────────────────────────┐
│         رمزنگاری سرتاسری            │
│    End-to-End Encryption (E2EE)    │
├─────────────────────────────────────┤
│  • AES-256 برای محتوای پیام         │
│  • امضای دیجیتال برای اصالت         │
│  • HMAC برای تأیید هویت Mesh       │
│  • کلیدها فقط روی دستگاه شما        │
└─────────────────────────────────────┘
```

## 📡 فناوری DTN چیست؟

DTN (Delay-Tolerant Networking) یک رویکرد شبکه‌ای است که برای محیط‌هایی با اتصال متناوب طراحی شده:

1. **Store-and-Forward**: پیام‌ها ذخیره می‌شوند و وقتی اتصال برقرار شد، ارسال می‌شوند
2. **Multi-Hop**: پیام‌ها از چندین دستگاه عبور می‌کنند
3. **Spray-and-Wait**: الگوریتم بهینه برای انتشار پیام
4. **ارتباط فرصت‌طلبانه**: استفاده از هر اتصال موجود

## 🔄 معماری دو حالته

```
           ┌──────────────────┐
           │   دستگاه شما     │
           └────────┬─────────┘
                    │
        ┌───────────┴───────────┐
        │                       │
   ┌────▼────┐            ┌─────▼─────┐
   │ حالت ۱  │            │  حالت ۲   │
   │ آنلاین  │            │  آفلاین   │
   └────┬────┘            └─────┬─────┘
        │                       │
   ┌────▼────┐            ┌─────▼─────┐
   │ سرور    │            │ Bluetooth │
   │ ابری    │            │   Mesh    │
   └─────────┘            └───────────┘
```

---

## 🌍 سفارشی‌سازی و دسترسی‌پذیری (Customization & Accessibility)

### What languages does RAVEN support?

RAVEN offers 100% localization parity in:
- **English** (English)
- **Spanish** (Español)
- **German** (Deutsch)
- **Persian** (فارسی) with full RTL support
- **Chinese** (中文)

Change language in **Settings → Language**.

### What is RTL support?

Right-to-Left (RTL) support ensures proper text rendering for languages like Persian and Arabic:
- Text flows from right to left
- UI elements mirror appropriately
- Icons and navigation adjust automatically

### Can I adjust font size?

Yes! RAVEN includes **Dynamic Font Scaling** for accessibility:
1. Navigate to **Settings → Font Size**
2. Choose from: Small, Medium, Large, Extra Large
3. All UI components automatically resize
4. Preferences persist across sessions

This ensures readability for all users, including those with visual impairments.

### Can I customize themes?

Theme customization is currently limited to the app's Golden Ratio design system with X-style "Flat Glass" visual language. Future updates may include dark mode and custom color schemes.

---

## ⚙️ ویژگی‌های فنی (Technical Features)

### What is Delay-Tolerant Networking (DTN)?

DTN is a networking approach designed for environments with intermittent connectivity:
- **Store-and-Forward**: Messages are stored when connectivity is unavailable and forwarded when it's restored
- **Multi-Hop Routing**: Messages hop through intermediate nodes
- **Spray-and-Wait Algorithm**: Optimizes message propagation efficiency
- **Opportunistic Communication**: Leverages any available connection (WiFi, Bluetooth, cellular)

### What is the Spray-and-Wait algorithm?

Spray-and-Wait is a routing protocol that:
1. **Spray Phase**: Creates multiple message copies and distributes them to different nodes
2. **Wait Phase**: Each node waits for direct contact with the destination
3. **Efficiency**: Balances delivery probability with network overhead
4. **Performance**: Ensures reliable delivery without flooding the network

### Does RAVEN work in the background on iOS?

Yes! RAVEN supports **background Bluetooth operations** on iOS:
- Continues scanning for nearby devices when the app is minimized
- Receives and relays messages even when not actively using the app
- Optimized for battery efficiency
- Respects iOS background execution limits

### How does real-time sync work?

RAVEN uses **10-second auto-refresh** for:
- Home feed posts
- Notifications (friend requests, likes, comments)
- Message delivery status
- Friend list updates

This ensures you always see the latest content without manual refreshing.

### Is there a web version?

Yes! RAVEN includes a **Progressive Web App (PWA)** with:
- All core messaging features
- Social feed and interactions
- Web Bluetooth API integration for mesh networking
- Offline capability
- Installable on desktop and mobile browsers

Access via your web browser for cross-platform communication.

---

## 🆘 پشتیبانی و عیب‌یابی (Support & Troubleshooting)

### Messages aren't sending. What should I do?

1. **Check connectivity**: Ensure WiFi/cellular or Bluetooth is enabled
2. **Check Outbox**: View pending messages in the Outbox
3. **Retry**: Tap retry on failed messages
4. **Restart app**: Force close and relaunch
5. **Check permissions**: Ensure Bluetooth and network permissions are granted

### The app won't connect to Bluetooth devices. Why?

1. **Enable Bluetooth**: Go to iOS Settings → Bluetooth
2. **Grant Permission**: Allow RAVEN to access Bluetooth in iOS Settings
3. **Check range**: Ensure you're within Bluetooth range (typically 10-30 meters)
4. **Restart Bluetooth**: Toggle Bluetooth off and on
5. **Update app**: Ensure you're running the latest version

### How do I report a bug?

Contact us at:
- **Email**: support@hybridmessenger.com
- **Subject**: Bug Report
- Include: Device model, iOS version, steps to reproduce, screenshots

### How do I request a feature?

We welcome feature requests!
- **Email**: feedback@hybridmessenger.com
- **Subject**: Feature Request
- Describe your idea and use case

### How do I report a security issue?

For security concerns:
- **Email**: security@hybridmessenger.com
- **Response**: We aim to respond within 24-48 hours
- **Disclosure**: We follow responsible disclosure practices

---

## 📊 سیاست حریم خصوصی (Data & Privacy Policy)

### What data does RAVEN collect?

RAVEN collects minimal data:
- **Account Information**: Username, email, password (hashed)
- **Profile Data**: Bio, profile picture (if provided)
- **Message Metadata**: Timestamps, sender/receiver IDs (not content)
- **Usage Analytics**: App interaction patterns (anonymized)

**We do NOT collect**: Message content, location history, contact lists, or any data not essential to app functionality.

### Who can see my data?

- **Your messages**: Only you and the recipient (end-to-end encrypted)
- **Your profile**: Public or private based on your search privacy settings
- **Your posts**: Visible to all RAVEN users (public social feed)
- **Your friend list**: Private (only you can see)

### Can RAVEN read my messages?

No. End-to-end encryption ensures that only you and the recipient can decrypt message content. RAVEN servers never have access to decryption keys or plaintext messages.

### Is my data sold to third parties?

Absolutely not. RAVEN does not sell, rent, or share your personal data with third parties for advertising or any other purpose.

---

---

# 💡 بخش ۳: نکات و ترفندهای باحال (Pro Tips)

## 🔥 Top 10 Tips for Power Users

### 1. 🔌 پیام‌رسانی آفلاین
> **WiFi خاموش کنید، باز هم پیام بفرستید!**
> 
> RAVEN از Bluetooth Mesh استفاده می‌کند. حتی وسط کویر هم اگر دوستتان نزدیک باشد، پیامتان می‌رسد!

### 2. ⏰ زمان‌بندی پیام (Schedule Messages)
> پیام‌ها را برای آینده زمان‌بندی کنید:
> - روی دکمه ارسال **نگه دارید**
> - زمان دلخواه را انتخاب کنید
> - پیام در Outbox ذخیره می‌شود و سر وقت ارسال می‌شود

### 3. 🤖 دستیار هوش مصنوعی
> در کامنت‌ها `@time_ask` را mention کنید و سؤالتان را بپرسید!
> ```
> @time_ask هوا چطوره امروز؟
> ```
> AI پاسخ می‌دهد! ✨

### 4. 📸 محافظت از اسکرین‌شات
> اگر کسی از عکس پروفایل شما اسکری‌شات بگیرد، **فوراً مطلع می‌شوید!**
> یک اعلان "📸 Screenshot detected!" دریافت می‌کنید.

### 5. 🎙️ پیام صوتی حرفه‌ای
> - دکمه میکروفون را **نگه دارید** و صحبت کنید
> - برای لغو، انگشت را به **چپ** بکشید
> - برای قفل کردن، انگشت را به **بالا** بکشید
> - Waveform زنده نمایش داده می‌شود!

### 6. 🔐 App Lock هوشمند
> Face ID + Passcode برای امنیت بیشتر:
> **Settings → Privacy → Passcode & Face ID**

### 7. 🌐 PWA - نسخه وب
> RAVEN را در مرورگر هم استفاده کنید!
> روی دسکتاپ نصب کنید و مثل اپ بومی استفاده کنید.

### 8. 🔄 سینک خودکار
> فید هر ۱۰ ثانیه آپدیت می‌شود!
> نیازی به Pull-to-Refresh نیست (اما اگر دوست دارید، کار می‌کند! 😉)

### 9. 🌙 حالت شب + فونت بزرگ
> برای چشم‌هایتان مهربان باشید:
> **Settings → Font Size** را Large کنید

### 10. 💾 بکاپ به iCloud
> قبل از هر چیز، بکاپ بگیرید:
> **Settings → Backup & Restore → Create Backup**
> همه چت‌ها، رمزنگاری شده، در iCloud شما!

---

## 🎯 Hidden Features (ویژگی‌های مخفی)

| ترفند | توضیح |
|------|-------|
| **Double-tap message** | پاسخ سریع |
| **Long-press send** | زمان‌بندی پیام |
| **Swipe left on chat** | حذف سریع |
| **3 messages = friend** | بعد از ۳ پیام، می‌توانید درخواست دوستی بفرستید |
| **Pull down on feed** | رفرش دستی |

---

## 🛠️ Keyboard Shortcuts (برای PWA)

| کلید | عملکرد |
|-----|--------|
| `Enter` | ارسال پیام |
| `Shift + Enter` | خط جدید |
| `Esc` | بستن modal |
| `Cmd/Ctrl + K` | جستجوی سریع |

---

## 🚀 ویژگی‌های آینده (Coming Soon)

- 🤖 **Android Version** - به زودی!
- 🎨 **Custom Themes** - تم شخصی
- 📍 **Dead Drops** - پیام‌های مکان‌محور
- 🎮 **Mini Games** - بازی‌های چت

---

## ℹ️ اطلاعات اپلیکیشن

| | |
|---|---|
| **نسخه** | 1.0 |
| **توسعه‌دهنده** | RAVEN Team |
| **پلتفرم** | iOS (Android coming soon) |
| **وب‌سایت** | [raven.com](https://raven.com) |

---

**سؤال دارید؟** با ما در ارتباط باشید: support@hybridmessenger.com

---

<div align="center">

✨ **RAVEN** ✨

*ارتباط بدون مرز، حتی بدون اینترنت*

© 2026 RAVEN. All rights reserved.

</div>
