# Raven iOS UI redesign notes / یادداشت بازطراحی UI

**EN:** 2026 chic redesign for `ios-native/RAVEN` — cyan signal (`#40F2FF`) on ink charcoal, SF Pro hierarchy, atmospheric shell. Networking/crypto unchanged.

**FA:** بازطراحی شیک ۲۰۲۶ — فیروزه‌ای برند روی مشکی عمیق؛ منطق پیام‌رسانی serverless دست‌نخورده.

## Design system (`DS` / `RavenDesignTokens.swift`)

| Token | Value | Role |
|---|---|---|
| `DS.cyan` | `#40F2FF` | Brand signal (site accent) |
| `DS.cyanDeep` / `DS.teal` | deeper cyan/teal | Gradients, CTAs |
| `DS.ink` | near-black | Text on cyan CTAs |
| `DS.signalGradient` | cyan→teal | Primary fills |
| `DS.inkAura` | radial cyan mist | Screen atmosphere |
| Motion | `tabSpring`, `openChatSpring`, `sendPulse` | Tab morph, open chat, CTA press |

Avoided: purple glow cliché, emoji chrome, dense card dashboards.

## Screens touched

- **MainShell** — `RavenScreenBackground` + cyan search FAB  
- **HapticTabBar** — cyan active dot; spring from `DS.tabSpring`  
- **Inbox** — empty state bird motif + primary CTA; filter pills use signal gradient; avatar cyan/teal  
- **Account** — identity hero rebranded (RAVEN wordmark, cyan ring, tagline); settings cards cyan hairline  
- **Discover / FindContacts** — flag-off tip + primary button style  
- **Serverless LAN** row — clear ON / enable-flag label  

## First-stage messaging (unchanged paths, clearer labels)

1. **Account → Serverless LAN · enable flag** → toggle **Serverless · RavenEnvelopeV1** ON  
2. **Discover** → Paste ash whoami / QR  
3. **New Chat** → send (LAN if host/port saved; BLE when peers connected)  

See `docs/FIRST_STAGE_IPHONE_MESSAGE.md`.

## Build

```bash
cd ios-native/RAVEN
xcodebuild -scheme RAVEN -destination 'platform=iOS Simulator,name=iPhone 16' build
```
