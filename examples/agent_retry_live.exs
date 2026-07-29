# Demonstrate the real timeout classification used by retrying Agent workers.
# The first turn intentionally has an unrealistically small timeout; the second
# is the manual equivalent of Oban's later attempt.
#
#     mix run examples/agent_retry_live.exs

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
