# Getting started

This guide builds an offline Codex worker first, then switches it to the real
CLI.

## 1. Add dependencies

```elixir
def deps do
  [
    {:ecto_sqlite3, "~> 0.17"},
    {:oban, "~> 2.23"},
    {:oban_codex, "~> 0.1"}
  ]
end
```

```console
mix deps.get
```

For an automated SQLite/Lite setup, use the installer instead:

```console
mix igniter.install oban_codex
```

## 2. Configure Oban

With an existing Ecto repo:

```elixir
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [codex: 2]
```

Add it to the supervision tree:

```elixir
children = [
  MyApp.Repo,
  {Oban, Application.fetch_env!(:my_app, Oban)}
]
```

Generate and run the Oban migration:

```console
mix ecto.gen.migration add_oban
```

```elixir
defmodule MyApp.Repo.Migrations.AddOban do
  use Ecto.Migration

  def up, do: Oban.Migrations.up()
  def down, do: Oban.Migrations.down(version: 1)
end
```

```console
mix ecto.migrate
```

## 3. Start with an offline worker

The injectable query function lets the entire Oban path run without a Codex
binary or model call:

```elixir
defmodule MyApp.SummaryWorker do
  use ObanCodex.Worker,
    queue: :codex,
    max_attempts: 3,
    args:
      ObanCodex.Args.defaults(
        sandbox: :read_only,
        approval_policy: :never
      ),
    query_fun: &__MODULE__.demo_query/2

  require Logger

  @impl ObanCodex.Worker
  def handle_result(result, _job) do
    Logger.info("Codex said: #{inspect(ObanCodex.text(result))}")
    :ok
  end

  def demo_query(prompt, _opts) do
    {:ok, ObanCodex.Testing.result("a summary of: #{prompt}")}
  end
end
```

Enqueue a job:

```elixir
ObanCodex.Args.new(
  prompt: "the oban_codex README",
  meta: %{request_id: "demo-1"}
)
|> MyApp.SummaryWorker.new()
|> Oban.insert()
```

The stored map uses string keys. `meta` is flattened into it, available to the
job and telemetry, but ignored by the Codex adapter.

## 4. Test the seam

```elixir
use ExUnit.Case

import ObanCodex.Testing

test "reads a structured verdict" do
  result = structured_result(%{"outcome" => "done"}, session_id: "thread-1")

  assert ObanCodex.outcome(result) == "done"
  assert ObanCodex.session_id(result) == "thread-1"
end
```

For worker tests, use `Oban.Testing.perform_job/3` when possible so args pass
through the same JSON encode/decode boundary as production.

## 5. Switch to the real Codex CLI

Install and authenticate Codex on every worker node, then check it:

```console
mix oban_codex doctor
```

Remove `query_fun` from the worker. Set a real working directory:

```elixir
use ObanCodex.Worker,
  queue: :codex,
  max_attempts: 2,
  args:
    ObanCodex.Args.defaults(
      working_dir: "/srv/checkouts/my_app",
      sandbox: :read_only,
      approval_policy: :never,
      timeout: :timer.minutes(10)
    )
```

The default path builds `CodexWrapper.Exec`, forces JSONL, and returns the raw
`%CodexWrapper.Result{}`. Use `ObanCodex.text/1`, `events/1`, `usage/1`, and
`session_id/1` to read it.

## 6. Structured output

Place a schema where every worker node can read it:

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["outcome", "summary"],
  "properties": {
    "outcome": {
      "type": "string",
      "enum": ["done", "blocked"]
    },
    "summary": {
      "type": "string"
    }
  }
}
```

Then:

```elixir
ObanCodex.Args.new(
  prompt: "inspect the repository and report",
  output_schema: "/srv/my_app/priv/report.schema.json",
  sandbox: :read_only,
  approval_policy: :never
)
```

```elixir
case ObanCodex.structured(result) do
  %{"outcome" => "done", "summary" => summary} -> persist(summary)
  %{"outcome" => "blocked"} -> {:cancel, :blocked}
  nil -> {:error, :missing_structured_output}
end
```

## 7. Production checks

- Pin security controls with `pinned_args` if enqueue input isn't fully trusted.
- Keep secrets out of args; they are plaintext database data.
- Set a finite command timeout.
- Keep attempts low for workers that mutate files or external systems.
- Add Oban Lifeline and Pruner plugins.
- Provide one isolated checkout per concurrent mutating job.
- Consider `CodexWrapper.Runner.Forcola` for process-group termination.
- Remember that session state is node-local and that `ephemeral` sessions cannot
  be resumed.

Continue with [Agent worker patterns](agent_worker_patterns.html) or the
experimental [Agent lifecycle](agent_lifecycle.html).
