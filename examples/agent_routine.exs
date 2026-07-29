# A scheduled Agent beat is a prompt with origin :tick. Agent.Tick is the Oban
# adapter in production; this offline example delivers the same event directly.
#
#     mix run examples/agent_routine.exs

alias ObanCodex.Agent

{:ok, supervisor} = ObanCodex.Agent.Supervisor.start_link([])
parent = self()

enqueue = fn args, meta ->
  send(parent, {:turn, args, meta})
  {:ok, :queued}
end

{:ok, _} = Agent.start_agent("routine", enqueue_fun: enqueue)

:processing =
  Agent.submit_prompt(
    "routine",
    "Run the scheduled repository sweep.",
    origin: :tick,
    session: :fresh
  )

receive do
  {:turn, args, %{"origin" => "tick"} = meta} ->
    IO.inspect(args, label: "scheduled turn")
    IO.inspect(meta, label: "metadata")
end

:ok =
  Agent.job_finished(
    "routine",
    {:ok, ObanCodex.Testing.result("sweep complete", session_id: "thread-routine")}
  )

{:ok, :idle} = Agent.await("routine", :idle)
IO.inspect(Agent.info("routine"), label: "routine")
Supervisor.stop(supervisor)
