# RAVEN Messaging Product Boundary V1

**Document type:** binding product boundary (not a wire/crypto profile)

**Date:** 2026-08-21

**Status:** **BINDING OWNER DIRECTION**

**Production effect:** Raven MUST be presented, implemented and reviewed as a
private messaging application. This document enables no runtime feature.

> Raven moves private messages between people and their explicitly joined
> devices. It is not a social network, feed, publishing platform, public
> repository browser, audience marketplace, or engagement product.

## 1. Allowed product surfaces

Raven may provide:

- one-to-one private messaging;
- explicitly invited private group messaging using an approved group protocol;
- voice/video calls and realtime communication between accepted participants;
- private file/media/voice-message transfer;
- local contacts, device verification, block and revocation;
- user-owned encrypted archives and explicit device/conversation handoff;
- direct LAN, BLE/mesh, Internet, relay, mailbox and bridge carriers for the
  same private endpoint objects;
- local-only search, organization, notification and accessibility controls;
- address/handle resolution whose only product purpose is finding a person the
  user intends to message or verify.

Private groups remain messaging conversations. They do not become public
communities, public channels, follower audiences, or discoverable content hubs.

## 2. Out-of-product surfaces

Raven MUST NOT ship or market:

- public or stranger-visible feeds/timelines/stories;
- follower/following/subscriber graphs or counts;
- public posts, reactions, reposts, quote-posts or engagement counters;
- public creator/profile pages or public audience growth tools;
- algorithmic content discovery, trending, recommendations or engagement
  ranking;
- public social repositories, public firehoses, public content mirrors, or
  unauthenticated stranger inventory;
- advertising, sponsored attention, influencer analytics, dwell tracking, or
  remote ranking/notification control;
- “community” semantics that allow public publishing or discovery outside an
  explicitly invited encrypted group conversation.

Minimal identity cards, device certificates, revocation records, prekeys and
opaque reachability hints exist only to establish private communication. Their
availability does not create a public profile or social graph.

## 3. Architecture consequences

1. `endpoint_object_bytes` are private sealed messaging/session/control
   objects, except narrowly approved public security records such as device
   revocation. Public content objects are not an allowed endpoint class.
2. Object Sync is contact/session-local reconciliation only. It cannot become
   public repository sync or stranger inventory.
3. ID Resolution returns bounded identity/device candidates for an intentional
   messaging action. It cannot return feeds, public repositories, popularity,
   content recommendations or follower state.
4. Carriers remain opaque and cannot expose public content APIs.
5. Archives contain messaging data selected by the user. Social follow state,
   public posts/repositories and engagement behavior are not product data.
6. Private groups, if approved, use explicit invitations and participant
   membership; they are listed with conversations, not a public discovery tab.
7. No protocol approval or feature flag may weaken this boundary. Changing it
   requires a new explicit owner decision, not an implementation convenience.

## 4. Existing experimental social drafts

Any current dirty-worktree document whose purpose is a public social graph,
feed, post, follower relationship, public repository, public community,
attention marketplace, or stranger content discovery is classified as:

```text
ABANDONED EXPERIMENT / OUTSIDE RAVEN PRODUCT
```

In particular this includes the experimental families named
`RAVEN_SOCIAL_*`, `RAVEN_SOVEREIGN_SOCIAL_GRAPH_*`, and
`RAVEN_PUBLIC_REPOSITORY_SYNC_*`, plus public-feed portions of any community or
archive draft. They are not approval prerequisites, companions, migration
targets, vectors, implementation plans, or future Release surfaces. Retaining
their untracked files for historical review does not authorize code.

Messaging-useful ideas from an abandoned draft (for example local anti-spam,
media authenticity, or private-group governance) may return only in a newly
named messaging companion that independently satisfies this boundary.

## 5. UX and telemetry test

Every proposed feature must answer “which explicit private conversation or
intentional contact action owns this surface?” If the answer is none, the
feature is outside Raven.

Release review must verify:

- no Feed/Explore/Followers/Trending/Public Profile navigation;
- no public-post/reaction/follower database or network callsite;
- no engagement/dwell/recommendation telemetry;
- no stranger content inventory or public repository endpoint;
- App Store, website and in-app language consistently call Raven a private
  decentralized messaging app.

## 6. Relationship to decentralization

Decentralization in Raven means that no mandatory provider owns identity,
trust, message history, routing or availability. It does not mean converting
private messaging into public publication. Direct carriers, replaceable relays,
offline mailboxes, user-owned archives and local cryptographic verification
serve private conversation continuity.

