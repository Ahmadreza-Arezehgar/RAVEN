# RAVEN iOS - Native Swift App

A complete SwiftUI rewrite of the RAVEN Messenger for iOS.

## 📊 Project Stats

- **22 Swift files**
- **5,860+ lines of code**
- **100% Swift/SwiftUI**

## 📂 Project Structure

```
RAVEN-iOS/
├── README.md
├── RAVEN.xcodeproj/
└── RAVEN/
    ├── RAVENApp.swift              # App entry point
    │
    ├── Models/
    │   ├── Models.swift            # User, Message, Conversation
    │   └── SocialModels.swift      # Post, Comment, News
    │
    ├── ViewModels/
    │   └── AppState.swift          # Global state (@Published)
    │
    ├── Services/
    │   ├── APIService.swift        # REST API client
    │   ├── AuthService.swift       # Auth + Keychain tokens
    │   ├── DatabaseService.swift   # SQLite local storage
    │   ├── SyncService.swift       # Background sync
    │   ├── NotificationService.swift # APNs push notifications
    │   ├── MediaService.swift      # Camera/Photos/Voice recording
    │   ├── AudioPlayerService.swift # Voice message playback
    │   └── NetworkMonitor.swift    # Connectivity status
    │
    ├── Views/
    │   ├── MainTabView.swift       # 5-tab navigation
    │   ├── HomeView.swift          # Social feed + posts
    │   ├── MessagesView.swift      # Inbox / conversation list
    │   ├── ChatView.swift          # Individual chat screen
    │   ├── ChatDetailsView.swift   # Shared media + profile
    │   ├── AuthenticationView.swift # Sign In / Sign Up
    │   ├── AccountView.swift       # Profile & Settings
    │   ├── Components/
    │   │   └── UIComponents.swift  # Reusable glass components
    │   └── Settings/
    │       └── SettingsViews.swift # Privacy, Security, About
    │
    └── Utils/
        └── Extensions.swift        # Date, String, Color helpers
```

## 🚀 Getting Started

### 1. Create Xcode Project

```bash
# Open Xcode
# File → New → Project → iOS App
# Product Name: RAVEN
# Interface: SwiftUI
# Language: Swift
```

### 2. Import Files

1. Delete auto-generated `ContentView.swift`
2. Drag all files from `RAVEN-iOS/RAVEN/` into Xcode

### 3. Update API URL

Edit `Services/APIService.swift` and `Services/AuthService.swift`:

```swift
private let baseURL = "https://YOUR-API-DOMAIN.com/api"
```

### 4. Add Info.plist Permissions

```xml
<key>NSCameraUsageDescription</key>
<string>For sending photos and videos</string>

<key>NSMicrophoneUsageDescription</key>
<string>For voice messages</string>

<key>NSPhotoLibraryUsageDescription</key>
<string>For sending photos</string>

<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.raven.sync</string>
</array>
```

### 5. Build & Run

```bash
xcodebuild -project RAVEN.xcodeproj \
  -scheme RAVEN \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  build
```

## ✅ Features Implemented

| Feature | Status |
|---------|--------|
| Sign In / Sign Up | ✅ |
| Sign Out | ✅ |
| Keychain Token Storage | ✅ |
| Tab Navigation (5 tabs) | ✅ |
| Inbox / Conversations | ✅ |
| Chat with Messages | ✅ |
| Text / Image / Voice / File bubbles | ✅ |
| Message Status Indicators | ✅ |
| Social Feed / Posts | ✅ |
| Like / Comment / Repost | ✅ |
| Compose Post | ✅ |
| Photo Picker | ✅ |
| Voice Recording | ✅ |
| Audio Playback + Waveform | ✅ |
| SQLite Local Database | ✅ |
| Background Sync | ✅ |
| Push Notifications (APNs) | ✅ |
| Network Status Monitor | ✅ |
| Settings (Privacy/Security) | ✅ |
| Glassmorphism UI | ✅ |

## 📱 Required iOS Version

- iOS 17.0+
- Xcode 15.0+
- Swift 5.9+

## 🔗 Backend

Uses the same Python/FastAPI backend at `hybrid_messenger/server/`

## 📄 License

MIT License - © 2025 RAVEN
