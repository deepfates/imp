# Imp workspace agent

This is a consumer application using Imp.ACP from the enclosing Imp package. It mounts
an ordinary Imp ReActV2 or RLM program in an ACP host and gives it bounded
workspace tools to list, read, search, create files, replace exact text, and run
an executable with an argument vector. The selected workspace is the grant for
bounded reads. Every write and command still requires an explicit ACP approval.

The local Toad journey is:

1. obtain authorized GitHub access to the private Imp repository;
2. install [Toad](https://github.com/batrachianai/toad) and run LM Studio's
   OpenAI-compatible server with `qwen/qwen3.6-35b-a3b` loaded;
3. launch the workspace you want the agent to inspect; the launcher runs
   preflight before entering Toad;
4. ask a grounded codebase question or request a small change; inspect tool
   cards, approve mutations, and cancel with Escape twice when desired.

Preflight accepts `toad` on `PATH` or the common `~/.local/bin/toad` install and
prints the exact absolute launch command for this checkout. The launcher records
the host-selected working directory before changing into this application. ACP
session creation fails closed unless the client's `cwd` matches that mounted
root exactly.

```sh
cd examples/workspace_agent

# Persistent RLM (default for the exercised local endpoint)
scripts/workspace-agent /absolute/path/to/a/workspace

# Restart-durable ReActV2
WORKSPACE_AGENT_PROGRAM=react \
  scripts/workspace-agent /absolute/path/to/a/workspace
```

Local reasoning generations use a five-minute transport inactivity timeout so
an active LM Studio request is not mistaken for a dead connection, and they are
never retried automatically. Persistent RLM calls have a separate ten-minute
whole-call budget. Override these with `WORKSPACE_AGENT_RECEIVE_TIMEOUT_MS` and
`WORKSPACE_AGENT_RLM_MAX_TIME_MS`; neither changes ACP cancellation.

ReAct stores completed conversation history under
`$XDG_STATE_HOME/imp_acp/workspace_agent/sessions` (or
`~/.local/state/imp_acp/workspace_agent/sessions`). Set
`WORKSPACE_AGENT_SESSION_STORE` to override the directory. ACP hosts that
support session loading can reopen the same conversation after the agent
process exits. RLM keeps a richer interpreter namespace, but that namespace is
not serializable today, so RLM intentionally does not advertise restart
continuity.

ACP hosts may also attach stdio, HTTP, or SSE MCP servers to the session. The
workspace agent denies all host-supplied server descriptors by default. Set
`WORKSPACE_AGENT_MCP_AUTHORITY=host` only when the ACP host is the trusted local
authority that selected those exact servers. In that mode the agent imports the
servers through ExMCP, adds their tools to the ordinary Imp program, and still
asks the ACP client before every external tool effect. Server credentials should
remain host-side env/file references and are resolved by the host at session
launch rather than stored as literal values.

Run `scripts/preflight /absolute/path/to/a/workspace` by itself when you want to
check prerequisites and print the underlying absolute Toad command without
launching it.

Ask a question whose answer requires evidence from the mounted project—for
example, compare responsibilities of two runtime components—and request relative
file citations. Avoid copying a canned expected answer into this example: the
point is to make the model inspect the selected workspace.

For a provider-free mechanics check, set `WORKSPACE_AGENT_PROVIDER=static`.
That mode deterministically lists the workspace, reads `README.md`, and reports
its first line; it does not demonstrate model quality.

The checked-in example uses the enclosing Imp checkout, so the launcher and
adapter cannot silently drift to different private revisions. Set
`IMP_PATH=/path/to/imp` only when running a copied example against a
different authorized checkout.

On 2026-08-22, both the ReActV2 and persistent-RLM modes answered a grounded
runtime-ownership question through Toad 0.6.20 and the configured local model.
The Toad wire logs showed permission before each effect, stable tool IDs through
completion, a source-cited answer, and `stopReason: end_turn`. Earlier attempts
also found and drove fixes for unbounded file context, a ReAct iteration-budget
failure, invalid scripted RLM code, and insufficient RLM tool-call guidance.

Commit `4490325` was then cloned fresh from the private remote with both local
path overrides unset. The clone fetched the pinned private Imp ACP, Imp, and
ExMCP revisions, passed all six consumer tests, and passed preflight. Its static
ReAct turn crossed two Toad permission decisions and returned the observed root
README heading. A separate local-model turn made seven approved bounded reads and
searches, answered where ACP transport, Imp execution, and workspace authority
live with exact `README.md` citations, and ended with `stopReason: end_turn`.
This is self-reproduction from clean source, not yet a second person's report.

On 2026-08-23, the mounted-read path was exercised through Toad with the
provider-free ReAct program. Its wire log contained two stable tool calls moving
directly from `in_progress` to `completed`, no `session/request_permission`, the
grounded answer `Observed README first line: # Imp ACP`, and
`stopReason: end_turn`. A mismatched ACP session root is rejected before the
program is constructed. This improves the dedicated read-only consumer; it does
not weaken the adapter's default authorization contract.

The same one-command path was then exercised with the actual local model and
persistent RLM. It made eight bounded reads, listings, and searches without a
client permission request, returned three grounded bullets citing
`lib/imp_acp.ex`, `lib/imp_acp/mcp.ex`, `lib/imp_acp/session.ex`, and the
workspace-agent authority files, and ended with `stopReason: end_turn`.

The equivalent ReActV2 turn exposed a provider-capability mismatch: LM Studio
rejected named tool choice, then accepted but did not honor `required`, leaving
a correct synthesis in reasoning without a `submit` call. Imp now preserves
native submit when supported and otherwise performs one tools-disabled typed
extraction over the original inputs and gathered history. Rerunning the same
Toad 0.6.20, `qwen/qwen3.6-35b-a3b`, workspace, and three-bullet prompt produced
the grounded cited answer and `stopReason: end_turn`; arbitrary model prose was
not accepted as the task output.

These tools are deliberately bounded and reject path or symlink traversal, but
they are not an operating-system sandbox. File creation is exclusive and will
not overwrite an existing path; replacement requires an exact, unambiguous old
fragment unless `replace_all` is explicit; command output and time are bounded,
and cancellation owns the complete process group. The mounted workspace, tool
catalog, provider credentials, and approved executables remain deployment
authority decisions.

On 2026-08-23, Toad 0.6.20 and the real local Qwen model crossed separate
permissions to create `notes.txt` containing exactly `hello\n` and run
`cat notes.txt`, observed exit 0, and returned `end_turn`. A separate cold Toad
exercise restarted the complete ReAct agent, loaded the same durable session,
replayed the exact prior user and assistant messages, and completed a second
grounded turn. The same real model did not reliably honor ReActV2's declared
JSON object arguments for commands: the retained failure was denied before any
effect and ended in `refusal` without a fabricated success. That is why RLM is
the current local-model default while ReAct remains an explicit durable option.

The historical exercise notes above predate protocol absorption into Imp. The
state directory retains its `imp_acp` name to preserve existing saved sessions;
this is a storage location, not a dependency on the retired application.
