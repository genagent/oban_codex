# Agent worker patterns

Durable model work combines two very different systems: an at-least-once job
queue and an agent that can write files or call external tools. The seam is
small; the operating policy is not.

## Defaults versus guardrails

Worker `args` are convenience defaults. Stored job args override them.
`pinned_args` are guardrails and win last:

```elixir
use ObanCodex.Worker,
  queue: :codex,
  args:
    ObanCodex.Args.defaults(
      model: "gpt-5",
      working_dir: "/srv/checkouts/project"
    ),
  pinned_args:
    ObanCodex.Args.defaults(
      sandbox: :read_only,
      approval_policy: :never,
      ignore_user_config: true
    )
```

Pin `working_dir`, sandbox/approval controls, config-isolation controls, and
dangerous bypass flags whenever a webhook or user-facing endpoint supplies job
args.

Keep `env` and secrets out of args. Oban stores them as plaintext JSON and
telemetry exposes the merged map.

## Read-only analysis

The safest worker defaults are:

```elixir
ObanCodex.Args.defaults(
  sandbox: :read_only,
  approval_policy: :never,
  strict_config: true,
  ignore_user_config: true,
  ignore_rules: true
)
```

Add explicit `config_overrides`, feature flags, and context directories rather
than inheriting a developer's workstation behavior.

## Mutating work

Codex can write with:

```elixir
sandbox: :workspace_write
```

Use `approval_policy: :never` only when the exact sandbox and working directory
are controlled by the worker. The dangerous bypass flag is not a stronger
workspace mode; it removes both sandbox and approvals and belongs only inside a
separate external sandbox.

Codex doesn't provide the worktree option exposed by `oban_claude`. A mutating
fleet should prepare an isolated checkout per job (or per conversational
session) before enqueue and pass that directory as `working_dir`. Clean it up
through a separate, idempotent lifecycle you control.

Never let two mutating jobs share the same checkout concurrently. Use Oban
uniqueness, queue partitioning, or an external lease.

## Retry economics and side effects

Oban executes at least once. A process may write a file or open a pull request,
then die before the job is marked complete. The next attempt can repeat the
effect.

For mutating workers:

- prefer `max_attempts: 1` unless the prompt/effects are idempotent;
- include external idempotency keys in prompts and tool calls;
- check whether the desired result already exists before creating it;
- make `handle_result/2` effects transactional or uniquely constrained;
- use a custom classifier to cancel known deterministic CLI failures.

The default classifier retries ordinary non-zero exits because Codex doesn't
provide a stable typed machine error. Your deployment may know more from its
wrapper version or logs; classify carefully and avoid broad prose matching.

## Timeouts and process lifetime

Set `timeout` in every unattended worker:

```elixir
args: ObanCodex.Args.defaults(timeout: :timer.minutes(15))
```

The default wrapper runner closes its port on timeout, but cannot guarantee that
the entire OS process group and every tool subprocess is killed. For strict
termination:

```elixir
{:forcola, "~> 0.3"}
```

```elixir
config :codex_wrapper, runner: CodexWrapper.Runner.Forcola
```

Set the application's shutdown grace period above the longest allowed run.
Configure `Oban.Plugins.Lifeline` with `rescue_after` above that same bound so a
deploy or node loss eventually rescues abandoned jobs.

## Structured propose/dispose

Separate model judgment from external writes:

1. Run Codex read-only with `output_schema`.
2. Decode with `ObanCodex.structured/1`.
3. Persist or enqueue a small deterministic effector.

```elixir
defmodule MyApp.Triage do
  use ObanCodex.Worker,
    queue: :triage,
    pinned_args:
      ObanCodex.Args.defaults(
        sandbox: :read_only,
        approval_policy: :never,
        output_schema: "/srv/my_app/priv/triage.schema.json"
      )

  @impl ObanCodex.Worker
  def handle_result(result, job) do
    case ObanCodex.structured(result) do
      %{"outcome" => "label", "label" => label} ->
        MyApp.ApplyLabel.new(%{"issue" => job.args["issue"], "label" => label})
        |> Oban.insert()

        :ok

      %{"outcome" => "ignore"} ->
        :ok

      _ ->
        {:error, :invalid_proposal}
    end
  end
end
```

This reduces permission surface and makes retries easier to reason about.

## Session handoff

Capture the thread id from a successful turn:

```elixir
thread_id = ObanCodex.session_id(result)
```

Enqueue the continuation:

```elixir
ObanCodex.Args.new(
  prompt: "continue from the previous analysis",
  session_id: thread_id,
  output_schema: "/srv/my_app/priv/result.schema.json"
)
|> MyApp.CodexWorker.new(meta: %{"resume_depth" => 1})
|> Oban.insert()
```

Bound continuation depth in job metadata so a failed conversation cannot spawn
an unbounded chain. Session persistence is node-local; route a chain to a node
that can read the transcript.

`ephemeral` is mutually exclusive with resume.

## Agent permission gate

The experimental Agent layer has two policy tiers:

```elixir
args: %{
  "sandbox" => "read_only",
  "approval_policy" => "never",
  "output_schema" => "/srv/my_app/priv/agent.schema.json"
},
approved_args: %{
  "sandbox" => "workspace_write",
  "approval_policy" => "never"
}
```

Normal turns can inspect. A structured `request_permission` directive parks the
state machine. Only an explicit `approve_action/2` sends one continuation with
the elevated args. A failed approved turn re-gates.

This is application-level approval; it is distinct from interactive Codex CLI
approval, which is unsuitable for a headless Oban worker.

## Scheduling and events

A worker with a prompt in defaults is a routine:

```elixir
defmodule MyApp.DailyAudit do
  use ObanCodex.Worker,
    queue: :codex,
    args:
      ObanCodex.Args.defaults(
        prompt: "audit the repository and summarize risks",
        working_dir: "/srv/checkouts/project",
        sandbox: :read_only,
        approval_policy: :never
      )
end
```

Pair it with `Oban.Plugins.Cron`, or insert jobs from webhooks/PubSub. Use
`unique:` to debounce repeated source events:

```elixir
use ObanCodex.Worker,
  queue: :events,
  unique: [period: 60, fields: [:worker, :args]]
```

## Telemetry and data retention

Run events carry merged args and result/error payloads. They may include prompts,
repository content, paths, and CLI diagnostics. Attach handlers that extract
only what they need.

Codex reports tokens in the final `turn.completed` event:

```elixir
ObanCodex.usage(result)
```

It doesn't report price. If you calculate cost, keep pricing in application
configuration rather than hard-coding mutable model prices into jobs.

Configure `Oban.Plugins.Pruner` based on your data sensitivity. Pruning removes
old job rows, not Codex session transcripts; manage Codex state separately.

## Testing strategy

- Pure result/classifier tests: `ObanCodex.Testing`.
- Worker merge/hook tests: injected named `query_fun`.
- Queue semantics: real SQLite/Lite Oban.
- CLI contract: fake `CodexWrapper.Runner`.
- Live smoke: `mix test --only live`, asserting mechanics rather than prose.

The default suite makes no model calls.
