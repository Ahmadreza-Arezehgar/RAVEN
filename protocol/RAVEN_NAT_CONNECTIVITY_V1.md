# Raven Experimental NAT Connectivity Profile V1

Status: **production disabled** (2026-08-13). This document specifies the
isolated Rust experiment only. It does not activate NAT traversal in Raven,
does not change the frozen Raven envelope, and does not define a central Raven
service.

## 1. Activation boundary

The profile is absent from default builds. All of the following are required:

1. compile `raven-swarm` with `experimental-nat-connectivity`;
2. select the separate `raven-swarm-connectivity-experimental` binary; and
3. pass `--enable-experimental-nat-connectivity` at runtime.

The main `raven-swarm` binary does not instantiate this behaviour. No relay,
bootstrap, rendezvous, dial, or AutoNAT server address is compiled in. Relay
and dial addresses are accepted only from the operator for that invocation.

## 2. Behaviour and transport composition

The reusable behaviour composes:

- TCP with libp2p Noise authentication and Yamux multiplexing;
- QUIC-v1 with QUIC's authenticated transport security and multiplexing;
- Circuit Relay v2 **client transport**, authenticated with Noise and
  multiplexed with Yamux;
- AutoNAT v2 **client only** (there is no AutoNAT server behaviour);
- DCUtR for direct-connection upgrade over an existing relayed connection;
- Identify using `/raven/connectivity/1.0.0` and Ping; and
- `libp2p-connection-limits` inside the same behaviour tree.

### 2.1 Realtime-media boundary

This libp2p experiment is not WebRTC ICE, STUN, TURN, DTLS-SRTP, RTP/RTCP,
SFrame or an SFU. A Circuit Relay v2 reservation cannot be relabeled a TURN
allocation; DCUtR success cannot be relabeled ICE consent; Noise authentication
cannot be relabeled the call-control/DTLS fingerprint binding required by
[`RAVEN_PRIVATE_REALTIME_MEDIA_V1.md`](RAVEN_PRIVATE_REALTIME_MEDIA_V1.md).

Any future realtime integration needs an independently pinned provider/library
profile, explicit direct-versus-relay privacy consent, consent freshness,
media-specific replay/counter/resource rules and physical tests. This binary
does not advertise, parse, proxy or activate realtime media.

AutoNAT is a reachability signal, not an authorization oracle. A successful
probe must never authenticate a Raven contact, session, message, or relay.
DCUtR only changes the path used by an already authenticated libp2p
connection; it does not replace ATSAM message authentication.

## 3. Fixed resource ceilings

The experiment's default connection budget is:

| Dimension | Default | Compile-time hard maximum |
| --- | ---: | ---: |
| Pending inbound | 8 | 64 |
| Pending outbound | 8 | 64 |
| Established inbound | 24 | 128 |
| Established outbound | 16 | 128 |
| Established total | 32 | 128 |
| Established per peer | 2 | 4 |

Every dimension is configured as `Some(limit)`; there is no unlimited path or
automatic limit bypass. The AutoNAT candidate set defaults to 8 and cannot
exceed 16. Other fixed bounds are a 10-second connection timeout, 90-second
idle timeout, 64 concurrently negotiating inbound streams, 32 buffered
per-connection events, and four concurrent address dials.

The experimental CLI accepts at most eight explicit dial addresses and runs
for at most one hour per invocation.

## 4. Relay selection and address rules

Raven does not operate or prefer a relay in this profile. An operator may
supply one relay multiaddr ending in exactly one `/p2p/<relay-peer>` component.
The client derives a single `/p2p-circuit` reservation address. Addresses that
already contain `/p2p-circuit`, omit the terminal peer, or contain ambiguous
peer components are rejected.

Relay participation is not a trust grant. A relay cannot decrypt an ATSAM
envelope, but it can observe timing, byte counts, its client PeerIds, circuit
counterparties, and network addresses. An AutoNAT server observes the candidate
address it is asked to probe. These services can lie, refuse service, correlate
traffic, or selectively degrade paths.

## 5. Privacy and failure policy

The experimental binary logs event categories only. It does not print
PeerIds, relay/dial/listen addresses, message identifiers, routing tags, or
payloads. Connection, AutoNAT, relay-reservation, and DCUtR failures are local
path failures and do not downgrade ATSAM authentication or expose plaintext.

No payload protocol is attached by this profile. Production integration must
carry only bounded opaque Raven Store Objects or authenticated Raven envelopes
and must retain the endpoint transaction's authenticate-before-durable-write
rule.

## 6. Production hold

Production activation requires, at minimum, completed ATSAM endpoint/session
integration on both Rust and iOS, signed-ACK recovery, abuse testing across
relay and AutoNAT failures, explicit relay policy, mobile lifecycle handling,
and interop soak tests. Until those gates pass, this module and binary remain
experimental and are not a production transport claim.
