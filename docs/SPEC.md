# RAVEN - Application Specification (SPEC)
> **Version**: 1.0  
> **Source of Truth**: Flutter `lib/` directory  
> **Purpose**: Full Native Swift/SwiftUI Rewrite Reference

---

## 1. App Overview

**RAVEN** is a hybrid messenger with DTN (Delay-Tolerant Networking) mesh capabilities. Messages can be delivered via:
- **WiFi/Internet** → Server-based routing (blue delivery indicator)
- **Bluetooth/Mesh** → Peer-to-peer routing when offline (purple delivery indicator)

---

## 2. Screen Inventory

### 2.1 Authentication Flow
| Screen | File | Description |
|--------|------|-------------|
| Welcome | `welcome_screen.dart` | Initial landing with branding |
| Sign Up | `sign_up_screen.dart` | Email mandatory, phone optional |
| Sign In | `sign_in_screen.dart` | Email + password OR Google |
| Email Verification | `email_verification_screen.dart` | 6-digit code input |
| Forgot Password | `forgot_password_screen.dart` | Email-based reset |
| Username Selection | `username_selection_screen.dart` | After OAuth, pick unique username |
| Verify Email | `verify_email_screen.dart` | Resend code + countdown timer |

### 2.2 Main Navigation (Tab Bar)
| Tab | Screen | File |
|-----|--------|------|
| Home | Feed (Local + Friends) | `home_tabs.dart` |
| Messages | Inbox | `messages_page.dart` |
| Search | Discovery | `search_page.dart` |
| Account | Settings & Profile | `account_settings_page.dart` |

### 2.3 Messaging
| Screen | File | Description |
|--------|------|-------------|
| Chat | `chat_page.dart` | 1:1 conversation with all media types |
| Chat Details | `chat_details_page.dart` | Shared media, mute, block, info |
| Contact Picker | `contact_picker_page.dart` | Select recipient for new chat |
| Group Setup | `group_setup_page.dart` | Create new group chat |

### 2.4 Posts & Social
| Screen | File | Description |
|--------|------|-------------|
| Post Detail | `post_detail_screen.dart` | Full post with comments |
| Hashtag Feed | `hashtag_feed_page.dart` | Posts filtered by hashtag |
| User Profile | `user_profile_page.dart` | View other user's profile |
| Profile Edit | `profile_edit_screen.dart` | Edit own profile |

### 2.5 Settings & Privacy
| Screen | File | Description |
|--------|------|-------------|
| Settings | `settings_screen.dart` | Main settings hub |
| Privacy Settings | `privacy_settings_page.dart` | Who can message, see profile |
| Privacy Security | `privacy_security_page.dart` | Security options |
| Two-Step Verification | `two_step_verification_page.dart` | 2FA setup |
| Passcode Setup | `passcode_setup_page.dart` | App lock passcode |
| Blocked Users | `blocked_users_page.dart` | Manage blocks |
| Change Password | `change_password_page.dart` | Update password |

### 2.6 Mesh & DTN
| Screen | File | Description |
|--------|------|-------------|
| Mesh Status | `mesh_status_screen.dart` | BLE peers, relay stats |
| DTN Debug Panel | `dtn_debug_panel.dart` | Developer mesh analytics |
| Dead Drop List | `deaddrop_list_screen.dart` | Geo-cached messages |

### 2.7 Other
| Screen | File | Description |
|--------|------|-------------|
| FAQ | `faq_page.dart` | Help & support |
| QR | `qr_screen.dart`, `scan_qr_screen.dart` | Share/scan profile QR |
| PDF Viewer | `pdf_viewer_screen.dart` | View PDF attachments |

---

## 3. Feature Specifications

### 3.1 Authentication

#### Sign Up
- **Email**: Mandatory, must be verified before access
- **Phone**: Optional, can verify later
- **Password**: Min 10 chars + uppercase + lowercase + number + special char + cannot contain username
- **Flow**: Signup → Email OTP (6 digits) → Verified → Full Access Token

#### Google Sign-In
- If email already exists with password: Show "Email already registered" error
- If new: Create user, prompt for username selection
- Store: `oauth_provider='google'`, `oauth_provider_id`

