# RAVEN User-Owned Agent Runtime V1

**Version:** 1 (architecture/security/privacy draft; wire and runtime profile not frozen)

**Document revision:** 1

**Date:** 2026-08-21

**Status:** **REQUIRED / NOT YET APPROVED**

**Production:** **disabled** — this document authorizes no autonomous agent,
model download, remote-model provider, Foundation Models tool, MCP/UCAN/WASI
dependency, plugin, shell, filesystem or network tool, bot identity, agent key,
capability codec, memory store, database migration, background automation,
message send, contact/room/moderation action, payment, live callsite, Release
flag, or change to the existing iOS AI surface

**Approval prerequisites:**
[`RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md`](RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md),
[`RAVEN_IDENTITY_CONTINUITY_V2.md`](RAVEN_IDENTITY_CONTINUITY_V2.md),
[`RAVEN_DEVICE_REVOCATION_V1.md`](RAVEN_DEVICE_REVOCATION_V1.md),
[`RAVEN_SOCIAL_OBJECT_WIRE_V1.md`](RAVEN_SOCIAL_OBJECT_WIRE_V1.md),
[`RAVEN_ATTENTION_FIREWALL_V1.md`](RAVEN_ATTENTION_FIREWALL_V1.md), and
[`RAVEN_USER_OWNED_ARCHIVE_V1.md`](RAVEN_USER_OWNED_ARCHIVE_V1.md) must be
**APPROVED** for every selected integration. Community bots additionally require
[`RAVEN_SOVEREIGN_COMMUNITIES_V1.md`](RAVEN_SOVEREIGN_COMMUNITIES_V1.md).
AI-media publication additionally requires
[`RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md`](RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md).

**Non-interference:** this draft does not reinterpret a Raven user/device
signature as an agent signature, does not turn a model response into authority,
does not make a bot a contact or room member, and does not weaken ATSAM, MLS,
block, revocation, Attention, archive, bridge, carrier or delivery semantics.
Existing smart replies and summaries remain a separate legacy assistance
surface and acquire no tool or side-effect authority from this document.

---

## 0. Constitutional decision

Raven treats useful intelligence and delegated authority as different systems:

```text
Untrusted social/context bytes  -> evidence supplied to inference
Model inference                 -> fallible recommendation or typed proposal
Capability verifier             -> maximum action the owner delegated
Deterministic policy            -> whether this exact proposal is eligible
Human approval                  -> consent to exact high-impact action bytes
Transactional executor          -> one committed side effect plus receipt
Attention policy                -> whether/when any result interrupts the user
```

The governing rule is:

> A model may propose an action. It cannot grant itself authority, broaden a
> capability, approve its own proposal, impersonate the owner, or convert text
> found in a message, webpage, attachment, memory or tool result into policy.

Raven's differentiator is not an omnipotent assistant inside every private
conversation. It is a **replaceable, user-owned, least-authority agent runtime**
whose data access, model, tools, spending, side effects and attribution are
locally inspectable and independently revocable.

The words MUST, MUST NOT, SHOULD and MAY are interpreted as in BCP 14 when
capitalized.

### 0.1 Honest limits

- On-device inference reduces provider disclosure; it does not make model
  output correct, non-manipulable, deterministic or authorized.
- Instructions and safety filters reduce some failures; they are not a proof
  against direct or indirect prompt injection.
- A typed tool call constrains syntax; it does not establish user intent.
- A sandbox limits available effects; it does not prove the effects are wise.
- A valid capability proves bounded delegation; it does not prove that a model
  selected the right action or that a human understood it.
- Remote inference necessarily exposes the explicitly selected plaintext to
  the named provider boundary. Raven E2EE does not extend through that provider.
- Stochastic model output may not be reproducible. Raven records evidence and
  receipts; it does not promise deterministic regeneration.
- Partitioned revocation cannot be instantly global. A local executor must use
  current locally accepted revocation evidence and conservative expiry.

---

## 1. Goals and non-goals

### 1.1 Goals

