# Raven Agent Team (RDAP)

RDAP is an **experimental A2A agent-delegation companion** in this repository. It lets explicitly trusted agents exchange recipient-bound, expiring Ed25519-signed tasks and signed answers over A2A JSON-RPC. It is not yet the same runtime or identity store as `raven-node`.

## Security model

The default server rejects unsigned RPC traffic and unsigned tasks. A trusted peer entry pins an exact Raven-style address to an exact Ed25519 public key; agent cards and replies are verified against that pin. Every JSON-RPC request is separately signed over its HTTP method, exact request target, body digest, sender, recipient, nonce, issue time, and expiry. That verified Raven address becomes the A2A `ServerCallContext` owner, so task history and live `List`, `Get`, `Subscribe`, and `Cancel` operations are isolated per peer. Delegations additionally bind the task sender, recipient, task ID, task/reply kind and payload. Accepted transport and delegation signatures use separate durable replay caches.

- Shell execution and arbitrary project-file writes are off unless explicitly
  enabled with the high-risk `--allow-shell` operator flag.
- `read_file` permits ordinary project text but always denies `.team/keys`,
  replay/mesh private state, Git internals, symlink/reparse paths, obvious env
  files, credentials, tokens, private-key formats, and hard-linked files.
- Bearer authentication is advertised and enforced only when a token is configured.
- Revocation/trust-file failures reject work rather than silently weakening policy.
- Cancellation requires the task owner's fresh Raven request signature and emits
  a terminal A2A `canceled` status; a different trusted peer receives task-not-found.
- Delegation authentication runs before task text reaches durable team memory or
  Git sync; unsigned, invalid, and policy-error requests receive an A2A rejection
  without journaling their payload or moving repository state.
- Direct JSON-RPC ingress is bounded per process: 256 KiB bodies, 16 in-flight
  requests, a 15-second body-read deadline, and a 250 ms capacity wait by
  default. Deployments can tune these with `TEAM_MAX_RPC_BODY_BYTES`,
  `TEAM_MAX_CONCURRENT_RPC`, `TEAM_RPC_BODY_TIMEOUT_SECONDS`, and
  `TEAM_RPC_QUEUE_TIMEOUT_SECONDS`.
- A2A task history uses a race-safe bounded store instead of the SDK's unbounded
  default. Rejected tasks are returned but never retained; completed/failed
  terminal history is evicted oldest-first when required, active work is never
  evicted to admit another task, and idle entries expire. Defaults are 256 tasks,
  8 MiB serialized storage, and one hour. `TEAM_TASK_STORE_MAX_COUNT`,
  `TEAM_TASK_STORE_MAX_BYTES`, and `TEAM_TASK_STORE_TTL_SECONDS` may lower or
  tune them, but compiled ceilings (4096 tasks, 64 MiB, 24 hours) cannot be
  exceeded.
- Invalid relay replies are quarantined instead of returned or destroyed.
- Automatic memory/relay commits stage only an allowlist of shared `.team` data.
  They exclude `.team/keys`, replay databases, mesh state, lock internals, and
  every normal project path. Incoming and outgoing commit ranges are checked
  before fast-forward/push; symlinks, reparse points, gitlinks, special files,
  divergence, and out-of-scope history fail closed. Pushes name the branch's
  configured upstream remote and exact `HEAD:<merge-ref>` explicitly, so
  `pushRemote`, `remote.pushDefault`, and `push.default` cannot redirect or
  broaden an automatic push.
- The agent-facing `write_file` and `git_commit` tools are absent by default,
  and direct dispatch rejects `write_file`. `--allow-shell` explicitly enables
  these already high-risk capabilities; even then `git_commit` commits only
  files staged beforehand and refuses private `.team` state.
- `--allow-shell` grants arbitrary commands with the server OS user's authority.
  A command can bypass `read_file` path policy, so this flag must be treated as
  full local code/data access; the agent prompt explicitly forbids using it as
  a read-policy bypass, but that instruction is not an OS sandbox.
- `--open` is an explicit dangerous override that accepts unsigned reachable traffic.

