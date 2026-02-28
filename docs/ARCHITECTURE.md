# Raven Architecture: Server-First + Offline/Mesh

## Overview

Raven uses a **Server as Source of Truth, Device as Cache + Queue + Router** model.

```
┌─────────────────────────────────────────────────────────────┐
│                        SERVER (Truth)                       │
├─────────────────────────────────────────────────────────────┤
│  users, sessions, friends, friend_requests                  │
│  posts, hashtags, media URLs, search index                  │
│  messages metadata (delivered/seen)                         │
│  notification feed                                          │
└─────────────────────────────────────────────────────────────┘
                              ▲
                              │ Sync when online
                              │ Bridge upload when available
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                     DEVICE (Cache + Queue)                  │
├─────────────────────────────────────────────────────────────┤
│  cached posts/messages                                      │
│  outbox queue (pending)                                     │
│  mesh routing (ttl, hopCount, sprayCounter)                 │
│  encryption keys + device identity                          │
│  local delivery receipts (until sync)                       │
└─────────────────────────────────────────────────────────────┘
```

---

## Server Responsibilities (Source of Truth)

| Data | Why Server |
|------|-----------|
| `users`, `sessions` | Security, auth, device management |
| `friends`, `friend_requests` | Multi-user state must be consistent |
| `posts`, `media URLs` | Searchable, shareable, reportable |
| `hashtags`, `search index` | Cross-user indexing |
| `messages` metadata | Delivered/seen status sync |
| `notifications` | Badge counts, event feed |

---

## Device Responsibilities (Offline/Mesh)

| Data | Why Device |
|------|-----------|
| Cached posts/messages | Fast UI, offline viewing |
| Outbox queue | Send when online/bridged |
| Mesh routing metadata | TTL, hopCount, sprayCounter |
| Encryption keys | Never leave device |
| Local receipts | Sync to server later |

---

## Duplicate Prevention (Critical)

### Rule: Every message has a **Global Unique ID**

```dart
// Generated on client BEFORE sending
final messageId = Uuid().v7(); // or ULID
```

### Three-layer deduplication:

1. **Client SQLite**: Check before INSERT
2. **Server DB**: UNIQUE constraint on `message_id`
3. **Mesh Router**: `_seenMessageIds` set

```sql
-- Server
CREATE UNIQUE INDEX idx_messages_id ON messages(id);

-- Insert is idempotent
INSERT INTO messages (id, ...) 
ON CONFLICT (id) DO NOTHING;
```

---

## Mesh Scenarios

### Scenario 1: Bridge to Server

```
A (offline) → Mesh → B (has internet) → Server → C
                     ↑
                   Bridge
```

1. A creates message with unique `message_id`
2. Message goes to outbox + Mesh broadcast
3. Bridge B receives, POSTs to server
4. Server checks `message_id`: new? save : ignore
5. Bridge sends ACK back through Mesh
6. A updates status to "delivered"

### Scenario 2: Pure Mesh Delivery

```
A (offline) → Mesh → Mesh → Mesh → B (offline)
```

1. Message broadcasts with TTL/hopCount
2. B receives, creates local receipt
3. B sends SEEN ACK through Mesh
4. Later when online, B syncs receipt to server
5. Server notifies A

---

## Server Endpoints (Required)

All endpoints must be **idempotent** on IDs:

| Endpoint | Idempotent Key |
|----------|---------------|
| `POST /messages` | `message_id` |
| `POST /posts` | `post_id` |
| `POST /receipts` | `receipt_id` or `(message_id, status)` |
| `POST /friend-requests` | `(requester_id, recipient_id)` |

---

## Checklist for Implementation

- [ ] Server DB schema: users, friends, friend_requests, posts, hashtags, messages, receipts, notifications
- [ ] UNIQUE constraints on message_id, post_id
- [ ] Idempotent endpoints (ON CONFLICT DO NOTHING)
- [ ] SQLite migrations for DTN columns
- [ ] Outbox queue with retry policy
- [ ] Mesh packet format: message_id, ttl, hopCount, signature, createdAt
- [ ] Dedupe set in router (`_seenMessageIds`)