| Goal | Required property |
|---|---|
| AR1 | Keep model reasoning outside the trusted authorization base |
| AR2 | Make every agent a distinct principal, never an invisible user impersonator |
| AR3 | Bind authority to exact resource, action, audience, limits and expiry |
| AR4 | Treat messages, media, webpages, memories and tool outputs as untrusted data |
| AR5 | Require exact human confirmation for high-impact or newly widened effects |
| AR6 | Support useful offline/on-device assistance without network or tool authority |
| AR7 | Permit replaceable local/self-hosted models without one Raven AI provider |
| AR8 | Preserve private-room membership and bot disclosure boundaries |
| AR9 | Attribute agent-assisted and autonomous outputs honestly without leaking private assistance metadata by default |
| AR10 | Keep agent memory encrypted, scoped, exportable and independently deletable |
| AR11 | Make proactive work rate-bounded, crash-safe, reviewable and easy to stop |
| AR12 | Let Attention policy—not the agent—decide ranking, notification and interruption |

### 1.2 Non-goals

V1 does not define or authorize:

- a Raven-operated global assistant, model API, plugin marketplace or MCP hub;
- arbitrary shell, process spawn, dynamic library, downloaded executable,
  unrestricted WASI, AppleScript, browser automation or raw socket access;
- ambient access to every message, contact, room, file, calendar, microphone,
  camera, location, HealthKit record, credential or signing key;
- autonomous payments, account recovery, key rotation, device revoke, contact
  trust, legal consent, emergency calls or destructive deletion;
- a model deciding whether its own prompt/tool output is trustworthy;
- silent remote inference or a claim that provider-visible plaintext remains
  end-to-end encrypted;
- treating an AI detector, model output, embedding or inferred identity as
  authentication, consent, provenance, moderation authority or truth;
- agent-created follows, joins, invites, blocks, reports or moderation actions
  merely because a natural-language message requested them;
- downloaded code in an Attention ranking recipe;
- hiding a bot inside a bridge, relay, SFU, mailbox, mirror or room coordinator;
- universal compatibility with MCP, UCAN, OpenAI, Apple, Google or any other
  provider/protocol. Adapters remain optional and separately pinned.

---

## 2. Threat model

The runtime considers:

- direct prompt injection by the user or a malicious local application;
- indirect prompt injection in a Raven message, social post, profile, webpage,
  attachment, OCR result, calendar event, contact field, archive, memory or tool
  response;
- a model that hallucinates, conceals uncertainty, emits malformed arguments,
  attempts tool escalation or strategically asks for broader permission;
- a malicious or compromised model/provider, model update, tokenizer, prompt
  template, tool adapter, plugin package or agent operator;
- cross-chat/context confusion that exposes one contact or room to another;
- confused-deputy and token-passthrough attacks at a remote tool boundary;
- capability replay, audience substitution, stale grant use, delegation fork,
  quota double spend, approval reuse, action substitution and crash recovery;
- exfiltration through tool arguments, URLs, DNS, filenames, generated media,
  logs, diagnostics, notifications or model-provider prompts;
- an agent using summaries/recommendations to manipulate local Attention;
- an explicit bot amplifying spam, coordinating Sybils or retaining room data;
- a local attacker rolling back app storage but not protected capability heads;
- denial of service through context bombs, recursive plans, tool loops, output
  floods, huge schemas, attachment expansion or concurrent tasks;
- coercive or deceptive UI that makes a model-generated explanation look like
  a human confirmation.

The design cannot prove that a model is aligned, that a remote provider erased
data, that a user read an approval, or that a proposed action is socially wise.
It guarantees narrower properties: explicit principals, least authority,
bounded context, deterministic enforcement, honest attribution and auditable
side-effect commits.

---

## 3. Principals and non-impersonation

### 3.1 Principal classes

| Principal | Authority source | May sign as user? |
|---|---|---|
| `USER_DEVICE` | Current Raven device certificate and local user action | Yes, only through existing Raven signing path |
| `LOCAL_ASSISTANT` | No network identity; pure/draft assistance only | No |
| `USER_AGENT_DEVICE` | Distinct agent credential delegated by the owner | No; signs as named agent |
| `COMMUNITY_BOT` | Explicit bot identity/device/MLS leaf and governance capability | No |
| `REMOTE_TOOL_SERVICE` | Its own authenticated service identity and scoped token | No |
| `MODEL_PROVIDER` | Provider/model manifest only; never Raven authority | No |

Display-name similarity, a shared model, owner relationship or local process
does not merge principals. An agent credential MUST NOT contain the owner's
private signing seed or ATSAM/MLS roots. A signing service accepts only a
pre-authorized exact agent record and never raw model text.

