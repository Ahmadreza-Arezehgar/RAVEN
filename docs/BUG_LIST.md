# RAVEN - Known Bugs & Edge Cases
> **Version**: 1.1 (Updated)  
> **Purpose**: Document bugs to avoid in Swift native rewrite

---

## 🔒 CRITICAL RULES (Must Be Implemented First)

### Rule 1: Atomic Message Display
```swift
// ✅ UI MUST verify message is complete before displaying
// NEVER show message until validation passes

func shouldDisplayMessage(_ message: ChatMessage) -> DisplayState {
    switch message.type {
    case .text:
        guard let text = message.text, !text.isEmpty else {
            return .hidden
        }
        return .ready
        
    case .image, .file:
        switch message.syncState {
        case .synced:
            return .ready
        case .uploading:
            return .uploading(progress: message.uploadProgress)
        case .failed:
            return .failed(error: message.lastError)
        case .localOnly, .queued:
            if message.localPath != nil {
                return .uploading(progress: 0)
            }
            return .hidden
        }
        
    case .voice:
        guard message.audioDurationSeconds != nil else {
            return .hidden // Don't show 0:00 duration
        }
        return message.syncState == .synced ? .ready : .uploading(progress: 0)
        
    case .location:
        return .ready
    }
}

enum DisplayState {
    case hidden
    case uploading(progress: Double)
    case ready
    case failed(error: String?)
}
```

> ⚠️ THIS PREVENTS: "Image shows as [Image] text first"

---

### Rule 2: ConversationStore Contract
```swift
// ✅ Central source of truth for Inbox
@Observable class ConversationStore {
    // MARK: - Data
    var conversations: [Conversation] = []
    
    // MARK: - Sources
    // 1. Local DB (SwiftData/GRDB) - primary cache
    // 2. API polling (/api/conversations) - every 15 seconds
    // 3. Push handler - instant refresh on notification
    
    // MARK: - Merge Rules
    func merge(incoming: [Conversation]) {
        for conversation in incoming {
            if let existing = conversations.first(where: { $0.roomId == conversation.roomId }) {
                // Update if incoming is newer
                if conversation.updatedAt > existing.updatedAt {
                    existing.update(from: conversation)
                }
            } else {
                conversations.append(conversation)
            }
        }
        sortByLastMessage()
    }
    
    // MARK: - Message Idempotency
    func handleIncomingMessage(_ message: ChatMessage) {
        // Check duplicate by message_id
        guard !messageExists(id: message.id) else {
            return // Already have this message
        }
        insertMessage(message)
        updateConversationPreview(for: message.roomId)
    }
}
```

> ⚠️ THIS PREVENTS: "Inbox doesn't update without entering chat"

---

## 1. Critical Bugs (Must Fix First)

### 1.1 Attachment Shows as Text First
**Severity:** High  
**Symptom:** When sending an image/voice/file, it appears as text "[Image]" or "[Voice]" first. After restarting app, correct media appears.

**Root Cause (Suspected):**
- Message inserted before attachment metadata available
- UI not observing updates to attachment fields
- `notifyListeners()` called before data ready

**How to Avoid in Swift:**
```swift
// ❌ Bad: Insert message, then update attachment
insertMessage(message)
message.attachmentUrl = uploadedUrl  // UI won't see this

// ✅ Good: Insert complete message atomically
let completeMessage = ChatMessage(
    text: text,
    attachmentUrl: uploadedUrl,
    attachmentType: .image
)
insertMessage(completeMessage)
```

---

### 1.2 Inbox Doesn't Update Until Entering Chat
**Severity:** High  
**Symptom:** New messages don't appear in conversation list. User must tap into a chat to see updates.

**Root Cause (Suspected):**
- No realtime listener on conversation list screen
- Only chat screen listens for updates
- `unreadCount` and `lastMessage` not updated in contacts

**How to Avoid in Swift:**
```swift
// ✅ Central ConversationStore with background updates
@Observable class ConversationStore {
    var conversations: [Conversation] = []
    
    func startPolling() {
        Timer.publish(every: 10, on: .main, in: .default)
            .sink { [weak self] _ in
                self?.fetchUpdates()
            }
    }
}
```

---

### 1.3 Voice Duration Shows 0:00 or Fixed 10s
**Severity:** High  
**Symptom:** Voice messages show wrong duration (0:00, or always 10 seconds).

**Root Cause (Suspected):**
- Duration not captured from recorder
- `audioDurationSeconds` not stored in database
- Hardcoded fallback value used

**How to Avoid in Swift:**
```swift
// ✅ Capture actual duration from AVAudioRecorder
let player = try AVAudioPlayer(contentsOf: audioURL)
let actualDuration = Int(player.duration)
message.audioDurationSeconds = actualDuration
```

---

## 2. Authentication Bugs

### 2.1 Email Verification Not Received
**Severity:** High  
**Symptom:** Users don't receive verification emails.

**Root Cause (Suspected):**
- SMTP/SendGrid misconfigured
- Emails going to spam
- Client silent fail on API error

**How to Avoid in Swift:**
```swift
// ✅ Show clear error states
switch result {
case .success:
    showMessage("Code sent! Check spam folder")
case .failure(let error):
    showError("Failed to send: \(error.localizedDescription)")
}
```

---

### 2.2 Forgot Password Flow Broken
**Severity:** Medium  
**Symptom:** Password reset doesn't work or silently fails.

