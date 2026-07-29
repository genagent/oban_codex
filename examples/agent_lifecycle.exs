# Offline Agent lifecycle: an injected enqueue function lets this script play
# the worker's return path without Oban or Codex.
#
#     mix run examples/agent_lifecycle.exs

alias ObanCodex.Agent

{:ok, supervisor} = ObanCodex.Agent.Supervisor.start_link([])
parent = self()

enqueue = fn args, meta ->
  send(parent, {:enqueued, args, meta})
  {:ok, :queued}
end

{:ok, _pid} =
  Agent.start_agent("demo",
    enqueue_fun: enqueue,
    args: %{
      "sandbox" => "read_only",
      "approval_policy" => "never",
      "output_schema" => "/srv/app/priv/agent.schema.json"
    },
    approved_args: %{
      "sandbox" => "workspace_write",
      "approval_policy" => "never"
    }
  )

:processing = Agent.submit_prompt("demo", "inspect the project")

assert_receive = fn ->
  receive do
    {:enqueued, args, meta} ->
      IO.inspect(args, label: "enqueued")
      IO.inspect(meta, label: "meta")
  after
    1_000 -> raise "turn was not enqueued"
  end
end

assert_receive.()

permission =
  ObanCodex.Testing.structured_result(
    %{"directive" => "request_permission", "action" => "update lib/core.ex"},
    session_id: "thread-demo"
  )

:ok = Agent.job_finished("demo", {:ok, permission})

{:ok, {:awaiting_permission, %{id: action_id} = action}} =
  Agent.await("demo", :awaiting_permission)

IO.inspect(action, label: "permission gate")
:processing = Agent.approve_action("demo", action_id)
assert_receive.()

:ok =
  Agent.job_finished(
    "demo",
    {:ok,
     ObanCodex.Testing.structured_result(
       %{"directive" => "none", "summary" => "updated"},
       session_id: "thread-demo"
     )}
  )

{:ok, :idle} = Agent.await("demo", :idle)
IO.inspect(Agent.info("demo"), label: "agent info")
IO.inspect(Agent.history("demo"), label: "history")

Supervisor.stop(supervisor)
