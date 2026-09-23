# Demonstrate the timeout classification a retrying worker receives. The first
# turn intentionally has an unrealistically small timeout; the second is a
# manual follow-up with a practical timeout. This does not start Oban or an
# Agent process.
#
#     mix run examples/timeout_retry_live.exs

base =
  ObanCodex.Args.defaults(
    working_dir: File.cwd!(),
    sandbox: :read_only,
    approval_policy: :never,
    skip_git_repo_check: true
  )

first = Map.merge(base, %{"prompt" => "Reply with exactly recovered", "timeout" => 1})
IO.inspect(ObanCodex.run(first), label: "attempt 1")

second =
  Map.merge(base, %{
    "prompt" => "Reply with exactly recovered",
    "timeout" => :timer.minutes(2),
    "ephemeral" => true
  })

case ObanCodex.run(second) do
  {:ok, result} -> IO.puts("attempt 2: #{ObanCodex.text(result)}")
  other -> IO.inspect(other, label: "attempt 2")
end
