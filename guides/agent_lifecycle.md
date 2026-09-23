# Agent lifecycle

The experimental Agent layer keeps conversational state in a `:gen_statem`
while every model turn remains an ordinary, durable Oban job.

It is intentionally aligned with `oban_claude`. The provider-specific
difference is the resume handle: Codex's `thread_id` is placed in the next job
as `"session_id"`.

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
but it does not restore an Agent's session id, history, pending gate, or current
turn after that process stops. A replacement with the same id has a new
generation and rejects late callbacks from the earlier process.

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
    max_history: 500
  )
```

Configuration:

- `args` — defaults under every turn.
- `approved_args` — temporary overrides for an approved continuation only.
- `worker` — turn worker, default `ObanCodex.Agent.Job`.
- `oban` — named Oban instance, default `Oban`.
- `job_timeout` — watchdog for one attempt plus expected retry backoff.
- `max_history` — bounded in-process event history.
- `enqueue_fun` — offline test seam.

## States

| State | Meaning |
|---|---|
| `idle` | ready for a prompt |
| `running` | an Oban turn is in flight |
| `waiting_for_user` | structured directive asked a question |
| `awaiting_permission` | structured directive requested an action |
| `paused` | emergency lockdown |
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

The next turn receives that value under `"session_id"`. Use
`session: :fresh` for a prompt that should start a new conversation:

```elixir
ObanCodex.Agent.submit_prompt("triage-7", "start over", session: :fresh)
```

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

## Emergency pause

```elixir
:ok = ObanCodex.Agent.emergency_pause("triage-7")
{:ok, :paused} = ObanCodex.Agent.status("triage-7")
:resumed = ObanCodex.Agent.resume_agent("triage-7")
```

Pause drops pending question/action scopes. A late result is recorded but cannot
unlock the agent or trigger a directive while paused.

## Inspection

```elixir
{:ok, info} = ObanCodex.Agent.info("triage-7")
{:ok, history} = ObanCodex.Agent.history("triage-7")
```

`info` includes state, session id, turns, pending scopes, and `cost_usd`.
Codex doesn't report price, so cost stays `0.0` unless a custom error payload
provides one.

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
