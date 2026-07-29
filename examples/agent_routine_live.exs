# Run one real "routine beat". In production Oban.Plugins.Cron inserts
# ObanCodex.Agent.Tick with equivalent args.
#
#     mix run examples/agent_routine_live.exs

args =
  ObanCodex.Args.new(
    prompt: "Reply with one short haiku about durable job queues.",
    working_dir: File.cwd!(),
    sandbox: :read_only,
    approval_policy: :never,
    skip_git_repo_check: true,
    ephemeral: true,
    timeout: :timer.minutes(3)
  )

case ObanCodex.run(args) do
  {:ok, result} ->
    IO.puts(ObanCodex.text(result))
    IO.inspect(ObanCodex.usage(result), label: "usage")

  other ->
    IO.inspect(other, label: "routine failed")
end

IO.puts("""

Cron shape:

    {Oban.Plugins.Cron,
     crontab: [
       {"0 * * * *", ObanCodex.Agent.Tick,
        args: %{
          "agent_id" => "hourly",
          "prompt" => "run the hourly sweep",
          "session" => "fresh",
          "if_offline" => "start"
        }}
     ]}
""")
