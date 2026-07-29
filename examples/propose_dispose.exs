# Structured propose/dispose without a database:
# Codex proposes a typed action under read-only policy; a deterministic handler
# disposes it. The Codex turn is stubbed, but the worker seam is real.
#
#     mix run examples/propose_dispose.exs

defmodule ProposeDispose.Sink do
  use Agent

  def start_link(_), do: Agent.start_link(fn -> [] end, name: __MODULE__)
  def record(value), do: Agent.update(__MODULE__, &[value | &1])
  def all, do: Agent.get(__MODULE__, &Enum.reverse/1)
end

defmodule ProposeDispose.Worker do
  use ObanCodex.Worker,
    queue: :triage,
    max_attempts: 2,
    pinned_args:
      ObanCodex.Args.defaults(
        sandbox: :read_only,
        approval_policy: :never,
        output_schema: "/srv/app/priv/triage.schema.json"
      ),
    query_fun: &__MODULE__.fake_query/2

  def fake_query(prompt, _opts) do
    {:ok,
     ObanCodex.Testing.structured_result(%{
       "outcome" => prompt,
       "summary" => "proposal for #{prompt}"
     })}
  end

  @impl ObanCodex.Worker
  def handle_result(result, job) do
    case ObanCodex.structured(result) do
      %{"outcome" => "fix", "summary" => summary} ->
        ProposeDispose.Sink.record({:implement, job.args["issue"], summary})
        :ok

      %{"outcome" => "needs_review", "summary" => summary} ->
        ProposeDispose.Sink.record({:review, job.args["issue"], summary})
        :ok

      %{"outcome" => "wontfix"} ->
        {:cancel, :wontfix}
    end
  end
end

{:ok, _} = ProposeDispose.Sink.start_link(nil)

for {issue, outcome} <- [{87, "fix"}, {88, "needs_review"}, {89, "wontfix"}] do
  args = %{"prompt" => outcome, "issue" => issue}
  verdict = ProposeDispose.Worker.perform(%Oban.Job{args: args})
  IO.puts("issue #{issue}: #{inspect(verdict)}")
end

IO.inspect(ProposeDispose.Sink.all(), label: "disposed effects")