### 3.2 Three honest output modes

1. **Recommendation/draft.** No network action. The user may edit or discard it.
2. **User-confirmed draft.** The UI shows the exact final bytes and audience;
   the user explicitly invokes the normal user send/publish action. The result
   is a user-device action. Private local audit MAY record assistance, but Raven
   does not force private smart-reply disclosure to peers.
3. **Delegated agent action.** A distinct agent credential signs/attests the
   action under a bounded grant. UI and recipients see that it is an agent,
   its owner/operator where policy permits, and the applicable provenance.

An autonomous action MUST use mode 3. It cannot be converted into mode 2 by
copying model output into a hidden user-signing call.

### 3.3 Agent descriptor

A later exact profile will bind an immutable agent descriptor to:

- agent and owner continuity identifiers;
- exact agent/device signing and agreement keys;
- runtime/model/tool manifest digests;
- execution locality (`ON_DEVICE`, `OWNER_HOST`, `REMOTE_PROVIDER`);
- operator, retention, network and data-processing disclosures;
- creation/expiry and revocation lineage; and
- supported—not automatically granted—capability classes.

The descriptor is identity/provenance evidence only. It grants no action.

---

## 4. Six-plane separation

Every operation crosses six independent planes:

| Plane | Question | Authority | Must never decide |
|---|---|---|---|
| Context admission | Which exact data may this run observe? | Local context policy + audience/contact/room state | Tool authority or side effects |
| Inference | Which model/config may compute a proposal? | Selected model manifest | Authorization or truth |
| Capability | What action could this agent ever invoke? | Verified grant chain + current revoke | Whether this proposal is desirable |
| Approval | Does this exact effect need current human consent? | Deterministic policy + trusted UI | Model-generated text |
| Execution | Did one exact effect commit? | Typed executor + transaction journal | Ranking or user interruption |
| Attention | When/how is result shown? | Local Attention policy | Capability or execution success |

Success in one plane never silently advances another. In particular, content
admitted for summarization is not authority; a capability is not approval; a
committed draft is not a sent message; and delivery is not user attention.

---

## 5. Automation levels

| Level | Meaning | V1 default |
|---|---|---|
| `L0_LOCAL_TRANSFORM` | Summary, translation, classification, smart-reply draft over explicitly selected local context | Eligible after dedicated review |
| `L1_READ_ONLY` | Bounded query through typed local projection; no external write | Disabled until capability/runtime profiles pass |
| `L2_DRAFT_ACTION` | Produce exact message/post/event/tool proposal; never execute | Disabled until approval UI and receipts pass |
| `L3_CONFIRM_EACH` | Execute one exact side effect after fresh human confirmation | Disabled |
| `L4_BOUNDED_AUTOMATION` | Repeated pre-delegated low-risk effects within strict budget/deadline | Not authorized in initial production profile |

The owner may always choose a lower level. A model, tool, room, provider or
remote message cannot raise the level. Capability attenuation can lower level,
scope or budget but never widen them.

The first production candidate, if ever approved, should contain L0 only. L1–L4
require separate human-factors, prompt-injection, durability and physical gates.

---

## 6. Context admission and privacy

### 6.1 Data is not instruction

Every context element carries structural provenance:

```text
context_item = {
  source_class,
  source_principal_or_local_component,
  audience_scope,
  exact_object_or_projection_digest,
  confidentiality_class,
  admitted_fields,
  purpose,
  expires_at,
  instruction_trust = DATA_ONLY | OWNER_REQUEST | STATIC_RUNTIME_POLICY
}
```

Raven messages, social objects, webpages, attachments, OCR, metadata, prior
model output, memories and tool responses are always `DATA_ONLY`. Quoted text
such as “ignore previous instructions” remains data even when signed by a
contact, administrator or room steward. A valid signature authenticates the
speaker; it does not promote their content into runtime policy.

### 6.2 Minimal projections

The inference host supplies the smallest purpose-specific projection:

- smart reply: selected latest message plus explicitly bounded recent turns;
- summary: exact selected interval, named participants minimized where possible;
- moderation assistance: policy-selected fields, not private identity secrets;
- public research: selected public records, never private graph or credentials;
- tool planning: schema and result subset required for the current task only.

Raw identity keys, ATSAM/MLS secrets, protected-store seeds, capability signing
keys, full address books, block/revocation internals and unrelated chats are
forbidden model context.

