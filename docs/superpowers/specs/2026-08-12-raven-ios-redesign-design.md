# RAVEN iOS Redesign — Design Spec (Pass 1: Shell + Chats + Network hub)

**Approved:** 2026-08-12, hybrid direction ("Obsidian base + Aurora signatures").
WhatsApp-inspired structure; base colors black + dark purple; Liquid Glass; unique
RAVEN elements surfacing the serverless story.

## User decisions
- Scope pass 1: design system + 4-tab shell + redesigned Chats list; Contacts/Network/
  Settings get restyled shells (Network gets a real hub view). Chat view untouched.
- Tabs (left→right): **Contacts · Chats · Network · Settings**; Chats is default.
- "Serverless LAN" becomes a user-facing **Network hub** tab (mesh + node/LAN + bridge
  status + rvn1 identity), not a debug form.
- From WhatsApp adopt only: **big title + search bar**. No filter chips, no archived
  row, no camera button.

## Palette (token flip in `Views/Components/RavenDesignTokens.swift`)
| Token | Old | New |
|---|---|---|
| `DS.ink` (base bg) | #0A0D12 near-black | **#000000** pure black |
| `DS.inkElevated` | #171A21 | **#0D0716** (violet-tinted near-black) |
| `DS.charcoal` | #24262E | **#171022** |
| `DS.violet` (new) | — | **#7C3AED** primary accent |
| `DS.violetDeep` (new) | — | **#5B21B6** |
| `DS.violetSoft` (new) | — | **#A78BFA** highlights/rings |
| `DS.cyan` (legacy alias) | #40F2FF | = `violet` (repointed; rename later) |
| `DS.cyanDeep` (legacy alias) | #0DB8D1 | = `violetDeep` |
| `DS.accentPurple` | slate | = `violetSoft` |
| `signalGradient` | cyan family | violet → violetSoft |
| `bubbleOutgoing` | cyan family | violetDeep → violet |
| `inkAura` | cyan radial | faint violet radial |

Semantic colors (danger red, success green, teal) unchanged. Repointing the legacy
alias values re-skins every existing DS consumer in one move; a mechanical
`cyan→violet` rename is a follow-up cleanup, not part of this pass.

## Structure
- `AppTab`: 4 cases — `contacts=0, messages=1, network=2, account=3` (rawValue drives
  the pager offset). Icons: `person.2`, `bubble.left.and.bubble.right`,
  `point.3.connected.trianglepath.dotted`, `gearshape` (+ `.fill` variants).
- `TabPager`: generalized to four pages (contacts/chats/network/settings).
- `MainShellView`: four NavigationStacks — `FindContactsView`, `InboxView`,
  `NetworkHubView` (new), `AccountView`. Floating search FAB **removed** (the Chats
  search bar replaces it; it opens the same `ConversationSearchSheet`). Badge stays on
  Chats tab. `makeQuickActions` covers the two new tabs (empty is acceptable).
- `HapticTabBar`: no structural change (iterates `allCases`); active dot goes violet
  via the token flip.

## Chats list (`InboxView`)
- Large-title "Chats" (34pt bold) + glass search field beneath (tap → existing
  `ConversationSearchSheet`); list scrolls under.
- Rows stay flat on pure black with 0.5pt hairline separators (Obsidian discipline).
- **Aurora signatures** (the unique-RAVEN elements):
  - **Mesh-ring avatar**: 2pt ring on the avatar colored by
    `lastMessage.deliveryAuthority` — mesh → `violet`, server/p2p → `DS.accentBlue`'s
    replacement (violetSoft vs blue kept: use blue #298DFF for internet), none → no ring.
  - **Delivery-path prefix** in the preview line when last message travelled the mesh:
    small `bluetooth`-style SF symbol + "via mesh".
  - **rvn1 styling**: previews starting with `rvn1` render in monospaced font.
  - Unread badge: violet capsule (not red, not green).

## Network hub (`Features/Network/NetworkHubView.swift`, new)
Read-mostly glass cards with a large-title "Network":
1. **Identity** — display name, `rvn1` address (monospace, copy), fingerprint, QR
   button (reuses existing QR flow); data via the same whoami/identity surface
   `RavenServerlessLanSettingsView` uses.
2. **Bluetooth mesh** — BLE state, connected peer count from `BLEMeshEngine.shared`,
  liveness dot (green when active).
3. **Serverless node (LAN)** — status line + `NavigationLink` into the existing
   `RavenServerlessLanSettingsView` for configuration (flag-gated behavior preserved).
4. **Internet bridge** — libp2p bridge state (connected/idle) as reported by the
   existing bridge transport surface; degrade gracefully if unavailable.

## Non-goals (this pass)
Chat view/bubbles, Contacts deep redesign, Settings deep redesign, iPad/Mac layouts,
onboarding, app icon. Rename `cyan→violet` across ~all files is deferred cleanup.

## Acceptance
- App builds; all four tabs navigate; Chats shows new title/search/rows; palette is
  black + dark purple everywhere DS tokens are used; Network hub shows live data and
  links to LAN settings; no red unread badges remain in the inbox.
