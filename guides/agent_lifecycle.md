# Agent lifecycle

The experimental Agent layer keeps conversational state in a `:gen_statem`
while every model turn remains an ordinary, durable Oban job.

It is intentionally aligned with `oban_claude`. Provider sessions live in
bounded, host-named conversation arcs; the provider-specific resume handle is
Codex's `thread_id`, placed in the next job as `"session_id"`.

## Supervision

Add the Agent supervisor after Oban:

```elixir
children = [
  MyApp.Repo,
  {Oban, Application.fetch_env!(:my_app, Oban)},
  {ObanCodex.Agent.Supervisor, []}
]
```

The supervisor owns a Registry and DynamicSupervisor. Agents exist only while
their processes are alive. Oban durably retains queued jobs and retry attempts,
but it does not restore an Agent's arcs, history, pending gate, deferred-pause
latch, or current turn after that process stops. Seed persisted arc handles
when starting the replacement. It has a new generation and rejects late
callbacks from the earlier process.

## Start an agent

```elixir
{:ok, _pid} =
  ObanCodex.Agent.start_agent("triage-7",
    args:
      ObanCodex.Args.defaults(
        working_dir: "/srv/checkouts/project",
        sandbox: :read_only,
        approval_policy: :never,
        output_schema: "/srv/my_app/priv/agent.schema.json"
      ),
    approved_args: %{
      "sandbox" => "workspace_write",
      "approval_policy" => "never"
    },
    job_timeout: :timer.minutes(12),
    max_history: 500,
    session_arcs: %{"operator" => persisted_thread_id},
    max_session_arcs: 32,
    config_revision: "routine-config-42"
  )
```

Configuration:

- `args` — defaults under every turn.
- `approved_args` — temporary overrides for an approved continuation only.
- `worker` — turn worker, default `ObanCodex.Agent.Job`.
- `oban` — named Oban instance, default `Oban`.
- `job_timeout` — watchdog for one attempt plus expected retry backoff.
- `max_history` — bounded in-process event history.
- `session_arcs` — optional `%{arc_id => thread_id}` restore seed.
- `max_session_arcs` — bounded retained handle count, default 32.
- `config_revision` — optional opaque host revision, exposed in `info/1`, job
  metadata, and lifecycle telemetry. It must be a non-empty string of at most
  256 bytes.
- `enqueue_fun` — offline test seam.

## States

| State | Meaning |
|---|---|
| `idle` | ready for a prompt |
| `running` | an Oban turn is in flight |
| `waiting_for_user` | structured directive asked a question |
| `awaiting_permission` | structured directive requested an action |
| `paused` | emergency lockdown or an applied safe-boundary pause |
| `offline` | no registered process |

```elixir
:processing = ObanCodex.Agent.submit_prompt("triage-7", "triage the new issues")
{:ok, :running} = ObanCodex.Agent.status("triage-7")

{:ok, settled} =
  ObanCodex.Agent.await(
    "triage-7",
    [:idle, :waiting_for_user, :awaiting_permission],
    :timer.minutes(10)
  )
```

`cast_prompt/3` is the non-blocking form. Prompts sent while a turn or approval
is active are postponed by the state machine.

## Directive schema

The lifecycle interprets two conventional structured directives:

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["directive", "summary"],
  "properties": {
    "directive": {
      "type": "string",
      "enum": ["none", "ask_user", "request_permission"]
    },
    "summary": {"type": "string"},
    "question": {"type": "string"},
    "action": {"type": "string"}
  }
}
```

- `ask_user` parks in `waiting_for_user`; the next operator prompt is the answer.
- `request_permission` parks in `awaiting_permission`; approve or reject using
  the action id returned by `status/1`.
- anything else returns to `idle`.

```elixir
{:ok, {:awaiting_permission, %{id: action_id, description: description}}} =
  ObanCodex.Agent.status("triage-7")

:processing =
  ObanCodex.Agent.approve_action("triage-7", action_id,
    args: %{"sandbox" => "workspace_write"}
  )