### 6.3 Cross-context isolation

Context, memory, cache and provider session keys are partitioned by at least:

```text
(owner, agent, purpose, audience, conversation_or_repository, confidentiality)
```

No embedding index, prompt cache, transcript or retrieval result silently
crosses partitions. Dedup may reuse encrypted immutable bytes but never reuse
authorization or expose the fact of a private match.

### 6.4 Remote-provider disclosure manifest

Before any remote inference, the UI must show and persist a machine-readable
manifest naming:

- provider and endpoint authority;
- exact selected fields and estimated byte/token bounds;
- purpose, retention/training policy claim and region where known;
- model/profile/version or provider alias and update behavior;
- whether tools or subprocessors may receive data;
- encryption boundary and the fact that Raven recipient E2EE ends locally;
- failure/fallback policy; and
- one-shot versus remembered user authorization.

Missing provider, network or policy never silently falls back from local to
remote inference.

---

## 7. Capability model

### 7.1 Capabilities live outside prompts

An agent capability is a cryptographically verified, canonical host object—not
natural language. A later byte profile must bind at least:

```text
grant_id
issuer_owner_or_governance_principal
agent_audience
resource_selector
action_class
argument_constraints
recipient_or_audience_constraints
confidentiality_ceiling
automation_level_ceiling
not_before / expires_at
per_invocation, byte, object, recipient, time and cost budgets
approval_mode
delegation_depth
model/tool manifest allow-list
previous_grant_or_revocation_head
nonce / replay namespace
signature(s)
```

Empty, wildcard, root or “all resources/actions” grants are forbidden in the
initial profile. Absence of a field never means unlimited. Unknown action,
condition, model, tool, audience or schema is fail-closed.

### 7.2 Attenuation

A delegated child grant MUST be a mathematical subset of every parent:

- no broader resources, actions, audiences, tools or models;
- no later expiry, earlier start, larger budget or higher automation level;
- no reduced approval requirement;
- no larger delegation depth; and
- no new private-data class.

Raven may later interoperate with UCAN-style delegations, but this draft freezes
no UCAN version, DID method, policy language, library or wire. Adapter evidence
cannot bypass Raven's exact subset verifier.

### 7.3 Capability classes

Read capabilities and write capabilities are separate. Representative classes:

```text
context/read-selected
archive/search-selected
draft/message
draft/publication
message/send-agent-attributed
publication/create-agent-attributed
notification/suggest
room/moderation-propose
room/moderation-execute
contact/propose
tool/query
tool/side-effect
```

`block`, `revoke`, `identity/recover`, `device/add`, `key/export`, `payment`,
`consent/grant`, `private-media/export`, `room/history-export` and destructive
delete are forbidden agent actions in the initial profile.

### 7.4 Revocation and kill switch

The owner can immediately disable local execution, delete provider tokens and
mark every queued invocation ineligible. Network-visible agent/device grants
follow signed revocation/continuity rules and honest partition semantics. A
local kill switch does not claim remote erasure, but no local executor may use
the killed capability again.

---

## 8. Model and runtime manifest

Every inference result binds a local manifest digest covering:

- provider/runtime identity and code/package digest where obtainable;
- model identifier, revision/digest and quantization/profile;
- instruction-template and schema digests;
- generation options, locale, safety/config profile and context limit;
- tool-interface manifest digest;
- execution locality and network mode;
- deterministic seed when genuinely supported, otherwise explicit absence;
- relevant OS/framework versions; and
- policy deciding how unannounced model updates are handled.

An OS or provider model may change without a stable weight digest. Raven records
the strongest observable version evidence and calls it `PROVIDER_VERSION_OPAQUE`;
it does not fabricate reproducibility. A changed model/profile requires fresh
evaluation before it can serve a capability allow-list.

Model output is never deserialized directly into authoritative state. Guided or
structured generation produces an untrusted candidate that passes independent
canonical parse, bounds, policy and authorization checks.

---

## 9. Tool runtime and sandbox

### 9.1 Default deny

No tool is ambient. Each tool exposes a versioned typed interface and declares:

- exact input/output schemas and semantic action class;
- read/write/side-effect classification;
- required capability/resource/audience;
- network domains, local stores and OS facilities it may access;
- maximum bytes, calls, concurrency, duration and monetary cost;
- idempotency key and receipt format;
- secrets it may reference through opaque handles; and
- cancellation/rollback/compensation limits.