#### Email Verification
- 6-digit numeric OTP
- **10-minute expiry** (600 seconds)
- Max 5 attempts per token
- 60-second cooldown between resends
- Visual: Separated input boxes, auto-advance on each digit
- **CRITICAL**: User gets restricted token until verified, no main app access

#### Forgot Password
- Enter email → Server sends reset OTP
- Enter OTP → Enter new password → Success

### 3.2 Messaging

#### Message Types
| Type | Index | Description |
|------|-------|-------------|
| text | 0 | Plain text |
| image | 1 | Photo with thumbnail |
| file | 2 | PDF, document with filename |
| voice | 3 | Audio with waveform + duration |
| location | 4 | GPS coordinates |

#### Delivery Status
| Status | Description |
|--------|-------------|
| pending | Queued locally |
| sending | Upload in progress |
| sent | Server received |
| forwarding | Mesh relay in progress |
| delivered | Recipient device received |
| read | Recipient opened chat |
| failed | Delivery failed |
| scheduled | Waiting for scheduled time |

#### Delivery Authority Color Coding
- **Blue (WiFi/Server)**: `deliveryAuthority = server`
- **Purple (Bluetooth/Mesh)**: `deliveryAuthority = mesh`

#### Voice Messages
- Duration stored in `audioDurationSeconds`
- Waveform data for visualization
- Transcript: `pending` → `processing` → `ready`
- Play/Pause controls with progress slider

#### Scheduled Messages
- `sendMode`: `instant` (default) or `scheduled`
- `scheduledAtUtc`: UTC timestamp for delivery
- Picker UI: Preset chips (1h, tonight, tomorrow) + custom date/time

#### Reply Quote
- `replyToMessageId`, `replyToTextPreview` (max 50 chars)
- `replyToSenderName`, `replyToType`
- Visual: Capsule above message input when replying

### 3.3 Posts & Feed

#### Feed Types
| Tab | Description |
|-----|-------------|
| Local | Posts within geo-radius (public visibility) |
| Friends | Posts from friends (friendsOnly or public) |

#### Post Visibility
- `public`: Visible in both Local and Friends feeds
- `friendsOnly`: Only visible to friends

#### Post Interactions
- Like (toggle, with animation)
- Comment (threaded replies)
- Forward (in-app only, no external share)
- View count (privacy-first, no viewer list)
- **REMOVED**: Repost, Share, 3-dots menu

### 3.4 Contacts & Friends

#### Relationship Status
| Status | Value | Description |
|--------|-------|-------------|
| stranger | 0 | No relationship |
| pending | 1 | Request sent, waiting |
| following | 2 | One-way follow accepted |
| followbackPending | 3 | Mutual request pending |
| friends | 4 | Mutual friends, can chat |
| declined | 5 | Request declined |
| blocked | 6 | Blocked |

#### Friend Request Flow
1. User A sends request → A=`pending`, B gets notification
2. B accepts → Both become `friends`
3. OR B declines → A=`declined`

### 3.5 Notifications

#### Types
| Type | Description |
|------|-------------|
| message | New message received |
| friendRequest | Incoming friend request |
| friendRequestSent | Outgoing request accepted |
| mention | Tagged in post |
| like | Post was liked |
| comment | Comment on post |
| presence | Nearby mesh user |
| deadDrop | New geo-cached message |
| security | Login/password events |

### 3.6 Mesh/DTN

#### Spray-and-Wait Algorithm
- `sprayCounter`: Remaining copies to distribute
- New message starts with sprayCounter=5
- Each hop decrements counter
- When counter=1, message enters "wait" phase

#### Hop Limiting
- `hopCount`: Current hop number
- `hopLimit`: Max hops allowed (default 10)
- Message dropped when hopCount > hopLimit

#### Route Path
- `routePath`: Array of device IDs message passed through
- Used to prevent routing loops

---

## 4. UI/UX Rules (Liquid Glass Design)

### 4.1 Colors
```
Primary: #6644FF (Purple-Blue)
Secondary: #00CCCC (Cyan)
Accent: #FF6699 (Pink)
```

### 4.2 Glass Effect
- `.ultraThinMaterial` background
- White border 0.5-1px at 20-30% opacity
- Corner radius: 16-20px for cards, 8-12px for inputs

