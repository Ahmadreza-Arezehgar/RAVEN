# Raven Offline Mailbox Transport V1

**Protocol:** `/raven/offline-mailbox/1.0.0`  
**Status:** Real interoperability profile; production-disabled security hold  
**Record:** [`RAVEN_STORE_OBJECT_V1.md`](RAVEN_STORE_OBJECT_V1.md)

This profile carries opaque `StoreObjectV1` rows over a Noise-authenticated
libp2p connection. The store sees ciphertext size, timing, source PeerId, and
reuse of a 16-byte `store_tag`. It does not receive a username, Raven address,
conversation identifier, route key, mailbox key, or plaintext message.

The profile is compiled only by the non-default Cargo feature
`experimental-offline-mailbox`. Its separate executable also requires
`--allow-experimental-mailbox`. The default `raven-swarm` binary neither
advertises nor accepts this protocol while production ATSAM session activation
is held.

## 1. Request wire

All integers are unsigned big-endian. A request is exactly one of:

```text
PUT = 0x01 || object_len_u32 || packed_StoreObjectV1

GET = 0x02 || store_tag_16 || has_after_u8 || after_token_32
           || page_limit_u16
```

`has_after` is `0` or `1`. When it is `0`, `after_token` MUST be 32 zero
bytes. `page_limit` is `1..16`. `GET` accepts only the store-facing rotating
mailbox capability; no API derives it from the per-envelope `routing_tag`.

## 2. Response wire

```text
STORED  = 0x00

OBJECTS = 0x01 || has_next_u8 || next_token_32 || count_u16
                 || repeated(count, object_len_u32 || packed_StoreObjectV1)

REJECTED = 0x02 || code_u8
```

Rejection codes are `1=malformed`, `2=store_full`, `3=expired`, `4=TTL`, and
`5=persistence`. Unknown codes and noncanonical/trailing bytes are protocol
errors.

The continuation token is:

```text
SHA-256("raven/offline-mailbox/page-token/v1" || packed_StoreObjectV1)
```

Rows are sorted by this token. `next_token` is the last returned token when
more rows remain. This makes pagination stable when an earlier row expires;
the token is opaque and is useful only with knowledge of the `store_tag`.

## 3. Hard resource limits

| Resource | Limit |
|---|---:|
| Packed Raven envelope | 1 MiB |
| Packed StoreObjectV1 | 1 MiB + 123 bytes |
| Request frame | 1 MiB + 128 bytes |
| Response frame | 4 MiB |
| Objects per response | 16 |
| Objects per `store_tag` | 64 |
| Concurrent request streams | 32 |
| Request/response deadline | 8 seconds |
| Store rows / bytes | 4,096 / 64 MiB |
| Maximum network mailbox TTL | 7 days |
| Allowed future creation skew | 5 minutes |

Decoders read at most the frame limit plus one byte and reject overflow before
parsing attacker-controlled lengths. A PUT is acknowledged only after the
strict StoreObject and inner RavenEnvelope decoders accept it, resource/TTL
checks pass, and the private atomic mailbox snapshot is fsynced and renamed.
Startup fails closed on a corrupt, oversized, symlinked, multiply-linked, or
non-private Unix snapshot.

## 4. Deletion and acknowledgements

V1 exposes no delete opcode. Objects disappear only through expiry. A sealed
ACK is opaque to the store and never authorizes deletion. An early-deletion
capability, if later designed, requires a new protocol version and exact-object
cryptographic authorization.

## 5. Executable evidence

- `raven-swarm::mailbox` unit tests exercise strict/noncanonical bounds and a
  real localhost libp2p PUT followed by sender disconnect, store restart, and
  byte-identical GET from a new client.
- `node/scripts/swarm_mailbox_smoke.sh` performs the same process-level restart
  path using the explicitly gated binary.