The model sees opaque resource handles and minimized projections, never bearer
tokens or raw secrets. Token passthrough is forbidden. Remote tokens bind the
intended tool/resource audience and remain in a protected broker.

### 9.2 Tool runner

The runner—not the model—performs:

1. strict canonical parse and cap reservation;
2. agent/capability/revocation/audience verification;
3. deterministic policy and approval classification;
4. exact intent materialization;
5. transactional execution or typed refusal;
6. exact readback/receipt verification; and
7. budget commit and replay protection.

Tool descriptions, annotations, server-provided schemas and return text are
untrusted until pinned/verified. A tool cannot introduce another tool or ask the
model to expand its own capability.

### 9.3 Sandboxed components

A future plugin profile may use WebAssembly Components/WASI with an explicit WIT
world because a component can access only provided imports. This is a candidate
containment mechanism, not an approved dependency or complete security proof.
The initial world would expose no filesystem, environment, clock, randomness,
network, process, credential or Raven store unless an exact typed import is
deliberately supplied for one invocation.

Native in-process plugins and arbitrary scripts are forbidden in the initial
profile. A sandbox escape, runtime JIT bug or host adapter bug remains in the
threat model.

### 9.4 External protocol adapters

MCP or OAuth tools require separate transport authorization, protected-resource
discovery, audience-bound tokens, PKCE where applicable, secure token storage,
and explicit user consent. MCP compatibility is not authority to install a
server or call all of its tools. STDIO tools are not accepted merely because
they avoid HTTP; their process/environment authority is generally broader.

---

## 10. Side-effect protocol

### 10.1 Prepare

The runtime converts a proposal into canonical `action_intent_bytes` containing:

- agent, grant chain and current authority digest;
- exact action/tool/version;
- exact target/resource/audience and payload digest;
- privacy/confidentiality transition;
- bounded cost and expiry;
- model/context/tool manifest evidence;
- idempotency/replay nonce; and
- expected result/readback class.

The model cannot edit these bytes after preparation.

### 10.2 Approval

For `L3_CONFIRM_EACH`, a trusted non-model UI shows human-readable fields
derived independently from the exact intent. Approval cryptographically binds:

```text
H(action_intent_bytes) || approver_device || expires_at || one_shot_nonce
```

The confirmation surface must display recipient/audience, data leaving the
device, irreversible or remote effects, cost and agent attribution. Model text
cannot obscure, pre-click, synthesize or replace the control. Any payload,
target, grant, cost or privacy change invalidates approval.

### 10.3 Execute and receipt

The executor uses two-phase durable ordering:

```text
reserve budget + write PENDING_AGENT_ACTION(exact intent/approval)
-> perform one idempotent typed effect
-> verify exact provider/local readback
-> commit immutable receipt + budget + resulting object reference
-> clear pending journal
-> release user-visible outcome to Attention
```

Crash recovery rolls forward from exact evidence. It never asks the model to
recreate an action, reuse a nonce, widen authority or interpret an ambiguous
provider result. If idempotency/readback cannot distinguish committed from
uncommitted, the action becomes `OUTCOME_UNKNOWN`, blocks conflicting retries
and requires user repair.

### 10.4 Effects that always require confirmation

The initial profile always confirms any external write, message/publication,
membership/contact change, moderation action, data export, remote-provider
disclosure, purchase, subscription, credential grant or destructive operation.
Some classes remain completely forbidden even with confirmation (§7.3).

---

## 11. Prompt-injection containment

Prompt injection is treated as an authorization-boundary attack, not merely a
bad-text classification problem.

Mandatory defenses:

1. Untrusted content is structurally labeled `DATA_ONLY` and never interpolated
   into static runtime instructions.
2. The model receives no raw secrets or bearer capabilities.
3. Tool selection is intersected with a deterministic host allow-list after
   generation.
4. Every tool argument is rebuilt/canonicalized outside the model and checked
   against the owner request and capability.
5. Tool output returns as untrusted data and cannot authorize the next call.
6. Read and write phases are separated; reading an object never enables a write
   to the object or its author.
7. High-impact operations require exact trusted-UI confirmation.
8. A canary-secret corpus detects attempted exfiltration in evaluation, but
   canaries are not claimed as a complete defense.
