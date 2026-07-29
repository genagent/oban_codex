# Event-to-job mapping. The example stops before database insertion so it is
# safe and fast in CI; the produced changesets are exactly what a webhook,
# PubSub handler, or poller would pass to Oban.insert/1.
#
#     mix run examples/event_driven.exs

defmodule EventDriven.RepositoryEvent do
  def to_prompt(%{repo: repo, ref: ref, kind: :push}) do
    "Review the push to #{repo} at #{ref} and summarize risk."
  end

  def to_prompt(%{repo: repo, number: number, kind: :pull_request}) do
    "Review pull request #{repo}##{number} and summarize risk."
  end
end

defmodule EventDriven.Worker do
  use ObanCodex.Worker,
    queue: :events,
    unique: [period: 60, fields: [:worker, :args]],
    pinned_args:
      ObanCodex.Args.defaults(
        sandbox: :read_only,
        approval_policy: :never
      )
end

events = [
  %{id: "evt-1", kind: :push, repo: "genagent/example", ref: "abc123"},
  %{id: "evt-2", kind: :pull_request, repo: "genagent/example", number: 42}
]

for event <- events do
  event
  |> EventDriven.RepositoryEvent.to_prompt()
  |> then(
    &ObanCodex.Args.new(
      prompt: &1,
      working_dir: "/srv/checkouts/example",
      meta: %{event_id: event.id}
    )
  )
  |> EventDriven.Worker.new()
  |> then(fn changeset ->
    IO.inspect(changeset.changes.args, label: "job args")
    IO.inspect(changeset.changes.unique, label: "uniqueness")
  end)
end
