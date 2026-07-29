# A scheduled routine keeps its entire task definition in worker defaults, so
# Cron inserts an empty job. This offline script performs one such job directly.
#
#     mix run examples/scheduled_routine.exs

defmodule ScheduledRoutine.Worker do
  use ObanCodex.Worker,
    queue: :routine,
    max_attempts: 2,
    args:
      ObanCodex.Args.defaults(
        prompt: "Summarize repository changes since yesterday.",
        sandbox: :read_only,
        approval_policy: :never
      ),
    query_fun: &__MODULE__.fake_query/2

  def fake_query(prompt, opts) do
    IO.inspect({prompt, opts}, label: "Codex invocation")
    {:ok, ObanCodex.Testing.result("daily summary produced")}
  end

  @impl ObanCodex.Worker
  def handle_result(result, _job) do
    IO.puts(ObanCodex.text(result))
    :ok
  end
end

:ok = ScheduledRoutine.Worker.perform(%Oban.Job{args: %{}})

IO.puts("""

Production Cron configuration:

    config :my_app, Oban,
      plugins: [
        {Oban.Plugins.Cron,
         crontab: [{"0 6 * * *", ScheduledRoutine.Worker}]}
      ]
""")