A trusted, signed task still has the intended default authority to read ordinary,
non-sensitive project files and mutate shared team memory (`.team` board, facts,
journal, locks, and outputs). The filename/path policy is defense in depth, not
content-aware data-loss prevention: keep secrets outside the delegated project
tree. Trusting a peer is not a project-write or shell grant unless the receiving
operator also enables `--allow-shell`.

Keep tokens out of argv and use mode `0600` on POSIX. Inbound server secrets are
`TEAM_AUTH_TOKEN[_FILE]`; outbound peer credentials are separately
`RDAP_BEARER_TOKEN[_FILE]` or a command's `--token-file`. RDAP never falls back
from an outbound credential to the local server secret. A Bearer credential is
sent only over HTTPS; plaintext HTTP is rejected even for loopback because a
different local process can take over a stopped node's port and replay its
public signed card.
Direct Raven peer traffic ignores process-wide HTTP proxy variables so a local
Bearer cannot be redirected through a proxy. Commands that fan out to multiple
peer identities refuse a single configured Bearer; invoke the command once per
teammate with that destination's token file.

## Current carriers

| Carrier | Confidentiality/status |
|---|---|
| Direct A2A HTTP | Signed and peer-pinned; HTTP payload confidentiality requires HTTPS or another protected network layer |
| Git relay | Signed task and signed answer; repository access controls provide transport confidentiality |
| Raven swarm mailbox adapter | **Disabled by default and plaintext**; signed JSON is placed in an RVN1 ciphertext field but is not Raven E2EE |

The mailbox adapter requires the explicit `--experimental-plaintext-mailbox` flag. It must not be described or deployed as confidential Raven messaging.

Automatic Git sync never rebases, autostashes, force-pushes, or merges divergent
history. Concurrent writers can therefore require an operator to reconcile the
branches explicitly before relay sync resumes.

Git relay is available only when `team-repo` has exactly one configured tracking
upstream. A local repository is not a carrier: RDAP now refuses it and never prints
"queued" for a file that cannot reach another clone. To create the shared relay,
use a private empty Git repository:

```bash
# Device A, after ./rdap init
./rdap relay-setup git@github.com:YOUR_ORG/YOUR_PRIVATE_TEAM_RELAY.git

# Device B, before its first ./rdap init
cd agent_team
git clone git@github.com:YOUR_ORG/YOUR_PRIVATE_TEAM_RELAY.git team-repo
./rdap init
```

Both clones must track the same branch. Relay commits remain restricted to the
documented shared `.team` allowlist; project files and private `.team/keys` state
are not staged. A fresh `rdap init` writes a repo-local, non-personal
`RDAP Agent <rdap@localhost.invalid>` Git identity before its checked initial
commit, so relay readiness never depends on global Git identity.

## LLM provider credentials

Hosted credentials are bound to their fixed HTTPS origin: `OPENAI_API_KEY` only
for `https://api.openai.com/v1`, `GROQ_API_KEY` only for Groq, and
`OPENROUTER_API_KEY` only for OpenRouter. Ollama is keyless and loopback-only.
The old generic `LLM_API_KEY` fallback is intentionally ignored.

An operator may use another OpenAI-compatible endpoint only by selecting
`custom`, supplying its URL explicitly, and setting the endpoint-specific
`TEAM_LLM_API_KEY` or mode-`0600` `TEAM_LLM_API_KEY_FILE`. A keyed custom endpoint
must use HTTPS; RDAP refuses to send any credential over HTTP.

```bash
./rdap model groq llama-3.3-70b-versatile
export GROQ_API_KEY='...'

./rdap model custom my-model --base-url https://llm.example.com/v1
export TEAM_LLM_API_KEY_FILE="$HOME/.config/rdap/custom-llm-key"
```

## Important integration gap

RDAP currently creates its own key under `.team/keys` and does not submit or receive application payloads through the production `raven-node` ATSAM session actor. The experimental mailbox invokes the separately gated `raven-swarm-mailbox-experimental` binary, not the normal terminal node. Unifying RDAP with the node identity/protected store and encrypted Raven carrier remains required before this can truthfully be called “A2A over production Raven Node.”

## Run and verify