9. Adaptive multi-turn attacks, concealed attacks, multilingual/encoded text,
   images/OCR, attachments and cross-tool poisoning are mandatory tests.
10. Failure or uncertainty reduces authority/automation; it never falls back to
    an unrestricted model, tool or provider.

The model may assist with classifying task relevance, but learned classification
alone cannot authorize a side effect.

---

## 12. Memory, archive and deletion

Agent memory is a separate encrypted store partitioned by owner/agent/purpose/
audience. Memory entries bind source evidence, admitted fields, created/expiry,
retention purpose, sensitivity and deletion state. A model suggestion cannot
mark itself durable memory without host policy or user action.

The owner can inspect, export and delete agent memory independently of chat
history. Deletion is local/best-effort for remote providers and makes no physical
overwrite claim on copy-on-write media. Protected root destruction provides
cryptographic retirement of the local memory generation.

[`RAVEN_USER_OWNED_ARCHIVE_V1.md`](RAVEN_USER_OWNED_ARCHIVE_V1.md) may preserve
encrypted historical agent descriptors, grants, manifests, intents and receipts.
Archive restore does not reactivate a capability, provider token, automation,
scheduled task, bot membership or model session. Restored memory remains inert
until current trust/revocation/policy and explicit owner import pass.

Raw prompts, private context and chain-of-thought are not required archive
records. Raven records exact admitted context digests/projections, configurations,
outputs, actions and receipts needed for accountability without claiming access
to hidden model reasoning.

---

## 13. Attention, social and community composition

### 13.1 Attention

An agent cannot rank, notify, auto-open media, bypass quiet hours or create an
interrupt. It emits a bounded candidate to the local Attention Firewall. The
owner's selected recipe decides whether, where and why it appears. Agent urgency
is untrusted metadata.

Recommendations show a “why suggested” explanation based on local rules and
declared context classes. The agent cannot upload private dwell/read/reply
behavior to improve a global feed without a separate remote-data authorization.

### 13.2 Private messages

Reading a DM does not make the sender an agent operator. A message cannot grant
tools or issue a trusted approval. Smart-reply drafts remain local until the
user sends exact final bytes. Autonomous replies require a distinct visible
agent identity and are not enabled by the initial profile.

### 13.3 Communities and bots

A community bot is an explicit participant with its own identity/device/MLS
leaf, visible label, operator/provenance, narrow governance capability, retention
and tool disclosure, rate budget and exact add/remove evidence. It can read only
the messages available to that leaf and cannot pretend to be a steward/member.

A moderator model may propose labels/actions, but execution requires the same
governance threshold/capability as a non-model actor. “AI moderator” is not an
authority class.

### 13.4 Bridges and external networks

An interoperability gateway containing an agent is a declared plaintext
endpoint/operator. It cannot launder foreign authorship into Raven user
authorship, silently widen audience, or preserve E2EE across a plaintext model.
Agent-specific lineage marks translations, summaries and generated replies.

---

## 14. Media and provenance

AI-generated or AI-edited public media follows
[`RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md`](RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md):
Raven publication authorship, model/tool workflow claims and named-actor identity
remain separate. A detector score never creates provenance.

Private smart replies, translation and summaries do not automatically publish
AI-assistance metadata to peers. If the result becomes public/high-impact media,
the selected publication policy may require a scoped AI-disclosure claim. This
is an honest disclosure rule, not a universal “AI content is false” label.

Voice/face synthesis, participation/use consent and media training remain
separate explicit grants. Agent authority cannot infer them from likeness,
contact status or a broad content license.

---

## 15. Current iOS assistance surface and migration hold

The current iOS source contains `FoundationAIService` for on-device smart reply,
summary and translation. It passes selected chat transcript text to Apple's
system model and stores `ai.foundation.optin` in `UserDefaults`, defaulting to
enabled when no value exists. It currently exposes no Raven agent credential or
tool authority, which is an important containment boundary.

Before Raven can describe even this surface as conforming to AR V1, a separate
review must prove:

1. fresh installs use explicit per-feature consent rather than implicit default
   enablement for transcript processing;
2. the UI shows the exact context interval/fields and whether translation or a
   provider/model asset is required;
3. transcript construction is purpose-minimized, bounded and cross-chat isolated;
4. content is treated as untrusted data and never grants tools/side effects;
5. no summary/smart-reply output sends, ranks, notifies or persists as memory
   without a separate user action/policy;
