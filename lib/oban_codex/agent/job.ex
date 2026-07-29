defmodule ObanCodex.Agent.Job do
  @moduledoc """
  The default Oban worker for agent turns: runs Codex, then routes the
  outcome back to the owning `ObanCodex.Agent.Instance`.

  The owning agent's id rides in the job's meta (`"agent_id"`), where
  `ObanCodex.Agent.Instance` puts it at enqueue time. A job without an
  `"agent_id"` (enqueued by hand) runs normally and reports to no one.

  ## Retry-awareness

  The routing is terminal-aware, so a worker with retries reports one logical
  turn, not one event per attempt:

    * a success, a `{:cancel, _}` verdict, or an `{:error, _}` on the final
      attempt is terminal -> `ObanCodex.Agent.job_finished/2`
    * an `{:error, _}` with attempts remaining, or a `{:snooze, _}`, means
      Oban will re-run the job -> `ObanCodex.Agent.job_retrying/2`, which
      keeps the machine in `:running` and re-arms its watchdog

  This worker itself stays at `max_attempts: 1` -- every retry is a fresh paid
  Codex call, so retrying is an explicit opt-in, not a default. To opt in,
  point the agent's `:worker` config at your own worker and delegate the
  callbacks here:

      defmodule MyApp.RetryingAgentJob do
        use ObanCodex.Worker, queue: :agents, max_attempts: 3

        @impl ObanCodex.Worker
        def handle_result(result, job), do: ObanCodex.Agent.Job.handle_result(result, job)

        @impl ObanCodex.Worker
        def handle_error(verdict, payload, job),
          do: ObanCodex.Agent.Job.handle_error(verdict, payload, job)
      end
  """

  use ObanCodex.Worker, queue: :agents, max_attempts: 1

  @impl ObanCodex.Worker
  def handle_result(result, %Oban.Job{meta: %{"agent_id" => agent_id}}) do
    ObanCodex.Agent.job_finished(agent_id, {:ok, result})
    :ok
  end

  def handle_result(_result, _job), do: :ok

  @impl ObanCodex.Worker
  def handle_error(oban_return, payload, %Oban.Job{meta: %{"agent_id" => agent_id}} = job) do
    if terminal?(oban_return, job) do
      ObanCodex.Agent.job_finished(agent_id, {:error, oban_return, payload})
    else
      ObanCodex.Agent.job_retrying(agent_id, %{
        attempt: job.attempt,
        max_attempts: job.max_attempts,
        verdict: oban_return
      })
    end

    oban_return
  end

  def handle_error(oban_return, _payload, _job), do: oban_return

  # Will Oban re-run this job after the verdict? {:cancel, _} never; {:error, _}
  # only with attempts left; {:snooze, _} always (and a snooze grows
  # max_attempts, so the attempt comparison cannot misread it as final).
  defp terminal?({:cancel, _reason}, _job), do: true
  defp terminal?({:error, _reason}, job), do: job.attempt >= job.max_attempts
  defp terminal?({:snooze, _period}, _job), do: false
  defp terminal?(_other, _job), do: true
end