**Root Cause (Suspected):**
- Same SMTP issues as verification
- Token expiry too short
- Error not displayed to user

**Fix:** Same as 2.1 - proper error handling

---

## 3. Persistence Bugs

### 3.1 Nickname Not Saved
**Severity:** Medium  
**Symptom:** Contact nickname reverts to username after restart.

**Root Cause (Suspected):**
- Local update without server sync
- Sync failure not handled
- Data overwritten on next fetch

**How to Avoid in Swift:**
```swift
// ✅ Optimistic update + server confirm
func setNickname(contactId: String, nickname: String) async {
    // 1. Optimistic local update
    updateLocalNickname(contactId, nickname)
    
    // 2. Server sync
    do {
        try await api.updateNickname(contactId, nickname)
    } catch {
        // 3. Revert on failure
        revertLocalNickname(contactId)
        showError("Failed to save nickname")
    }
}
```

---

### 3.2 Bio/Tags Not Persisted
**Severity:** Medium  
**Symptom:** Profile bio and tags revert after restart.

**Root Cause:** Same as nickname - local vs server sync issues

---

## 4. UI/UX Bugs

### 4.1 Search Avatar Overflow
**Severity:** Low  
**Symptom:** Avatars in search results clip or overflow bounds.

**How to Avoid in Swift:**
```swift
// ✅ Proper clipping
AsyncImage(url: URL(string: avatarUrl))
    .frame(width: 44, height: 44)
    .clipShape(Circle())
```

---

### 4.2 Chat Header Overflow
**Severity:** Low  
**Symptom:** Long names cause "OVERFLOWED BY X PIXELS" error.

**How to Avoid in Swift:**
```swift
// ✅ Constrain text
Text(userName)
    .lineLimit(1)
    .truncationMode(.tail)
    .frame(maxWidth: 200)
```

---

### 4.3 Search Layout Wrong
**Severity:** Medium  
**Symptom:** Expected horizontal people + vertical posts, but layout is different.

**How to Avoid in Swift:**
```swift
// ✅ Correct layout
VStack {
    // Horizontal people scroll
    ScrollView(.horizontal) {
        LazyHStack { ... }
    }
    
    // Vertical posts list
    LazyVStack { ... }
}
```

---

## 5. Sync & Realtime Bugs

### 5.1 Shared Media Missing Items
**Severity:** Medium  
**Symptom:** Shared media tab doesn't show all files from both parties.

**Root Cause (Suspected):**
- Only fetching sender's media
- Filtering by direction incorrectly

**How to Avoid in Swift:**
```swift
// ✅ Fetch all media in conversation (both directions)
let media = await db.messages
    .filter("roomId == %@ AND type IN %@", roomId, ["image", "file", "voice"])
    .sorted(by: \.timestamp, ascending: false)
```

---

### 5.2 Message Status Not Updating
**Severity:** Medium  
**Symptom:** "Sent" stays even after read by recipient.

**Root Cause (Suspected):**
- No polling for read receipts
- Status not being observed

**How to Avoid in Swift:**
```swift
// ✅ Poll for status updates or use WebSocket
func observeMessageStatus(messageId: String) {
    // WebSocket or polling for read_at updates
}
```

---

## 6. Deep Link Bugs

### 6.1 Notification Tap Doesn't Open Chat
**Severity:** High  
**Symptom:** Tapping notification opens app but not the correct chat.

**Root Cause (Suspected):**
- Deep link payload not parsed
- Chat ID not extracted
- Navigation not triggered

**How to Avoid in Swift:**
```swift
// ✅ Handle notification payload
func userNotificationCenter(_ center: UNUserNotificationCenter,
                            didReceive response: UNNotificationResponse) {
    let userInfo = response.notification.request.content.userInfo
    if let chatId = userInfo["chat_id"] as? String {
        navigate(to: ChatView(chatId: chatId))
    }
}
```

---

## 7. Edge Cases

### 7.1 OAuth Email Conflict
**Scenario:** User signs up with email, then tries Google Sign-In with same email.

**Expected:** Block login, show "Email already registered"  
**Bug If:** Creates duplicate account or throws cryptic error

---

### 7.2 Scheduled Message Past Time
**Scenario:** User schedules message for 1 hour ago (time zone issue).

**Expected:** Send immediately or show error  
**Bug If:** Message stuck in limbo

---

### 7.3 Offline Send → Online Sync
**Scenario:** User sends message offline, comes online later.

**Expected:** Message syncs to server, recipient receives  
**Bug If:** Message lost or duplicated

---

### 7.4 Large File Upload
**Scenario:** User sends 100MB video.

**Expected:** Progress indicator, graceful timeout/retry  
**Bug If:** App freezes, silent failure, or crash

---

### 7.5 Rapid Message Send
**Scenario:** User taps send button 10 times quickly.

**Expected:** Only 1 message sent (debounce)  
**Bug If:** 10 duplicate messages created

---

## 8. Testing Checklist

Before each release, verify:

- [ ] Send text message → appears immediately in chat
- [ ] Send image → shows image (not [Image])
- [ ] Send voice → shows correct duration
- [ ] Check inbox → new messages visible without entering chat
- [ ] Email verification → code received within 2 minutes
- [ ] Forgot password → reset link works
- [ ] Set nickname → persists after restart
- [ ] Set bio → persists after restart
- [ ] Tap notification → opens correct chat
- [ ] Search → horizontal people, vertical posts
- [ ] Shared media → shows all files from both users

---

*Document generated: 2026-01-30*