6. debug/error telemetry contains no transcript or generated private text;
7. model/framework/version changes trigger evaluation and honest version evidence;
8. opt-out clears local feature state/caches that Raven controls without making
   false OS-level deletion claims; and
9. physical tests cover unsupported languages, safety/model availability,
   lock/relaunch, context caps and no-network behavior.

This document does not authorize changing that live code. Until migration passes,
it is classified as legacy local assistance, not a Raven agent runtime.

---

## 16. Resource, privacy and abuse bounds

Caps are reserved before parsing, inference, retrieval, tool execution or
durable storage. A later exact profile freezes at least:

- maximum context items/bytes/tokens and per-item decoded expansion;
- maximum model output, tool schema/result and plan depth;
- maximum tool calls, recursive steps, concurrency and wall/CPU time;
- per-agent/per-owner/per-contact/per-room daily action and notification budgets;
- remote provider bytes/tokens/cost and retry count;
- memory bytes/records/TTL and archive export size;
- pending actions, receipts, replay entries and conflict evidence; and
- separate stranger/public/bot budgets that cannot evict protected user state.

Capacity exhaustion fails closed and preserves existing grants, revocations,
pending intents and receipts. The runtime never evicts a live capability or
pending side-effect journal to make room for new model output.

Logs are redacted by construction: no raw prompt, private message, model output,
tool token, contact address, secret, capability bearer or filesystem path in
Release diagnostics. User-selected encrypted audit export is a separate action.

---

## 17. Failure and recovery matrix

| Failure | Required outcome |
|---|---|
| Model unavailable | Typed defer; no silent local→remote fallback |
| Model/provider changes | Hold until manifest/evaluation policy accepts it |
| Malformed/generated arguments | Reject before tool/capability mutation |
| Direct/indirect injection detected or suspected | Refuse or reduce to non-effect draft; retain bounded evidence |
| Missing/expired/revoked grant | Refuse; never ask model to negotiate broader grant |
| Approval missing/mismatched/expired | Refuse exact action |
| Provider token audience mismatch | Refuse; no token passthrough |
| Tool timeout/cancel before commit | Retry only if exact idempotency evidence permits |
| Crash after pending, before effect | Recover exact intent; do not regenerate with model |
| Crash after effect, before receipt | Read back/idempotency query; ambiguous → `OUTCOME_UNKNOWN` |
| Receipt conflict | Terminal conflict; preserve both authenticated claims |
| Budget exhausted | Refuse without evicting protected state |
| Agent kill/revoke | Stop new work; quarantine pending effects for repair |
| Archive restore | Inert evidence only; no capability/session reactivation |
| Remote provider unreachable | Defer/fail; no privacy downgrade |
| Sandbox/runtime integrity failure | Disable affected tool/runtime; no native fallback |

---

## 18. Required vectors and evaluations

### 18.1 Semantic fixtures

Three-language compute fixtures must cover:

- capability subset/attenuation, expiry, audience, revoke and delegation depth;
- context partition and `DATA_ONLY` handling;
- deterministic action-intent/approval/receipt digests;
- exact user-draft versus agent-attributed output classification;
- model/tool manifest pin and opaque-version outcomes;
- side-effect prepare/commit/recovery/idempotency/conflict;
- memory/archive inert restore; and
- Attention candidate separation.

### 18.2 Adversarial corpus

The corpus includes direct and indirect injection in:

- DMs, profiles, public posts, community messages and bot output;
- HTML/Markdown, URLs, calendar/contact fields and filenames;
- PDF/document text, images/OCR, audio transcripts and media metadata;
- tool schemas/descriptions/results and remote error messages;
- encoded, multilingual, split-across-turn and hidden/unicode content;
- prior model output, memory and archive-restored records; and
- attacks that both execute an effect and conceal compromise from the user.

Tests use planted secrets and unauthorized actions to prove the deterministic
runner—not model self-report—blocks exfiltration/effects. Passing a static corpus
is not a proof; adaptive red-team and model-update reruns remain required.

### 18.3 Simulation

At least a 1,000-node model covers owner devices, local agents, community bots,
malicious contacts, public records, partitions, revocations, provider/tool loss,
prompt-injection campaigns, budget floods, agent kill, crash points and archive
restore. It reports false approvals, unauthorized effects, leaked context,
duplicate commits, ambiguous outcomes, attention amplification and resource use.

