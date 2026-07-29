defmodule ObanCodex.CLI do
  @moduledoc false

  @enum_keys [:sandbox, :approval_policy, :search, :color]
  @control_keys [:json, :rest, :prompt]

  @sandboxes ~w(read_only workspace_write danger_full_access)
  @approval_policies ~w(untrusted on_request never)
  @search_modes ~w(cached indexed live disabled)
  @color_modes ~w(always never auto)

  @doc false
  defmacro codex_options do
    quote do
      argument(:prompt, type: :string, required: true, help: "The Codex prompt.")

      option(:model, type: :string, short: :m, help: "Model name.")
      option(:profile, type: :string, help: "Named Codex config profile.")
      option(:working_dir, type: :string, short: :w, help: "Codex working directory.")
      option(:binary, type: :string, help: "Path to the codex CLI binary.")
      option(:timeout, type: :integer, help: "Command timeout in milliseconds.")
      option(:verbose, type: :boolean, help: "Enable verbose CLI output.")

      option(:sandbox,
        type: :string,
        short: :s,
        choices: unquote(@sandboxes),
        help: "Sandbox mode."
      )

      option(:approval_policy,
        type: :string,
        short: :a,
        choices: unquote(@approval_policies),
        help: "Approval policy."
      )

      option(:full_auto, type: :boolean, help: "Use the workspace-write compatibility mode.")

      option(:dangerously_bypass_approvals_and_sandbox,
        type: :boolean,
        help: "Bypass approvals and sandboxing."
      )

      option(:dangerously_bypass_hook_trust,
        type: :boolean,
        help: "Run enabled hooks without persisted trust."
      )

      option(:skip_git_repo_check, type: :boolean, help: "Allow a non-git working directory.")
      option(:add_dir, type: :string, multi: true, help: "Additional directory (repeatable).")

      option(:search,
        type: :string,
        choices: unquote(@search_modes),
        help: "Web-search mode."
      )

      option(:ephemeral, type: :boolean, help: "Do not persist the Codex session.")
      option(:output_schema, type: :string, help: "Path to a JSON Schema file.")
      option(:output_last_message, type: :string, help: "Path for the final message.")
      option(:images, type: :string, multi: true, help: "Image path (repeatable).")
      option(:config_overrides, type: :string, multi: true, help: "key=value (repeatable).")
      option(:enabled_features, type: :string, multi: true, help: "Feature to enable.")
      option(:disabled_features, type: :string, multi: true, help: "Feature to disable.")
      option(:strict_config, type: :boolean, help: "Reject unrecognized config fields.")
      option(:ignore_user_config, type: :boolean, help: "Ignore user config.toml.")
      option(:ignore_rules, type: :boolean, help: "Ignore user and project policy rules.")

      option(:color,
        type: :string,
        choices: unquote(@color_modes),
        help: "Color mode for the initial turn."
      )

      option(:oss, type: :boolean, help: "Use an open-source provider.")
      option(:local_provider, type: :string, help: "Local provider name.")
      option(:session_id, type: :string, help: "Codex thread id to resume.")
      option(:resume, type: :string, help: "Alias for --session-id.")
    end
  end

  @doc false
  @spec to_args(map()) :: ObanCodex.Args.t()
  def to_args(parsed) do
    prompt = Map.get(parsed, :prompt)

    opts =
      parsed
      |> Map.drop(@control_keys)
      |> Enum.reject(fn {_key, value} -> value in [nil, []] end)
      |> Enum.map(&coerce/1)

    opts = if prompt, do: [{:prompt, prompt} | opts], else: opts

    ObanCodex.Args.new(opts)
  rescue
    error in [NimbleOptions.ValidationError, ArgumentError] ->
      Mix.raise(Exception.message(error))
  end

  defp coerce({key, value}) when key in @enum_keys and is_binary(value),
    do: {key, String.to_existing_atom(value)}

  defp coerce(pair), do: pair

  @doc false
  @spec emit({ObanCodex.oban_return(), term()}, boolean()) :: boolean()
  def emit(outcome, json?) do
    rendered = render(outcome, json?)
    ok? = success?(outcome)
    if json? or ok?, do: Mix.shell().info(rendered), else: Mix.shell().error(rendered)
    ok?
  end

  @doc false
  @spec success?({ObanCodex.oban_return(), term()}) :: boolean()
  def success?({:ok, _payload}), do: true
  def success?({{:ok, _}, _payload}), do: true
  def success?(_), do: false

  @doc false
  @spec render({ObanCodex.oban_return(), term()}, boolean()) :: String.t()
  def render({oban_return, %CodexWrapper.Result{} = result}, true) do
    oban_return
    |> verdict_json()
    |> Map.merge(%{
      text: ObanCodex.text(result),
      structured: ObanCodex.structured(result),
      session_id: ObanCodex.session_id(result),
      usage: ObanCodex.usage(result),
      exit_code: result.exit_code,
      success: result.success,
      stderr: blank_to_nil(result.stderr)
    })
    |> encode_json()
  end

  def render({oban_return, %ObanCodex.Error{} = error}, true) do
    oban_return
    |> verdict_json()
    |> Map.merge(%{
      error_kind: error.kind,
      error_reason: reason_string(error.reason),
      message: error.message
    })
    |> encode_json()
  end

  def render({oban_return, %CodexWrapper.Result{} = result}, false) do
    metadata =
      [
        exit: result.exit_code,
        session: ObanCodex.session_id(result),
        usage: ObanCodex.usage(result)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map_join("  ", fn {key, value} -> "#{key}=#{inspect(value)}" end)

    body = ObanCodex.text(result) || String.trim(result.stdout)

    "verdict: #{inspect(oban_return)}\n\n#{body}" <>
      if(metadata == "", do: "", else: "\n\n" <> metadata)
  end

  def render({oban_return, %ObanCodex.Error{} = error}, false) do
    "verdict: #{inspect(oban_return)}\nerror [#{error.kind}]: " <>
      (error.message || reason_string(error.reason))
  end

  def render({oban_return, payload}, true) do
    verdict_json(oban_return)
    |> Map.put(:payload, inspect(payload))
    |> encode_json()
  end

  def render({oban_return, payload}, false) do
    "verdict: #{inspect(oban_return)}\n#{inspect(payload)}"
  end

  defp verdict_json(:ok), do: %{verdict: "ok"}
  defp verdict_json({:ok, _}), do: %{verdict: "ok"}
  defp verdict_json({:error, reason}), do: %{verdict: "error", reason: reason_string(reason)}
  defp verdict_json({:cancel, reason}), do: %{verdict: "cancel", reason: reason_string(reason)}
  defp verdict_json({:snooze, value}), do: %{verdict: "snooze", snooze: inspect(value)}

  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string(reason), do: inspect(reason)

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  @doc false
  @spec encode_json(term()) :: String.t()
  def encode_json(term), do: Jason.encode!(term)
end