```

Only the continuation turn receives `approved_args` and the optional
string-keyed `:args` overrides passed to `approve_action/3`. If that turn fails
or hits the watchdog, the action re-gates with a fresh id rather than silently
losing its elevation.

## Session threading

Each completed result supplies:

```elixir
ObanCodex.session_id(result)
```

The next turn in the same arc receives that value under `"session_id"`.
Omitting `arc_id` uses the backward-compatible `"default"` arc:

```elixir
ObanCodex.Agent.submit_prompt("triage-7", "continue the issue",
  arc_id: "issue-651"
)

ObanCodex.Agent.submit_prompt("triage-7", "start a new sweep",
  arc_id: "daily-sweep",
  session: :fresh
)
```

Freshness clears only the selected arc. `session: :fresh_fallback` records
that the host deliberately started fresh after a failed resume. A terminal
resume classified as `:session_not_found`, `:invalid_session`,
`:unknown_session`, or `:session_rejected` appears in `info/1` as the typed
continuation `outcome: :session_rejected`, so the host can reconstruct a
durable handoff and retry without silently selecting another local transcript.

Each job's metadata and `[:oban_codex, :agent, :turn_completed]` telemetry
identify the arc, input session, continuation decision and reason, final
outcome, and optional host `config_revision`. Pass an opaque `correlation_id`
to `submit_prompt/3` or
`cast_prompt/3` to carry an application request identity through postponed
delivery, job metadata, turn transitions, approval continuations, and
completion. Turn events also expose the wrapper-owned `agent_generation` and
`agent_turn_id`. Least-recently used inactive handles are evicted at the
configured bound. Durable persistence and rotation policy belong to the host.

`fork_arc/5` forks the source arc's Codex thread into the target arc through
`codex exec fork` and runs the prompt on the fork. If the target arc already
has a session, that session is replaced and the replaced session id is reported
in completion telemetry. The source arc handle is never rewritten, and a failed
fork leaves the target arc unchanged. Forking an arc into itself returns
`{:error, :same_arc}`. A source arc with no session handle returns
`{:error, {:enqueue_failed, {:fork_source_missing, source_arc_id}}}`. A CLI
without `exec fork` fails the turn with the non-retryable reason
`{:unsupported, :exec_fork}`.

Never put `ephemeral: true` in an Agent's default args; there would be no session
file to resume.

## Retry semantics

`ObanCodex.Agent.Job` distinguishes a retryable attempt from a finished logical
turn. While Oban will retry, the state stays `running`, records a `:retrying`
entry, and re-arms the watchdog. A terminal result/error feeds
`ObanCodex.Agent.job_finished/3`.

Every job carries an opaque instance generation and logical turn id in its
metadata. The instance checks both inside the state machine before changing
state, session, approval, counters, or watchdogs. Late outcomes, duplicate
callbacks, and callbacks from an earlier same-id process are retained only as
bounded diagnostics. Custom workers that delegate their result and error
callbacks to `ObanCodex.Agent.Job` inherit this behavior automatically.

Tune `job_timeout` above one command timeout plus the largest expected backoff.

A `pause_after_turn/3` latch survives retry callbacks for the same logical
turn. A terminal retry result applies it, and a watchdog expiry applies it just
like any other terminal boundary.

## Scheduling

`ObanCodex.Agent.Tick` adapts `Oban.Plugins.Cron` to the lifecycle by delivering
a prompt through the Agent facade. It does not enqueue a turn behind the state
machine:

```elixir
{Oban.Plugins.Cron,
 crontab: [
   {"0 9 * * *", ObanCodex.Agent.Tick,
    args: %{
      "agent_id" => "standup",
      "arc_id" => "daily-sweep",
      "prompt" => "Summarize overnight CI failures.",
      "session" => "fresh",
      "if_offline" => "start",
      "start" => %{"args" => %{"sandbox" => "read_only"}}
    }}
 ]}
