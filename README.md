# oban_codex

[![Hex.pm](https://img.shields.io/hexpm/v/oban_codex.svg)](https://hex.pm/packages/oban_codex)
[![Documentation](https://img.shields.io/badge/hex-docs-purple.svg)](https://hexdocs.pm/oban_codex)

Run [OpenAI Codex](https://developers.openai.com/codex/) turns as durable
[Oban](https://hexdocs.pm/oban) jobs.

`codex_wrapper` owns the Codex CLI process. Oban owns persistence, concurrency,
retries, scheduling, uniqueness, and recovery. `oban_codex` is the seam between
them, plus the same higher-level conveniences offered by `oban_claude`:
validated args, result helpers, worker callbacks, testing fixtures, CLI tools,
an Igniter installer, and an opt-in long-lived Agent lifecycle.

## Install

```elixir
def deps do
  [
    {:oban, "~> 2.23"},
    {:oban_codex, "~> 0.1"}
  ]
end
```

Requirements:

- Elixir `~> 1.20`
- a configured Oban instance
- `codex_wrapper ~> 0.4`
- the `codex` CLI installed and authenticated for real runs

Check a worker node before enabling its queue:

```console
mix oban_codex doctor
```

## Quick start

```elixir
defmodule MyApp.CodexJob do
  use ObanCodex.Worker, queue: :codex, max_attempts: 3

  @impl ObanCodex.Worker
  def handle_result(result, _job) do
    Logger.info("Codex: #{ObanCodex.text(result)}")
    :ok
  end
end

ObanCodex.Args.new(
  prompt: "summarize this repository",
  working_dir: "/path/to/repo",
  sandbox: :read_only,
  approval_policy: :never
)
|> MyApp.CodexJob.new()
|> Oban.insert()
```

`ObanCodex.Args.new/1` accepts atom keys and native Elixir values, validates
them, and returns the string-keyed JSON map Oban stores. A raw string map is
also accepted as the low-level escape hatch.

## Compatibility with oban_claude

The packages intentionally share the same architecture and naming. Application
code that only depends on the Oban-facing seam should feel familiar.

| Surface | `oban_claude` | `oban_codex` |
|---|---|---|
| stateless engine | `run/2` | `run/2` |
| worker macro | defaults, pinned args, classifier, result/error hooks | same |
| args builder | `new/1`, `defaults/1`, flat `meta` | same |
| result helpers | structured output, session, cost | text, events, structured output, session, usage; cost unavailable |
| testing | result/error/query fixtures and sequences | same concepts, encoded as real Codex JSONL |
| task CLI | `run`, `doctor`, `args` | same |
| installer | SQLite/Lite Igniter scaffold | same |
| Agent lifecycle | Instance, Job, Supervisor, Tick | same state machine and facade |

Provider semantics intentionally differ:

| Concern | Claude | Codex |
|---|---|---|
| permissions | `permission_mode`, tool allow/deny | `sandbox`, `approval_policy`, explicit dangerous bypass flags |
| structured output | inline JSON Schema | path to a JSON Schema file |
| resume | Claude resume flags | Codex thread id through `session_id`; `resume` is an alias |
| isolation | CLI worktree option | provide a dedicated checkout/working directory outside this package |
| config sealing | Claude hermetic scopes | `ignore_user_config`, `ignore_rules`, `strict_config`, explicit overrides |
| spend/turn rails | wrapper reports cost and rail stops | Codex JSONL reports token usage, not price or turn-budget errors |

Those differences are deliberate rather than papered over with misleading
fields.

## Worker configuration

Worker `:args` are defaults under the stored job args. `:pinned_args` are
guardrails over the job:

```elixir
defmodule MyApp.ReadOnlyReview do
  use ObanCodex.Worker,
    queue: :review,
    max_attempts: 2,
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
end
```

Precedence is:

```text
pinned_args > stored job args > args defaults
```

Both worker maps must be string-keyed; the builders are the easiest way to
ensure that. A malformed stored job cancels as
`{:cancel, {:invalid_args, message}}` instead of retrying the same input.

Do not put environment variables or secrets in job args. `:env` is deliberately
absent because Oban stores args in plaintext. Resolve secrets on the worker node
or inject a custom `:query_fun`.

## Result model

The successful payload is the underlying `%CodexWrapper.Result{}`:

```elixir
%CodexWrapper.Result{
  stdout: "... JSONL ...",
  stderr: "",
  exit_code: 0,
  success: true
}
```

`oban_codex` forces `--json` and provides stable readers over those events:

```elixir
ObanCodex.events(result)      # [%CodexWrapper.JsonLineEvent{}, ...]
ObanCodex.text(result)        # final agent message
ObanCodex.structured(result)  # decoded object/array, or nil
ObanCodex.outcome(result)     # conventional structured["outcome"]
ObanCodex.session_id(result)  # thread_id from thread.started
ObanCodex.usage(result)       # token usage from the final turn.completed
ObanCodex.cost_usd(result)    # nil; Codex doesn't report price
```

A non-zero CLI exit is still a `%CodexWrapper.Result{success: false}`. A failure
before a result exists (timeout, spawn, signal, I/O) is normalized as an
`%ObanCodex.Error{}`.

## Structured output

Codex takes a JSON Schema **file path**, not inline schema text:

```elixir
ObanCodex.Args.new(
  prompt: "triage issue 87",
  output_schema: "/srv/my_app/priv/triage.schema.json",
  sandbox: :read_only,
  approval_policy: :never
)
```

The path must exist on the node executing the job. It is reapplied to resumed
turns. A handler can propose/dispose with the decoded object:

```elixir
@impl ObanCodex.Worker
def handle_result(result, _job) do
  case ObanCodex.structured(result) do
    %{"outcome" => "fix", "summary" => summary} ->
      MyApp.Implement.new(%{"prompt" => summary}) |> Oban.insert()
      :ok

    %{"outcome" => "wontfix"} ->
      {:cancel, :wontfix}

    _ ->
      :ok
  end
end
```

## Classification and error hooks

The default classifier is intentionally conservative:

| Outcome | Oban verdict |
|---|---|
| successful result | `:ok` |
| exit 126/127 | `{:cancel, :command_unavailable}` |
| other non-zero exit | `{:error, {:command_failed, exit_code}}` |
| timeout | `{:error, :timeout}` |
| deterministic normalized config/auth/spawn fault | `{:cancel, kind}` |
| other normalized execution fault | `{:error, kind}` |
| off-contract raw error | `{:cancel, term}` |

Codex doesn't currently expose a stable typed envelope for errors printed by the
CLI, so arbitrary non-zero exits are bounded retries. Override `:classifier`
when your deployment can classify an exit more precisely:

```elixir
defmodule MyApp.CodexJob do
  use ObanCodex.Worker,
    queue: :codex,
    classifier: &__MODULE__.classify/1

  def classify({:ok, %CodexWrapper.Result{success: false} = result}) do
    if result.stdout =~ "login required" do
      {{:cancel, :auth}, result}
    else
      ObanCodex.Outcome.classify({:ok, result})
    end
  end

  def classify(outcome), do: ObanCodex.Outcome.classify(outcome)
end
```

A classifier returns `{oban_return, payload}`, not a flat verdict.
`handle_error/3` receives every non-`:ok` verdict with its payload and job, and
may preserve or replace the verdict.

## Sessions

Every persisted run emits a thread id:

```elixir
thread_id = ObanCodex.session_id(result)

ObanCodex.Args.new(
  prompt: "continue with the tests",
  session_id: thread_id
)
```

`resume: thread_id` is accepted as a compatibility alias. Do not set both.
`ephemeral: true` is for one-shot jobs and cannot be combined with either resume
key.

Session files are node-local. Pin a conversational chain to compatible worker
nodes or use shared Codex state storage if your deployment provides it.

## Experimental Agent lifecycle

The opt-in Agent layer is in sync with `oban_claude`:

- `ObanCodex.Agent`
- `ObanCodex.Agent.Instance`
- `ObanCodex.Agent.Job`
- `ObanCodex.Agent.Supervisor`
- `ObanCodex.Agent.Tick`

Add the supervisor:

```elixir
children = [
  {ObanCodex.Agent.Supervisor, []}
]
```

Then start and prompt a long-lived conversational state machine:

```elixir
{:ok, _pid} =
  ObanCodex.Agent.start_agent("triage-7",
    args:
      ObanCodex.Args.defaults(
        working_dir: "/srv/checkouts/project",
        output_schema: "/srv/my_app/priv/agent.schema.json",
        sandbox: :read_only,
        approval_policy: :never
      ),
    approved_args: %{
      "sandbox" => "workspace_write",
      "approval_policy" => "never"
    }
  )

:processing = ObanCodex.Agent.submit_prompt("triage-7", "triage new issues")
{:ok, status} = ObanCodex.Agent.status("triage-7")
```

The state machine threads `session_id` across ordinary Oban jobs and supports
idle, running, waiting-for-user, awaiting-permission, and paused states.
`cost_usd` remains in its info map for cross-package shape compatibility, but it
stays `0.0` unless a custom error payload reports cost.

See [Agent lifecycle](guides/agent_lifecycle.md).

## Testing without Codex

```elixir
import ObanCodex.Testing

assert {:ok, result} =
         ObanCodex.run(%{"prompt" => "x"}, query_fun: respond("done"))

assert ObanCodex.text(result) == "done"

query = sequence([error(:timeout), structured_result(%{"outcome" => "done"})])
```

Fixtures are real `%CodexWrapper.Result{}` structs containing production-shaped
JSONL, so helper behavior is exercised rather than mocked around.

## CLI and installer

```console
# real, queueless Codex turn
mix oban_codex run "summarize the repo" \
  --working-dir . --sandbox read_only --approval-policy never

# dry-run the validated stored args
mix oban_codex args "summarize the repo" --sandbox read_only --json

# preflight binary, auth, config, and runtime health
mix oban_codex doctor
```

For a runnable SQLite/Lite scaffold:

```console
mix igniter.install oban_codex
```

The generated worker is offline by default via `query_fun`, so the first boot
doesn't start a model turn.

## Telemetry

Each turn emits:

- `[:oban_codex, :run, :start]`
- `[:oban_codex, :run, :stop]` for any completed CLI result
- `[:oban_codex, :run, :exception]` for a pre-result execution failure
- `[:oban_codex, :agent, :transition]` for Agent state changes

Run measurements include native `duration` and `cost_usd: 0.0`. Metadata can
contain prompts and raw output; redact before exporting it.

## Fleet safety

- Keep `max_attempts` low for mutating work; a retry is another model turn and
  may repeat writes.
- Pin `sandbox`, `approval_policy`, dangerous bypass flags, and `working_dir`
  with `:pinned_args` when enqueue input is semi-trusted.
- Set a finite `timeout`. Configure `CodexWrapper.Runner.Forcola` when you need
  the whole OS process group killed on timeout.
- Use `Oban.Plugins.Lifeline` for abandoned jobs and `Oban.Plugins.Pruner` for
  plaintext job-arg retention.
- Provide isolated checkouts yourself for concurrent mutating jobs. Codex has no
  `oban_claude`-style worktree option in this seam.
- Never enable `dangerously_bypass_approvals_and_sandbox` unless the worker is
  already protected by an external sandbox.

More patterns are in [Agent worker patterns](guides/agent_worker_patterns.md).

## License

MIT