Python 3.10 or newer is required. The `./rdap` launcher installs the exact
hash-verified dependency graph from `requirements.lock.txt`; CI uses that same
lock on Python 3.10 and 3.12. For the first deterministic two-device LAN smoke,
use the built-in `echo` provider so no API key, model download, Internet relay,
or shared Git repository is involved. Rely on Raven signatures and do not
configure Bearer. Allow inbound TCP `9001` only on the private/trusted LAN in
each device's firewall, then find each device's real IPv4 LAN address (not
`127.0.0.1`). The current listener is IPv4-only; a URL-safe ASCII hostname can
be supplied, but RDAP validates only its syntax and every peer must resolve it
to IPv4. A raw IPv6 address and the IPv4 limited-broadcast address are rejected
explicitly. For this first smoke, use the numeric LAN IPv4 address.

On Linux/macOS use `./rdap`. On native Windows use `rdap.cmd` (or
`powershell -NoProfile -ExecutionPolicy Bypass -File .\rdap.ps1`). Both install
the same hash-locked environment and forward the same arguments.

On Alice, in terminal 1:

```bash
cd agent_team
./rdap init --name alice --role coordinator --no-internet
./rdap invite --ip <alice-lan-ip> --port 9001
./rdap start --ip <alice-lan-ip> --port 9001 --provider echo
```

On Bob, in terminal 1:

```bash
cd agent_team
./rdap init --name bob --role worker --no-internet
./rdap invite --ip <bob-lan-ip> --port 9001
./rdap start --ip <bob-lan-ip> --port 9001 --provider echo
```

Keep both `start` commands running. RDAP refuses to substitute loopback when
the machine has no default route, and startup fails instead of silently moving
to another port if `9001` is occupied.

Exchange the two invite lines through an authenticated channel. In terminal 2
on each device, first enter that device's cloned `agent_team` directory. Alice
then trusts Bob's complete invite, and Bob trusts Alice's. A supplied URL is
saved only after the live signed Agent Card and Raven identity match the invite
pin:

```bash
# Alice, terminal 2
cd /path/to/RAVEN/agent_team
./rdap trust 'RDAP1 bob <bob-rvn1> <bob-ed25519> http://<bob-lan-ip>:9001'
./rdap ping --name bob
./rdap ask 'Reply exactly: RAVEN_A2A_OK_FROM_BOB' --name bob

# Bob, terminal 2
cd /path/to/RAVEN/agent_team
./rdap trust 'RDAP1 alice <alice-rvn1> <alice-ed25519> http://<alice-lan-ip>:9001'
./rdap ping --name alice
./rdap ask 'Reply exactly: RAVEN_A2A_OK_FROM_ALICE' --name alice
```

Run those trust/ping/ask commands in terminal 2 on each device. `trust` performs
a live signed-card check, so the destination node must already be running. The
echo result should say `completed task` and include the requested marker in its
task summary. For Windows `cmd.exe`, begin every new terminal with
`cd /d C:\path\to\RAVEN\agent_team`, replace `./rdap` with `rdap.cmd`, and use
double quotes around each complete invite/task string, for example
`rdap.cmd trust "RDAP1 bob ..."`; single quotes in the Bash examples are not CMD
quoting.

Do not add `--open` or `--allow-shell` for this smoke. Direct HTTP is signed and
peer-pinned but is not encrypted; keep it on a network you trust, or add HTTPS
before using it across an untrusted network.

A four-field invite without a URL remains valid for offline pin setup, but it
does not create a direct endpoint. Bearer-protected peers require a securely
obtained **destination server's** token during `trust` and `ask`; use HTTPS
for every authenticated endpoint. `discover` is public TOFU only and will never
send a Bearer token to an untrusted mDNS endpoint.

Run the authentication and real localhost A2A flow:

```bash
./rdap status  # bootstraps the local virtualenv/dependencies if needed
.venv/bin/python -m team_agents.selftest
```

On native Windows, use the equivalent launcher and virtualenv path:

```powershell
rdap.cmd status
.venv\Scripts\python.exe -m team_agents.selftest
```

CI runs the same functional suite on Linux, macOS, and Windows via
`.github/workflows/raven-agent-team.yml`.

Windows security hold: persistent identity and token files do not yet have a
tested current-user-only DACL creator/validator equivalent to the POSIX `0600`
checks. Windows remains a functional test target, but use a dedicated OS account
and a directory whose ACL inheritance is already restricted; do not place
production credentials there until native DACL enforcement lands.
