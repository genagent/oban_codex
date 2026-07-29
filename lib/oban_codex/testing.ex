defmodule ObanCodex.Testing do
  @moduledoc """
  Build deterministic Codex outcomes for worker tests without invoking the CLI.

  The helpers encode the same JSONL events `ObanCodex` reads in production, so
  tests exercise `text/1`, `structured/1`, `session_id/1`, and `usage/1` rather
  than relying on a parallel fake result representation.

      import ObanCodex.Testing

      assert {:ok, result} =
               ObanCodex.run(%{"prompt" => "x"}, query_fun: respond("done"))

      assert ObanCodex.text(result) == "done"

      result = structured_result(%{"outcome" => "blocked"}, session_id: "thread-1")
      assert ObanCodex.outcome(result) == "blocked"
      assert ObanCodex.session_id(result) == "thread-1"
  """

  alias CodexWrapper.Result
  alias ObanCodex.Error

  @typedoc "A result struct or shorthand final-message string."
  @type respondable :: Result.t() | String.t()

  @typedoc "A normalized error struct or shorthand error kind."
  @type failable :: Error.t() | atom()

  @doc """
  Build a successful `%CodexWrapper.Result{}` with realistic JSONL stdout.

  A string is shorthand for the final agent message. Keyword options:

    * `:text` / `:result` — final agent message (`:result` is a parity alias)
    * `:session_id` — emitted as the `thread_id`
    * `:usage` — map emitted on `turn.completed`
    * `:stderr` — raw stderr
    * `:events` — additional raw event maps inserted before `turn.completed`
  """
  @spec result(String.t() | keyword()) :: Result.t()
  def result(text_or_opts \\ "")
  def result(text) when is_binary(text), do: result(text: text)

  def result(opts) when is_list(opts) do
    validate_keys!(opts, [:text, :result, :session_id, :usage, :stderr, :events], :result)

    text = Keyword.get(opts, :text, Keyword.get(opts, :result, ""))
    session_id = Keyword.get(opts, :session_id)
    usage = Keyword.get(opts, :usage, %{})
    additional = Keyword.get(opts, :events, [])

    events =
      []
      |> maybe_add_thread(session_id)
      |> Kernel.++([%{"type" => "turn.started"}])
      |> Kernel.++(additional)
      |> maybe_add_message(text)
      |> Kernel.++([%{"type" => "turn.completed", "usage" => usage}])

    %Result{
      stdout: Enum.map_join(events, "\n", &Jason.encode!/1),
      stderr: Keyword.get(opts, :stderr, ""),
      exit_code: 0,
      success: true
    }
  end

  @doc "Build a result from final-message text plus keyword options."
  @spec result(String.t(), keyword()) :: Result.t()
  def result(text, opts) when is_binary(text) and is_list(opts),
    do: result(Keyword.put(opts, :text, text))

  @doc "Build a successful result whose final message is JSON-encoded structured data."
  @spec structured_result(map() | list(), keyword()) :: Result.t()
  def structured_result(data, opts \\ [])
      when (is_map(data) or is_list(data)) and is_list(opts) do
    result(Keyword.put(opts, :text, Jason.encode!(data)))
  end

  @doc """
  Build a completed non-zero Codex result.

  This models CLI failures such as authentication or invalid config, which the
  wrapper returns as `%Result{success: false}` rather than `{:error, reason}`.
  """
  @spec failed_result(String.t(), keyword()) :: Result.t()
  def failed_result(output \\ "codex command failed", opts \\ []) when is_binary(output) do
    validate_keys!(opts, [:exit_code, :stderr], :failed_result)
    exit_code = Keyword.get(opts, :exit_code, 1)

    %Result{
      stdout: output,
      stderr: Keyword.get(opts, :stderr, ""),
      exit_code: exit_code,
      success: false
    }
  end

  @doc "Build a normalized pre-result execution error."
  @spec error(atom(), keyword()) :: Error.t()
  def error(kind, opts \\ []) when is_atom(kind) do
    validate_keys!(opts, [:reason, :message], :error)
    Error.new(kind, opts)
  end

  @doc "Return a query function that always succeeds."
  @spec respond(respondable()) :: ObanCodex.query_fun()
  def respond(response) do
    value = {:ok, to_result(response)}
    fn _prompt, _opts -> value end
  end

  @doc "Return a query function that always fails before producing a CLI result."
  @spec fail(failable()) :: ObanCodex.query_fun()
  def fail(error) do
    value = {:error, to_error(error)}
    fn _prompt, _opts -> value end
  end

  @doc """
  Return each scripted result/error in sequence, raising after exhaustion.

  Strings become successes, atoms become normalized errors, and prebuilt
  `%Result{}` / `%Error{}` structs retain their sense.
  """
  @spec sequence([respondable() | failable()]) :: ObanCodex.query_fun()
  def sequence(values) when is_list(values) do
    scripted = Enum.map(values, &coerce/1)
    {:ok, agent} = Agent.start_link(fn -> scripted end)
    count = length(values)

    fn _prompt, _opts ->
      case Agent.get_and_update(agent, &pop/1) do
        {:queued, value} ->
          value

        :exhausted ->
          raise "ObanCodex.Testing.sequence/1 exhausted: scripted #{count} response(s)"
      end
    end
  end

  defp maybe_add_thread(events, nil), do: events

  defp maybe_add_thread(events, session_id),
    do: events ++ [%{"type" => "thread.started", "thread_id" => session_id}]

  defp maybe_add_message(events, nil), do: events

  defp maybe_add_message(events, text) do
    events ++
      [
        %{
          "type" => "item.completed",
          "item" => %{"type" => "agent_message", "text" => text}
        }
      ]
  end

  defp pop([next | rest]), do: {{:queued, next}, rest}
  defp pop([]), do: {:exhausted, []}

  defp to_result(%Result{} = result), do: result
  defp to_result(text) when is_binary(text), do: result(text)

  defp to_error(%Error{} = error), do: error
  defp to_error(kind) when is_atom(kind), do: error(kind)

  defp coerce(%Result{} = result), do: {:ok, result}
  defp coerce(%Error{} = error), do: {:error, error}
  defp coerce(text) when is_binary(text), do: {:ok, result(text)}
  defp coerce(kind) when is_atom(kind), do: {:error, error(kind)}

  defp validate_keys!(opts, allowed, function) do
    case Keyword.keys(opts) -- allowed do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown option(s) for #{function}: #{inspect(Enum.uniq(unknown))}"
    end
  end
end
