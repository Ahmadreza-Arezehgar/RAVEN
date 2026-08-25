# Task 0A — Physical iPhone SQLCipher checklist

Lab-only. Not a production gate. Signed-simulator CI covers API/order/crash/cross-provider; this checklist is the remaining physical-device stop-line for Independent Task 0A evidence when a device is available.

## Required before claiming device durability evidence

- [ ] Main app provisioning includes `group.app.raven.fullbraid` (App Group + Keychain access group).
- [ ] Extensions/watch/Catalyst still lack that entitlement.
- [ ] Create/open App Group profile DB on device; `cipher_provider=commoncrypto`, `cipher_status=1`, header=32.
- [ ] Kill app mid-uncommitted / mid-committed WAL / post-checkpoint; reopen yields only valid old-or-new state.
- [ ] Independently swapped WAL/SHM rejected without recreation.
- [ ] High-entropy sentinel absent from DB/WAL/SHM after checkpoint.
- [ ] Lock/unlock and complete-until-first-auth Data Protection: store refuses unlock-required paths with typed failure (no fallback).
- [ ] Release/App Store path still cannot enable Full Braid durable storage.

## CI contract

GitHub Actions asserts this file exists and retains the section headers above. It does not execute the device steps.