### 18.4 Physical matrix

Physical rows include:

- iPhone local L0 assistance offline, lock/relaunch and model-unavailable cases;
- macOS/Linux/Windows owner-host sandbox and protected-token behavior;
- Terminal↔iPhone user-confirmed draft flow with no agent impersonation;
- community bot add/remove/revoke with visible MLS membership;
- remote provider explicit disclosure and packet-level no-silent-fallback proof;
- crash during every side-effect boundary; and
- accessibility, localization and coercive-confirmation usability review.

---

## 19. Production holds

Production remains disabled until all of the following pass:

1. this architecture receives independent security/privacy/human-factors review;
2. exact agent descriptor, grant, revoke, intent, approval, receipt, manifest,
   memory and archive profiles are frozen with negative parsers;
3. protected agent identity/capability heads and transactional journals pass
   native crash/rollback matrices on Apple, GNU/Linux and Windows;
4. selected model/runtime/tool packages and update policies are reproducibly
   pinned or honestly classified as opaque;
5. context minimization, prompt-injection and secret-exfiltration evaluations
   pass for every supported model/version/language/tool combination;
6. no raw keys/tokens/context leak through model, logs, crashes or provider;
7. trusted approval UI passes accessibility, substitution and fatigue tests;
8. Attention, archive, media, community and interoperability boundaries pass;
9. simulation and physical matrices pass without waived unauthorized effects;
10. the existing iOS assistance surface completes §15 migration or remains
    explicitly outside the approved runtime; and
11. an independent reviewer records no open P0/P1 and the protocol owner gives
    a separate production authorization.

No test count, on-device label, privacy policy, model safety filter, sandbox,
capability library or user opt-in alone satisfies these holds.

---

## 20. Primary research and standards boundary

This architecture is informed by, but does not freeze:

- NIST AI 600-1, *Generative Artificial Intelligence Profile*, especially
  prompt injection, data privacy, value-chain and evaluation risks:
  <https://doi.org/10.6028/NIST.AI.600-1>
- NIST AI 100-2 E2025 prompt-injection/adversarial-ML taxonomy:
  <https://csrc.nist.gov/pubs/ai/100/2/e2025/final>
- NIST's 2026 AI-agent identity/authorization concept work, which highlights
  identification, authorization, audit, non-repudiation and prompt injection:
  <https://csrc.nist.gov/pubs/other/2026/02/05/accelerating-the-adoption-of-software-and-ai-agent/ipd>
- Apple's Foundation Models documentation for sessions, transcripts, structured
  generation and tools, plus its warning that prompt hierarchy is not a
  complete prompt-injection defense:
  <https://developer.apple.com/documentation/foundationmodels/>
  <https://developer.apple.com/videos/play/wwdc2025/286/>
- Apple's agentic-feature security guidance on indirect injection, side effects,
  confirmations and authentication:
  <https://developer.apple.com/videos/play/wwdc2026/347/>
- Model Context Protocol security/authorization guidance. Tool metadata is
  untrusted, explicit consent is required, token passthrough is forbidden and
  tokens must be audience-bound:
  <https://modelcontextprotocol.io/specification/2025-03-26/index>
  <https://modelcontextprotocol.io/specification/draft/basic/authorization>
- UCAN's attenuated user-originated delegation model, considered only as an
  optional future adapter:
  <https://ucan.xyz/specification/>
- WebAssembly Component Model/WIT capability boundaries, considered only as a
  future sandbox candidate:
  <https://component-model.bytecodealliance.org/design/worlds.html>

Upstream drafts and framework behavior can change. A later implementation pins
exact versions, threat assumptions, adapters and conformance evidence. This
document never treats an upstream name as proof of Raven compliance.

---

## 21. Revision history

- **Revision 1 (2026-08-21):** Initial architecture. Separated context,
  inference, capability, approval, execution and Attention; defined explicit
  agent principals/non-impersonation, assistance versus delegated output,
  automation levels, structural `DATA_ONLY` context, bounded capabilities,
  model/tool manifests, typed sandboxed tools, exact side-effect confirmation
  and crash receipts, memory/archive isolation, community/media composition,
  current iOS assistance migration holds, adversarial evaluation and production
  gates.
