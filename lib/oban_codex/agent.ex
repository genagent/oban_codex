defmodule ObanCodex.Agent do
  @moduledoc """
  A facade over long-lived agent processes whose turns run as Oban jobs.

  > #### Experimental {: .warning}
  >
  > The agent layer is the stateful floor above the stateless `ObanCodex`
  > seam. It is opt-in (nothing runs unless `ObanCodex.Agent.Supervisor` is
  > in your tree) and experimental: the API may change between minor
  > releases while it carries this marker. See the
  > [Agent lifecycle](agent_lifecycle.html) guide.

  One agent is one `ObanCodex.Agent.Instance` (`:gen_statem`) registered
  under a caller-chosen id. A prompt does not block on Codex: it enqueues an
  `ObanCodex.Worker` job and the state machine parks in `:running` until the
  worker reports back through `job_finished/3`. All interaction goes through
  this module; nothing here messages a process that is not running.

      {:ok, _pid} = ObanCodex.Agent.start_agent("triage-7",
        args: ObanCodex.Args.defaults(model: "gpt-5"))

      :processing = ObanCodex.Agent.submit_prompt("triage-7", "triage the new issues")
      {:ok, :running} = ObanCodex.Agent.status("triage-7")

      {:ok, {:awaiting_permission, %{id: id}}} =
        ObanCodex.Agent.await("triage-7", [:idle, :awaiting_permission, :waiting_for_user])
      :processing = ObanCodex.Agent.approve_action("triage-7", id)

  Requires `ObanCodex.Agent.Supervisor` in the host supervision tree.
  """

  @registry ObanCodex.Agent.Registry
  @supervisor ObanCodex.Agent.InstanceSupervisor

  @typedoc "The caller-chosen agent identity, unique per running agent."
  @type agent_id :: term()

  @typedoc """
  What `status/1` returns: a bare state atom, except the two gated states,
  which atomically carry what they are gated on (the action map holds the
  `:id` that `approve_action/2` / `reject_action/3` take). `:offline` when the
  agent is not running.
  """
  @type status ::
          :idle
          | :running
          | :paused
          | :offline
          | {:awaiting_permission, %{id: String.t(), description: String.t()}}
          | {:waiting_for_user, String.t() | nil}

  @typedoc "A safe-boundary pause retained from its source turn until resume."
  @type pause_latch :: %{
          cause: :pause_after_turn | :quiesce,
          reason: term(),
          source_generation: String.t(),
          source_turn_id: String.t(),
          owner_generation: String.t(),
          owner_turn_id: String.t(),
          owner_arc_id: String.t(),
          owner_correlation_id: String.t() | nil
        }

  @typedoc "A correlated safe-boundary pause validation failure."
  @type pause_after_turn_error ::
          :agent_not_running
          | :agent_id_mismatch
          | :malformed_identity
          | :foreign_generation
          | :retired_turn
          | :stale_turn
          | {:invalid_state, atom()}

  @doc """
  Spawn a new agent under the dynamic supervisor.

  Starting an id that is already running returns the existing pid, so the call
  is idempotent. See `ObanCodex.Agent.Instance` for the config keys.
  """
  @spec start_agent(agent_id(), keyword() | map()) :: {:ok, pid()} | {:error, term()}
  def start_agent(agent_id, config \\ []) do
    case DynamicSupervisor.start_child(
           @supervisor,
           {ObanCodex.Agent.Instance, {agent_id, config}}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  @doc "Cleanly stop a running agent (`:transient`, so it is not restarted)."
  @spec stop_agent(agent_id()) :: :ok | {:error, :agent_not_running}
  def stop_agent(agent_id) do
    with_agent(agent_id, &:gen_statem.stop/1)
  end

  @doc """
  Read the agent's lifecycle status from registry metadata, without messaging
  the process: one atomic read of the state *and*, in the gated states, the
  pending action or question it is gated on -- so there is no torn
  status-then-payload sequence.

      {:ok, :running} = status("live")
      {:ok, {:awaiting_permission, %{id: id, description: d}}} = status("live")
      {:ok, {:waiting_for_user, question}} = status("live")

  An unknown or stopped agent reads as `{:ok, :offline}`. Registry cleanup
  after a process death is asynchronous, so `:offline` after `stop_agent/1`
  is eventually-consistent -- `await(id, :offline)` if you need to block on it.
  """
  @spec status(agent_id()) :: {:ok, status()}
  def status(agent_id) do
    case Registry.lookup(@registry, agent_id) do
      [{_pid, value}] -> {:ok, value}
      [] -> {:ok, :offline}
    end
  end

  @doc """
  All running agents as `{agent_id, status}` pairs, straight off the registry
  (no process is messaged). Order is unspecified. The fleet-inventory read for
  dashboards and supervisors.
  """
  @spec list() :: [{agent_id(), status()}]
  def list do
    Registry.select(@registry, [{{:"$1", :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
  end

  @doc """
  Block until the agent settles into one of `states` (a state atom or list of
  them), returning the full `t:status/0` it landed on -- so a gated state
  arrives with its payload:

      case ObanCodex.Agent.await("live", [:idle, :awaiting_permission], 300_000) do
        {:ok, {:awaiting_permission, %{id: id}}} -> ObanCodex.Agent.approve_action("live", id)
        {:ok, :idle} -> :done
      end

  Polls the registry (25ms), so it never messages the agent. `:offline` is
  awaitable (e.g. after `stop_agent/1`). Returns `{:error, :timeout}` when the
  deadline passes first.
  """
  @spec await(agent_id(), atom() | [atom()], timeout :: pos_integer()) ::
          {:ok, status()} | {:error, :timeout}
  def await(agent_id, states, timeout \\ 60_000) do
    states = List.wrap(states)
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_await(agent_id, states, deadline)
  end

  @doc """
  Send a prompt to a running agent. Synchronous: replies `:processing` once the
  turn's Oban job is enqueued.

  In `:running` and `:awaiting_permission` the call blocks (the machine
  postpones it) until the turn finishes / the gate clears; in
  `:waiting_for_user` the prompt is the answer to the pending question and
  resumes the Codex session.

  Options (shared with `cast_prompt/3`):

    * `:session` -- `:resume` (default) continues the agent's Codex session;
      `:fresh` starts a new one for this turn (the resume handle is cleared at
      delivery time, so it composes with queued prompts); `:fresh_fallback`
      records that the host deliberately started fresh after a failed resume.
    * `:arc_id` -- an opaque non-empty string naming the provider conversation;
      defaults to `"default"`. Arcs isolate their session handles while the
      agent remains single-turn-at-a-time.
    * `:origin` -- `:operator` (default) or `:tick`. A `:tick` prompt is a
      scheduled delivery: in `:waiting_for_user` it queues behind the pending
      question instead of being consumed as the answer.
      `ObanCodex.Agent.Tick` sets this; operators rarely should.
    * `:correlation_id` -- an optional opaque application-owned string carried
      through postponed delivery, Oban job metadata, and Agent lifecycle
      telemetry. The wrapper preserves it but does not interpret it.
  """
  @spec submit_prompt(agent_id(), String.t(), keyword()) :: :processing | {:error, term()}
  def submit_prompt(agent_id, prompt, opts \\ []) do
    call(agent_id, {:user_prompt, prompt, prompt_opts(opts)})
  end

  @doc """
  The fire-and-forget form of `submit_prompt/3`: never blocks the caller.

  Returns `:ok` as soon as the cast is sent -- there is no `:processing`
  acknowledgment and no error reply on a failed enqueue (that lands in
  `history/1` as `{:enqueue_failed, reason}`). State handling matches
  `submit_prompt/3` -- queued in `:running` / `:awaiting_permission`, the
  answer in `:waiting_for_user` -- except `:paused`, where the prompt is
  dropped (recorded as `{:dropped_prompt, text}`) since lockdown has no caller
  to refuse. Use this from callers that must not block on a busy agent (a
  LiveView event handler, a scheduler); use `submit_prompt/3` when you want
  backpressure and the enqueue acknowledgment. Takes the same options.
  """
  @spec cast_prompt(agent_id(), String.t(), keyword()) :: :ok | {:error, :agent_not_running}
  def cast_prompt(agent_id, prompt, opts \\ []) do
    # validate opts eagerly, before the registry lookup can short-circuit
    event = {:user_prompt, prompt, prompt_opts(opts)}
    with_agent(agent_id, &:gen_statem.cast(&1, event))
  end

  @doc """
  Fork one named conversation arc into another and run `prompt` on the fork.

  The turn runs `codex exec fork` from the source arc's session handle, so the
  source conversation is left untouched. When the turn completes, the new
  thread id from its result becomes the target arc's handle. A target arc that
  already has a handle is replaced; its previous id is reported as
  `:replaced_session_id` in the job metadata and the completion telemetry. The
  source arc's handle is never rewritten, and a failed fork leaves the target
  arc as it was.

  Like `submit_prompt/3` this replies `:processing` once the turn's Oban job is
  enqueued, and blocks while the agent is busy. Nothing is enqueued and an
  error is returned when the arcs are the same (`{:error, :same_arc}`) or the
  source arc has no session handle yet
  (`{:error, {:enqueue_failed, {:fork_source_missing, source_arc_id}}}`).

  Options: `:origin` and `:correlation_id`, as for `submit_prompt/3`.
  """
  @spec fork_arc(agent_id(), String.t(), String.t(), String.t(), keyword()) ::
          :processing | {:error, term()}
  def fork_arc(agent_id, source_arc_id, target_arc_id, prompt, opts \\ []) do
    require_arc_id!(:source_arc_id, source_arc_id)
    require_arc_id!(:target_arc_id, target_arc_id)

    if source_arc_id == target_arc_id do
      {:error, :same_arc}
    else
      fork_opts =
        opts
        |> Keyword.take([:origin, :correlation_id])
        |> Keyword.merge(arc_id: target_arc_id, fork_from: source_arc_id)

      submit_prompt(agent_id, prompt, fork_opts)
    end
  end

  @doc """
  Approve the pending action by id (read it off `status/1` or `await/3`).

  Treat action IDs as opaque strings. They include a process generation so an
  action left in durable downstream state cannot be confused with a new
  action after the BEAM or agent process restarts.

  The continuation turn resumes the Codex session with the approved action as
  its prompt, and carries the agent's `:approved_args` (e.g. a
  `sandbox` elevation) merged over the default args -- so approval
  actually unlocks the tools the action needs, on that turn only.

  ## Options

    * `:args` -- a string-keyed map of Codex args merged over `:approved_args`
      for this continuation only. The caller can size the elevation to the
      action that was approved. Nothing is remembered; a later approval uses
      the standing args again unless it supplies another override. Non-string
      keys are refused with `{:error, {:invalid_args, keys}}` and the action
      stays pending.
  """
  @spec approve_action(agent_id(), String.t(), keyword()) :: :processing | {:error, term()}
  def approve_action(agent_id, action_id, opts \\ []) do
    call(agent_id, {:approve_action, action_id, Keyword.get(opts, :args, %{})})
  end

  @doc "Reject the pending action. Records the denial and returns to `:idle`, or `:paused` when a safe-boundary pause is latched."
  @spec reject_action(agent_id(), String.t(), String.t()) :: :rejected | {:error, term()}
  def reject_action(agent_id, action_id, reason \\ "denied") do
    call(agent_id, {:reject_action, action_id, reason})
  end

  @doc """
  Latch a pause at the current turn's next safe boundary.

  This is the correlated counterpart to `emergency_pause/1`. The caller must
  pass the complete job metadata captured for the turn. The turn may still be
  running or may have just completed into a question or permission gate. The
  call returns only after the Agent has validated the instance generation and
  logical turn id and stored the latch, so a following `job_finished/3` cannot
  race ahead of it.

  Ordinary completion, failure, or watchdog expiry applies the pause. An
  `ask_user` or `request_permission` directive remains visible instead; one
  answer or approval continuation is allowed, with the latch retained until
  that continuation completes or opens another gate. Repeating the call with
  the same captured identity is idempotent and keeps the first reason.
  """
  @spec pause_after_turn(agent_id(), term(), map()) :: :ok | {:error, pause_after_turn_error()}
  def pause_after_turn(agent_id, reason, captured_meta) do
    call(agent_id, {:pause_after_turn, reason, captured_meta})
  end

  @doc """
  Move an agent to a safe paused boundary for host-managed replacement.

  An idle agent pauses immediately. A running agent arms a pause for the
  current turn; an agent behind a question or permission gate keeps that gate,
  allows its one continuation, and pauses when the continuation reaches a safe
  boundary. An already paused agent is left unchanged when it has no retained
  turn. If an emergency-paused turn has not reported its terminal outcome,
  `quiesce/2` returns `:draining`; that is not a safe replacement boundary, and
  the caller should retry after the turn drains.

  Unlike `pause_after_turn/3`, this call is initiated by the host and does not
  require captured job metadata. The state check and latch installation happen
  atomically inside the Agent process.
  """
  @spec quiesce(agent_id(), term()) ::
          :paused | :armed | :already_paused | :draining | {:error, :agent_not_running}
  def quiesce(agent_id, reason), do: call(agent_id, {:quiesce, reason})

  @doc "Asynchronously force the agent into `:paused` lockdown, from any state. Drops any pending action or question."
  @spec emergency_pause(agent_id()) :: :ok | {:error, :agent_not_running}
  def emergency_pause(agent_id) do
    with_agent(agent_id, &:gen_statem.cast(&1, :emergency_pause))
  end

  @doc "Synchronously force the agent into `:paused` and acknowledge retained pause provenance."
  @spec emergency_pause(agent_id(), map()) :: :ok | {:error, :agent_not_running}
  def emergency_pause(agent_id, context) when is_map(context) do
    call(agent_id, {:emergency_pause, context})
  end

  @doc "Release a `:paused` agent back to `:idle`."
  @spec resume_agent(agent_id()) :: :resumed | {:error, term()}
  def resume_agent(agent_id), do: call(agent_id, :resume)

  @doc """
  The agent's bookkeeping in one map. `:session_id` remains the legacy default
  arc handle; `:session_arcs`, `:active_arc_id`, and `:continuation` expose the
  named-arc state and the current or most recent fresh/resume decision. Also
  includes `:state`, `:turns`, accumulated `:cost_usd`, any pending gate, the
  host's optional `:config_revision`, and the `t:pause_latch/0` under
  `:deferred_pause` when a safe-boundary pause is active. While paused,
  `:pause_context` retains the metadata that applied the pause.
  """
  @spec info(agent_id()) :: {:ok, map()} | {:error, :agent_not_running}
  def info(agent_id), do: call(agent_id, :info)

  @doc """
  The agent's event log, oldest first. Works in every state. Result entries
  are `{:result, structured_output_map}` for `--json-schema` turns and
  `{:result, text}` otherwise.
  """
  @spec history(agent_id()) :: {:ok, list()} | {:error, :agent_not_running}
  def history(agent_id), do: call(agent_id, :history)

  @doc """
  The return path for workers: report a finished turn back to its agent.

  `ObanCodex.Agent.Job` calls this from `handle_result/2` /
  `handle_error/3` with the complete metadata captured by the job. Payload
  shapes: `{:ok, %CodexWrapper.Result{}}` on success, or
  `{:error, oban_return, payload}` for a failed turn. Fire-and-forget: if the
  agent is gone the outcome is dropped.
  """
  @spec job_finished(
          agent_id(),
          {:ok, CodexWrapper.Result.t()} | {:error, term(), term()},
          map()
        ) :: :ok | {:error, :agent_not_running | :turn_identity_required}
  def job_finished(agent_id, payload, captured_meta) do
    with_identity(agent_id, captured_meta, fn ->
      with_agent(agent_id, &:gen_statem.cast(&1, {:job_finished, payload, captured_meta}))
    end)
  end

  @deprecated "pass the job metadata as the third argument"
  @spec job_finished(agent_id(), term()) :: {:error, :turn_identity_required}
  def job_finished(_agent_id, _payload), do: {:error, :turn_identity_required}

  @doc """
  The retry half of the return path: report a failed-but-retryable attempt.

  `ObanCodex.Agent.Job`'s error callback calls this when Oban will re-run
  the job (an `{:error, _}` with attempts remaining, or a `{:snooze, _}`). The
  machine stays in `:running` -- the logical turn is still in flight -- records
  `{:retrying, retry}` in history, and re-arms the `:job_timeout` watchdog to
  cover the retry's backoff plus execution. `retry` is
  `%{attempt:, max_attempts:, verdict:}`. Fire-and-forget, like
  `job_finished/3`.
  """
  @spec job_retrying(agent_id(), map(), map()) ::
          :ok | {:error, :agent_not_running | :turn_identity_required}
  def job_retrying(agent_id, retry, captured_meta) do
    with_identity(agent_id, captured_meta, fn ->
      with_agent(agent_id, &:gen_statem.cast(&1, {:job_retrying, retry, captured_meta}))
    end)
  end

  @deprecated "pass the job metadata as the third argument"
  @spec job_retrying(agent_id(), map()) :: {:error, :turn_identity_required}
  def job_retrying(_agent_id, _retry), do: {:error, :turn_identity_required}

  defp with_identity(agent_id, %{"agent_id" => captured_id}, fun)
       when captured_id === agent_id and is_function(fun, 0),
       do: fun.()

  defp with_identity(_agent_id, _captured_meta, _fun), do: {:error, :turn_identity_required}

  defp prompt_opts(opts) do
    session = Keyword.get(opts, :session, :resume)
    origin = Keyword.get(opts, :origin, :operator)
    arc_id = Keyword.get(opts, :arc_id)
    fork_from = Keyword.get(opts, :fork_from)
    correlation_id = Keyword.get(opts, :correlation_id)

    unless session in [:resume, :fresh, :fresh_fallback] do
      raise ArgumentError,
            "unknown :session #{inspect(session)}; expected :resume, :fresh, or :fresh_fallback"
    end

    unless origin in [:operator, :tick] do
      raise ArgumentError, "unknown :origin #{inspect(origin)}; expected :operator or :tick"
    end

    validate_arc_id!(:arc_id, arc_id)
    validate_arc_id!(:fork_from, fork_from)
    validate_correlation_id!(correlation_id)

    %{
      session: session,
      origin: origin,
      arc_id: arc_id,
      fork_from: fork_from,
      correlation_id: correlation_id
    }
  end

  defp require_arc_id!(name, nil) do
    raise ArgumentError, ":#{name} must be a non-empty string of at most 256 bytes, got: nil"
  end

  defp require_arc_id!(name, value), do: validate_arc_id!(name, value)

  defp validate_arc_id!(_name, nil), do: :ok

  defp validate_arc_id!(_name, value)
       when is_binary(value) and byte_size(value) in 1..256,
       do: :ok

  defp validate_arc_id!(name, value) do
    raise ArgumentError,
          ":#{name} must be a non-empty string of at most 256 bytes, got: #{inspect(value)}"
  end

  defp validate_correlation_id!(nil), do: :ok

  defp validate_correlation_id!(value)
       when is_binary(value) and byte_size(value) in 1..256,
       do: :ok

  defp validate_correlation_id!(value) do
    raise ArgumentError,
          ":correlation_id must be a non-empty string of at most 256 bytes, got: #{inspect(value)}"
  end

  defp poll_await(agent_id, states, deadline) do
    {:ok, current} = status(agent_id)

    cond do
      status_state(current) in states ->
        {:ok, current}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(25)
        poll_await(agent_id, states, deadline)
    end
  end

  defp status_state({state, _payload}), do: state
  defp status_state(state) when is_atom(state), do: state

  defp call(agent_id, request), do: with_agent(agent_id, &:gen_statem.call(&1, request))

  defp with_agent(agent_id, fun) do
    case Registry.lookup(@registry, agent_id) do
      [{pid, _state}] -> fun.(pid)
      [] -> {:error, :agent_not_running}
    end
  end
end
