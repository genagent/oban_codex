defmodule ObanCodex do
  @moduledoc """
  Run Codex CLI work on an Oban queue.

  `oban_codex` is the thin seam between `codex_wrapper` and Oban:

    * `run/2` accepts the string-keyed map Oban stores, executes a JSONL Codex
      turn, and maps the outcome to an Oban return value.
    * `ObanCodex.Worker` supplies the drop-in worker and two result hooks.
    * `ObanCodex.Args` validates native Elixir options before enqueue.
    * result helpers (`text/1`, `structured/1`, `session_id/1`, `usage/1`) hide
      Codex's JSONL event representation.

  The underlying successful payload stays a `%CodexWrapper.Result{}`. That
  keeps the seam honest while the helpers offer the ergonomic fields available
  directly in `oban_claude`.

  ## Example

      defmodule MyApp.CodexJob do
        use ObanCodex.Worker, queue: :codex, max_attempts: 3
      end

      ObanCodex.Args.new(
        prompt: "summarize the repository",
        working_dir: "/path/to/repo",
        sandbox: :read_only
      )
      |> MyApp.CodexJob.new()
      |> Oban.insert()

  ## Telemetry

  Every run emits `[:oban_codex, :run, :start]`, followed by either
  `[:oban_codex, :run, :stop]` when the CLI produced a result (including a
  non-zero exit), or `[:oban_codex, :run, :exception]` when execution failed
  before a result was available.

  Measurements include `:duration` in native time units and `:cost_usd`, which
  is always `0.0` because Codex's JSON event contract doesn't report price.
  Metadata includes the stored args and a slim job identity map.

  > #### Data handling {: .warning}
  >
  > Prompts, metadata, JSONL output, and CLI error text can ride on telemetry
  > events. Redact them before exporting telemetry to a log aggregator.
  """

  alias CodexWrapper.{JsonLineEvent, Result}
  alias ObanCodex.Error

  @typedoc """
  An `c:Oban.Worker.perform/1` return. `:snooze` accepts Oban's period form.
  """
  @type oban_return ::
          :ok | {:ok, term()} | {:error, term()} | {:cancel, term()} | {:snooze, Oban.Period.t()}

  @typedoc "The result of the Codex entrypoint."
  @type wrapper_outcome :: {:ok, Result.t()} | {:error, Error.t() | term()}

  @typedoc "Maps a wrapper outcome to the `{oban_return, payload}` envelope."
  @type classifier :: (wrapper_outcome() -> {oban_return(), term()})

  @typedoc "The injectable Codex entrypoint: `(prompt, query_opts) -> outcome`."
  @type query_fun :: (String.t(), keyword() -> wrapper_outcome())

  @passthrough ~w(model profile sandbox approval_policy full_auto
                  dangerously_bypass_approvals_and_sandbox
                  dangerously_bypass_hook_trust working_dir timeout verbose binary
                  add_dir search ephemeral output_schema output_last_message images
                  config_overrides enabled_features disabled_features strict_config
                  ignore_user_config ignore_rules color oss local_provider session_id)

  @passthrough_atoms Map.new(@passthrough, &{&1, String.to_atom(&1)})

  @enum_values %{
    "sandbox" =>
      Map.new(~w(read_only workspace_write danger_full_access), &{&1, String.to_atom(&1)}),
    "approval_policy" => Map.new(~w(untrusted on_request never), &{&1, String.to_atom(&1)}),
    "search" => Map.new(~w(cached indexed live disabled), &{&1, String.to_atom(&1)}),
    "color" => Map.new(~w(always never auto), &{&1, String.to_atom(&1)})
  }

  @doc """
  Run one Codex turn from a string-keyed args map.

  The return is `{oban_return, payload}`: callers get both the Oban verdict and
  the underlying `%CodexWrapper.Result{}` or `%ObanCodex.Error{}`.

  Options:

    * `:classifier` — maps the query outcome to the envelope; defaults to
      `ObanCodex.Outcome.classify/1`.
    * `:query_fun` — injectable `(prompt, opts)` entrypoint; defaults to
      `ObanCodex.Query.run/2`.
    * `:job` — the current `%Oban.Job{}` for telemetry attribution.
  """
  @spec run(
          ObanCodex.Args.t(),
          [{:classifier, classifier()} | {:query_fun, query_fun()} | {:job, Oban.Job.t()}]
        ) :: {oban_return(), Result.t() | Error.t() | term()}
  def run(args, opts \\ []) when is_map(args) do
    classifier = Keyword.get(opts, :classifier, &ObanCodex.Outcome.classify/1)
    query_fun = Keyword.get(opts, :query_fun, &ObanCodex.Query.run/2)
    job = Keyword.get(opts, :job)
    {prompt, query_opts} = build(args)

    start = System.monotonic_time()
    emit_start(args, job)
    outcome = query_fun.(prompt, query_opts)
    emit(outcome, start, args, job)

    outcome
    |> classifier.()
    |> validate_classified!(classifier)
  end

  @doc "Parse the Codex JSONL stdout into event structs."
  @spec events(Result.t()) :: [JsonLineEvent.t()]
  def events(%Result{stdout: stdout}) when is_binary(stdout),
    do: JsonLineEvent.parse_lines(stdout)

  @doc """
  Return the final agent message text, or `nil` when no message was emitted.

  Query runs always force JSONL. For a custom query function that returns plain
  stdout, a non-empty stdout string is used as a compatibility fallback.
  """
  @spec text(Result.t()) :: String.t() | nil
  def text(%Result{} = result) do
    case final_agent_text(events(result)) do
      nil -> fallback_text(result.stdout)
      value -> value
    end
  end

  @doc """
  Decode the final agent message as a JSON object or array.

  Codex's `--output-schema` validates the final message but still emits it as
  text inside an `item.completed` event. Scalar JSON values intentionally
  return `nil`; structured worker contracts should use an object or array.
  """
  @spec structured(Result.t()) :: map() | list() | nil
  def structured(%Result{} = result) do
    with value when is_binary(value) <- text(result),
         {:ok, decoded} when is_map(decoded) or is_list(decoded) <- Jason.decode(value) do
      decoded
    else
      _ -> nil
    end
  end

  @doc "Read the conventional top-level `\"outcome\"` string from structured output."
  @spec outcome(Result.t()) :: String.t() | nil
  def outcome(%Result{} = result) do
    case structured(result) do
      %{"outcome" => value} when is_binary(value) -> value
      _ -> nil
    end
  end

  @doc """
  Return the Codex thread/session id carried by a result or normalized error.

  Current Codex versions emit `thread_id`; `session_id` remains a defensive
  fallback for older versions and forks.
  """
  @spec session_id(Result.t() | Error.t() | term()) :: String.t() | nil
  def session_id(%Result{} = result) do
    Enum.find_value(events(result), fn event ->
      JsonLineEvent.get(event, "thread_id") || JsonLineEvent.get(event, "session_id")
    end)
  end

  def session_id(%Error{reason: reason}) when is_map(reason),
    do: reason[:session_id] || reason["session_id"]

  def session_id(_), do: nil

  @doc """
  Return token usage from the final `turn.completed` event, or `nil`.
  """
  @spec usage(Result.t()) :: map() | nil
  def usage(%Result{} = result) do
    result
    |> events()
    |> Enum.reverse()
    |> Enum.find_value(fn
      %JsonLineEvent{event_type: "turn.completed", data: %{"usage" => usage}}
      when is_map(usage) ->
        usage

      _ ->
        nil
    end)
  end

  @doc """
  Return reported cost in USD.

  Codex doesn't currently include price in its JSONL contract, so a normal
  result returns `nil`. The error-map clause supports custom query functions.
  """
  @spec cost_usd(Result.t() | Error.t() | term()) :: number() | nil
  def cost_usd(%Result{}), do: nil

  def cost_usd(%Error{reason: reason}) when is_map(reason),
    do: reason[:cost_usd] || reason["cost_usd"]

  def cost_usd(_), do: nil

  defp build(args) do
    prompt = Map.fetch!(args, "prompt")

    if Map.has_key?(args, "resume") and Map.has_key?(args, "session_id") do
      raise ArgumentError,
            "set only one of resume or session_id; both identify the session to resume"
    end

    if (args["resume"] || args["session_id"]) && args["ephemeral"] do
      raise ArgumentError, "ephemeral sessions cannot be resumed"
    end

    args =
      case args["resume"] do
        nil -> args
        session_id -> Map.put(args, "session_id", session_id)
      end

    query_opts =
      for key <- @passthrough, Map.has_key?(args, key) do
        {Map.fetch!(@passthrough_atoms, key), coerce(key, args[key])}
      end

    {prompt, query_opts}
  end

  defp coerce(key, value) when is_binary(value) and is_map_key(@enum_values, key) do
    case get_in(@enum_values, [key, value]) do
      nil ->
        expected = @enum_values |> Map.fetch!(key) |> Map.keys() |> Enum.sort()

        raise ArgumentError,
              "unknown #{key} #{inspect(value)}; expected one of #{inspect(expected)}"

      atom ->
        atom
    end
  end

  defp coerce(_key, value), do: value

  defp final_agent_text(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %JsonLineEvent{
        event_type: "item.completed",
        data: %{"item" => %{"type" => "agent_message"} = item}
      } ->
        item["text"] || item["content"]

      _ ->
        nil
    end)
  end

  defp fallback_text(stdout) when is_binary(stdout) do
    case String.trim(stdout) do
      "" -> nil
      value -> value
    end
  end

  defp validate_classified!(classified, classifier) do
    if valid_return?(classified) do
      classified
    else
      raise ArgumentError, """
      classifier #{inspect(classifier)} returned #{inspect(classified)}, which \
      is not the required {oban_return, payload} envelope.

      The first element must be :ok, {:ok, term}, {:error, term}, \
      {:cancel, term}, or {:snooze, period}. A flat {:cancel, reason} is a \
      verdict, not the envelope; return {{:cancel, reason}, payload}.
      """
    end
  end

  defp valid_return?({:ok, _payload}), do: true
  defp valid_return?({{:ok, _}, _payload}), do: true
  defp valid_return?({{:error, _}, _payload}), do: true
  defp valid_return?({{:cancel, _}, _payload}), do: true
  defp valid_return?({{:snooze, n}, _payload}) when is_integer(n) and n > 0, do: true
  defp valid_return?({{:snooze, {n, _unit}}, _payload}) when is_integer(n) and n > 0, do: true
  defp valid_return?(_other), do: false

  defp emit_start(args, job) do
    :telemetry.execute(
      [:oban_codex, :run, :start],
      %{system_time: System.system_time()},
      %{args: args, job: job_meta(job)}
    )
  end

  defp emit({:ok, %Result{} = result}, start, args, job) do
    :telemetry.execute(
      [:oban_codex, :run, :stop],
      %{duration: System.monotonic_time() - start, cost_usd: 0.0},
      %{result: result, args: args, job: job_meta(job)}
    )
  end

  defp emit({:error, error}, start, args, job) do
    :telemetry.execute(
      [:oban_codex, :run, :exception],
      %{duration: System.monotonic_time() - start, cost_usd: cost_usd(error) || 0.0},
      %{error: error, args: args, job: job_meta(job)}
    )
  end

  defp emit(_off_contract, _start, _args, _job), do: :ok

  defp job_meta(%Oban.Job{} = job) do
    Map.take(job, [:id, :queue, :worker, :attempt, :max_attempts, :meta])
  end

  defp job_meta(_), do: nil
end