```

Tick policies are `if_busy` (`"skip"` by default or `"queue"`), `if_offline`
(`"skip"` by default or `"start"`), and `session` (`"resume"` by default or
`"fresh"`). Run ticks on a dedicated queue such as
`queues: [agents: 2, ticks: 1]`; a tick on the Agent turn queue can wait behind
the work whose busy state it is meant to observe.

## Safe-boundary pause

A host rail may trip while a turn is still producing the permission request or
question that the operator must see. `pause_after_turn/3` installs a correlated
latch without interrupting that result:

```elixir
:ok =
  ObanCodex.Agent.pause_after_turn(
    "triage-7",
    :daily_budget,
    captured_job_meta
  )
```

The call is synchronous. It validates the job metadata's agent, instance
generation, and logical turn inside the state machine, then replies only after
the latch is stored. The matching turn may still be running or may have just
completed into `waiting_for_user` or `awaiting_permission`. A matching
completion cannot overtake the latch. Repeating the request for its source turn
or latest continuation is idempotent; the first reason wins.

Completion, failure, or watchdog expiry normally moves straight to `paused`.
Structured gates remain visible instead:

- `ask_user` stays in `waiting_for_user`; one operator answer may run.
- `request_permission` stays in `awaiting_permission`; one approval may run.
- a continuation that opens a new gate, fails after approval, or times out
  remains gated with the latch attached.
- rejecting a latched permission request moves directly to `paused`.

Prompts queued behind the turn or gate cannot start another turn after the
latch applies. The Agent answers synchronous callers with `{:error, :paused}`
and records dropped cast prompts. `info/1` exposes the reason plus immutable
source identity and the latest owner's generation, turn, arc, and correlation
identities under `:deferred_pause`. `resume_agent/1` clears that latch.

Relevant transition telemetry adds `cause: :pause_after_turn`, `pause_reason`,
and `pause_action` (`:continued`, `:applied`, or `:cleared`). Permission
decisions add `gate_outcome`, `action_id`, and action details needed to audit a
rejection. These fields are additive; the existing state and continuation
identity metadata remains present.

## Host configuration handoff

When a host needs to replace the live Agent process because its effective
configuration changed, `quiesce/2` provides one atomic boundary:

```elixir
case ObanCodex.Agent.quiesce("triage-7", :config_handoff) do
  :paused -> :safe_to_replace
  :armed -> :wait_for_paused
  :already_paused -> :safe_to_replace
end
```

An idle agent pauses immediately. A running turn is allowed to complete. A
question or permission gate remains visible and receives one answer or
approval continuation before pausing; rejection pauses immediately. The first
armed reason wins, and transition telemetry uses `cause: :quiesce`. The host
still owns persistence, replacement, and any replay of durable prompts.

## Emergency pause

```elixir
:ok = ObanCodex.Agent.emergency_pause("triage-7")
{:ok, :paused} = ObanCodex.Agent.status("triage-7")
:resumed = ObanCodex.Agent.resume_agent("triage-7")
```

Emergency pause is immediate. It drops pending question/action scopes and any
safe-boundary latch. A late result is recorded but cannot unlock the agent or
trigger a directive while paused.

## Inspection

```elixir
{:ok, info} = ObanCodex.Agent.info("triage-7")
{:ok, history} = ObanCodex.Agent.history("triage-7")
```

`info` includes state, the default session id, all retained `session_arcs`,
the active arc, the current or most recent continuation, turns, pending scopes,
the optional `deferred_pause` latch, and `cost_usd`. Codex doesn't report price,
so cost stays `0.0` unless a custom error payload provides one.

## Offline tests

Inject enqueue rather than starting Oban:

```elixir
test_pid = self()

enqueue = fn args, meta ->
  send(test_pid, {:enqueued, args, meta})
  {:ok, :queued}
end

{:ok, _} = ObanCodex.Agent.start_agent("test-agent", enqueue_fun: enqueue)
:processing = ObanCodex.Agent.submit_prompt("test-agent", "work")

assert_receive {:enqueued, %{"prompt" => "work"}, %{"agent_id" => "test-agent"} = meta}

:ok =
  ObanCodex.Agent.job_finished(
    "test-agent",
    {:ok, ObanCodex.Testing.result("done", session_id: "thread-1")},
    meta
  )
```
