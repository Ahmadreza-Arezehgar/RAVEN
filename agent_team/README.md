# Raven Agent Team (RDAP)

RDAP is an **experimental A2A agent-delegation companion** in this repository. It lets explicitly trusted agents exchange recipient-bound, expiring Ed25519-signed tasks and signed answers over A2A JSON-RPC. It is not yet the same runtime or identity store as `raven-node`.

## Security model

The default server rejects unsigned tasks. A trusted peer entry pins an exact Raven-style address to an exact Ed25519 public key; agent cards and replies are verified against that pin. Delegations bind the sender, recipient, task ID, task/reply kind, payload digest, nonce, issue time, and expiry. Accepted signatures are recorded in a durable SQLite replay cache.

- Shell execution and arbitrary project-file writes are off unless explicitly
  enabled with the high-risk `--allow-shell` operator flag.
- `read_file` permits ordinary project text but always denies `.team/keys`,
  replay/mesh private state, Git internals, symlink/reparse paths, obvious env
  files, credentials, tokens, private-key formats, and hard-linked files.
- Bearer authentication is advertised and enforced only when a token is configured.
- Revocation/trust-file failures reject work rather than silently weakening policy.
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

Keep tokens out of argv. Prefer `--token-file`, `TEAM_AUTH_TOKEN_FILE`, or `RDAP_BEARER_TOKEN_FILE` with a user-private file.

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

## Important integration gap

RDAP currently creates its own key under `.team/keys` and does not submit or receive application payloads through the production `raven-node` ATSAM session actor. The experimental mailbox invokes the separately gated `raven-swarm-mailbox-experimental` binary, not the normal terminal node. Unifying RDAP with the node identity/protected store and encrypted Raven carrier remains required before this can truthfully be called “A2A over production Raven Node.”

## Run and verify

Python 3.10 or newer is required.

```bash
cd agent_team
./rdap init
./rdap invite
./rdap trust 'RDAP1 <name> <rvn1-address> <ed25519-public-key>'
./rdap start --token-file /path/to/private-token-file
```

From a trusted peer:

```bash
./rdap ask 'perform this task' --name <name> --token-file /path/to/private-token-file
```

Run the authentication and real localhost A2A flow:

```bash
./rdap status  # bootstraps the local virtualenv/dependencies if needed
.venv/bin/python -m team_agents.selftest
```

CI runs the same suite on Linux, macOS, and Windows via `.github/workflows/raven-agent-team.yml`.