### 4.3 Animations
- Spring animations for interactive elements
- 200-300ms duration for transitions
- Haptic feedback on important actions

### 4.4 Typography
- Headlines: SF Pro Display Bold
- Body: SF Pro Text
- Monospace: SF Mono (for codes)

---

## 5. Known Bugs (Must Not Repeat in Swift)

### 5.1 "Attachment shows as text first"
**Symptom**: Image/voice message appears as text placeholder, correct after app restart  
**Root Cause**: Message inserted before metadata fully available; UI not observing changes  
**Fix in Swift**: Insert message + attachment atomically; use `@Observable` properly

### 5.2 "Inbox doesn't update until entering chat"
**Symptom**: New messages don't appear in conversation list  
**Root Cause**: No realtime listener on conversation list; only chat screen listens  
**Fix in Swift**: Central `ConversationStore` with background polling/websocket

### 5.3 "Voice duration shows 0:00"
**Symptom**: Voice message duration is 0 or 10s fixed  
**Root Cause**: Duration not captured correctly from recorder; not stored in DB  
**Fix in Swift**: Capture actual duration from AVAudioRecorder, store in message

### 5.4 "Email verification not received"
**Symptom**: Users don't receive verification emails  
**Root Cause**: SMTP misconfiguration, emails going to spam, or silent API failures  
**Fix in Swift**: Display clear error messages from server; check spam folder prompt

### 5.5 "Nickname not saved"
**Symptom**: Contact nickname reverts after restart  
**Root Cause**: Local update but no server sync; or sync failure not handled  
**Fix in Swift**: Confirm server response before updating local cache

---

## 6. Acceptance Criteria Checklist

### Authentication
- [ ] Email signup with mandatory verification
- [ ] 6-digit OTP input with auto-advance
- [ ] 60s resend cooldown with timer
- [ ] Google Sign-In (block if email exists)
- [ ] Forgot password with email reset
- [ ] Proper error messages (not raw JSON)

### Messaging
- [ ] Send text/image/file/voice
- [ ] Delivery status indicators
- [ ] Blue (WiFi) vs Purple (Mesh) colors
- [ ] Voice with actual duration + waveform
- [ ] Reply quote feature
- [ ] Scheduled messages with picker

### Inbox
- [ ] Realtime updates without entering chat
- [ ] Unread badge count
- [ ] Last message preview
- [ ] Deep link from push notification

### Media
- [ ] Shared media tab (all files from both parties)
- [ ] Photo preview with zoom
- [ ] PDF viewer
- [ ] Voice playback with progress

### Search
- [ ] Horizontal people results
- [ ] Vertical post results
- [ ] Avatar loading OK
- [ ] No overflow/clipping issues

### Account
- [ ] Profile header with avatar, name, bio, tags
- [ ] Bio/tags persistence after restart
- [ ] Membership date display

---

## 7. Architecture for Swift Rewrite

### Recommended Stack
- **UI**: SwiftUI
- **Networking**: URLSession + async/await
- **Storage**: SQLite via GRDB or SwiftData
- **Authentication**: Keychain for tokens
- **Push**: APNs / Firebase Cloud Messaging
- **Audio**: AVFoundation
- **Images**: Kingfisher or AsyncImage

### Folder Structure
```
RAVEN/
├── App/
│   ├── RAVENApp.swift
│   └── AppState.swift
├── Features/
│   ├── Auth/
│   ├── Chat/
│   ├── Contacts/
│   ├── Feed/
│   ├── Notifications/
│   ├── Profile/
│   └── Settings/
├── Core/
│   ├── Networking/
│   ├── Storage/
│   ├── Crypto/
│   └── Mesh/
├── Components/
│   └── LiquidGlass/
└── Services/
    ├── PushService.swift
    ├── DeepLinkService.swift
    └── MediaService.swift
```

---

## 8. Migration Priority Order

1. **Auth** (email verify, forgot password, Google)
2. **Messages Inbox** (realtime, badges, previews)
3. **Chat** (attachments atomic, voice duration, delivery colors)
4. **Shared Media** (both parties, playback)
5. **Search** (horizontal/vertical layout)
6. **Account** (header layout, bio persistence)
7. **Mesh/DTN** (optional, can be Phase 2)

---

*Document generated: 2026-01-30*
