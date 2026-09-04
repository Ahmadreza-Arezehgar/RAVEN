# Org Structure — 5 Domains, 20 Roles

## Domains

| Domain | Scope | Roles |
|--------|-------|-------|
| **D1 — Architecture & Protocol** | System shape, wire contracts, versioning, Raven↔RDAP alignment | #1–#4 |
| **D2 — Crypto & Core Runtime** | Crypto, identity primitives, core agent/runtime | #5–#8 |
| **D3 — Network & Transport** | Networking, transports, reliability, perf | #9–#11 |
| **D4 — Platforms & RDAP** | Apple, Windows, RDAP agent protocol surface | #12–#16 |
| **D5 — Assurance & Release** | Security assurance, QA/interop, CI/release | #17–#20 |

## Roles (#1–#20)

| # | Title (short) | Domain |
|---|---------------|--------|
| 1 | Principal Architect | D1 |
| 2 | Protocol Lead | D1 |
| 3 | Spec & Versioning Owner | D1 |
| 4 | Raven↔RDAP Interop Architect | D1 |
| 5 | Crypto Lead | D2 |
| 6 | Identity Lead | D2 |
| 7 | Core Runtime Lead | D2 |
| 8 | Core Libraries Owner | D2 |
| 9 | Network Lead | D3 |
| 10 | Transport Lead | D3 |
| 11 | Performance Owner | D3 |
| 12 | Apple Platform Lead | D4 |
| 13 | Windows Platform Lead | D4 |
| 14 | RDAP Protocol Lead | D4 |
| 15 | RDAP Runtime Owner | D4 |
| 16 | Agent UX / Tooling Owner | D4 |
| 17 | Security Assurance Lead | D5 |
| 18 | Interop & QA Lead | D5 |
| 19 | Release Engineering Lead | D5 |
| 20 | CI / DevEx Owner | D5 |

## Boards & management

| Body | Members (by role) | Mandate |
|------|-------------------|---------|
| **Architecture Board** | #1 (chair), #2, #4, #7 | Normative architecture, protocol version bumps, cross-domain design |
| **Engineering Management** | Staffing & delivery authority over #1–#20 (not a merge bypass) | Prioritization, hiring, sprint capacity — **cannot** waive R3 self-merge ban |
| **Security Board** | #5, #6, #17 (chair), + #1 as non-voting consult | Trust boundaries, crypto/identity review, R3 security second approval |

## Org chart (text)

```
Engineering Management
├── Architecture Board (#1 chair)
│   ├── D1 Architecture & Protocol
│   │   ├── #1 Principal Architect
│   │   ├── #2 Protocol Lead
│   │   ├── #3 Spec & Versioning Owner
│   │   └── #4 Raven↔RDAP Interop Architect
│   └── (consults D2–D5 leads)
├── Security Board (#17 chair)
│   ├── #5 Crypto Lead
│   ├── #6 Identity Lead
│   └── #17 Security Assurance Lead
├── D2 Crypto & Core Runtime
│   ├── #5 Crypto Lead
│   ├── #6 Identity Lead
│   ├── #7 Core Runtime Lead
│   └── #8 Core Libraries Owner
├── D3 Network & Transport
│   ├── #9 Network Lead
│   ├── #10 Transport Lead
│   └── #11 Performance Owner
├── D4 Platforms & RDAP
│   ├── #12 Apple Platform Lead
│   ├── #13 Windows Platform Lead
│   ├── #14 RDAP Protocol Lead
│   ├── #15 RDAP Runtime Owner
│   └── #16 Agent UX / Tooling Owner
└── D5 Assurance & Release
    ├── #17 Security Assurance Lead
    ├── #18 Interop & QA Lead
    ├── #19 Release Engineering Lead
    └── #20 CI / DevEx Owner
```

Team handles map to domains via `06-github-teams.md` (`@Raven-ASHCO/architecture`, `@Raven-ASHCO/crypto`, …).
