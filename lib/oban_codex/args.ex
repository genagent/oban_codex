defmodule ObanCodex.Args do
  @schema [
    prompt: [
      type: :string,
      required: true,
      doc: "The Codex prompt. The only required option for `new/1`."
    ],
    model: [type: :string, doc: "Model name understood by the installed Codex CLI."],
    profile: [type: :string, doc: "Named Codex config profile for the initial turn."],
    working_dir: [type: :string, doc: "Working directory for the Codex subprocess."],
    binary: [
      type: :string,
      doc:
        "Path to the `codex` binary. Pin this in worker defaults when a PATH " <>
          "upgrade during a batch would be unsafe."
    ],
    timeout: [type: :pos_integer, doc: "Whole command timeout in milliseconds."],
    verbose: [type: :boolean, doc: "Enable verbose Codex CLI output."],
    sandbox: [
      type: {:in, [:read_only, :workspace_write, :danger_full_access]},
      doc: "Codex sandbox mode."
    ],
    approval_policy: [
      type: {:in, [:untrusted, :on_request, :never]},
      doc: "Codex approval policy."
    ],
    full_auto: [
      type: :boolean,
      doc:
        "Compatibility shorthand for `sandbox: :workspace_write`; an explicit " <>
          "`:sandbox` wins."
    ],
    dangerously_bypass_approvals_and_sandbox: [
      type: :boolean,
      doc:
        "Bypass approvals and sandboxing. Only use inside a separately secured " <>
          "execution environment."
    ],
    dangerously_bypass_hook_trust: [
      type: :boolean,
      doc:
        "Run repository hooks without persisted trust. Only use when hook sources " <>
          "are already vetted."
    ],
    skip_git_repo_check: [
      type: :boolean,
      doc: "Allow Codex to run outside a git repository."
    ],
    add_dir: [
      type: {:or, [:string, {:list, :string}]},
      doc: "Additional readable directory or directories for an initial turn."
    ],
    search: [
      type: {:in, [:cached, :indexed, :live, :disabled]},
      doc: "Web-search mode."
    ],
    ephemeral: [
      type: :boolean,
      doc:
        "Do not persist the session. This is suitable for one-shot jobs and is " <>
          "incompatible with `:session_id`/`:resume`."
    ],
    output_schema: [
      type: :string,
      doc:
        "Path to a JSON Schema file for the final message. Unlike Claude's inline " <>
          "`json_schema`, Codex expects a file path. It is reapplied on resumed turns."
    ],
    output_last_message: [
      type: :string,
      doc: "Path where Codex writes the final agent message."
    ],
    images: [
      type: {:list, :string},
      doc: "Image paths attached to the prompt."
    ],
    config_overrides: [
      type: {:list, :string},
      doc: "Repeatable Codex `key=value` config overrides."
    ],
    enabled_features: [
      type: {:list, :string},
      doc: "Feature names enabled for this invocation."
    ],
    disabled_features: [
      type: {:list, :string},
      doc: "Feature names disabled for this invocation."
    ],
    strict_config: [
      type: :boolean,
      doc: "Fail when config contains fields the installed Codex doesn't recognize."
    ],
    ignore_user_config: [
      type: :boolean,
      doc: "Do not load the user's `config.toml` (authentication still resolves normally)."
    ],
    ignore_rules: [
      type: :boolean,
      doc: "Do not load user or project execpolicy `.rules` files."
    ],
    color: [
      type: {:in, [:always, :never, :auto]},
      doc: "Color mode for the initial turn."
    ],
    oss: [type: :boolean, doc: "Use an open-source provider for the initial turn."],
    local_provider: [
      type: :string,
      doc: "Local provider name, typically `\"ollama\"` or `\"lmstudio\"`."
    ],
    session_id: [
      type: :string,
      doc:
        "Explicit Codex thread id to resume. Obtain it with " <>
          "`ObanCodex.session_id/1` from a prior result."
    ],
    resume: [
      type: :string,
      doc:
        "Alias for `:session_id`, retained to keep lifecycle code and migration " <>
          "patterns aligned with `oban_claude`. Do not set both."
    ],
    meta: [
      type: {:map, {:or, [:atom, :string]}, :any},
      doc:
        "Application metadata merged flat into the stored args (keys stringified). " <>
          "It is not forwarded to Codex."
    ]
  ]

  @options_schema NimbleOptions.new!(@schema)
  @codex_option_keys @schema |> Keyword.delete(:meta) |> Keyword.keys() |> Enum.map(&to_string/1)

  @defaults_schema @schema
                   |> Keyword.update!(:prompt, &Keyword.delete(&1, :required))
                   |> NimbleOptions.new!()

  @moduledoc """
  Build a Codex job's string-keyed, JSON-safe Oban args.

  `new/1` accepts atom-keyed native Elixir options, validates them, and returns
  the map Oban stores:

      ObanCodex.Args.new(
        prompt: "review the repository",
        working_dir: "/repo",
        sandbox: :read_only,
        approval_policy: :never
      )

      #=> %{
      #     "prompt" => "review the repository",
      #     "working_dir" => "/repo",
      #     "sandbox" => "read_only",
      #     "approval_policy" => "never"
      #   }

  `defaults/1` has the same schema with `:prompt` optional, making it suitable
  for worker-level defaults:

      use ObanCodex.Worker,
        queue: :codex,
        args: ObanCodex.Args.defaults(
          working_dir: "/repo",
          sandbox: :read_only,
          approval_policy: :never
        )

  `:meta` carries application values such as an issue number or correlation id.
  It is flattened into the map because Oban jobs already expose their args to
  callbacks and telemetry. Meta keys may not collide with a Codex option and
  every value must be JSON-encodable.

  ## Options

  #{NimbleOptions.docs(@options_schema)}
  """

  @typedoc "The string-keyed map accepted by `ObanCodex.run/2` and stored by Oban."
  @type t :: %{optional(String.t()) => term()}

  @doc "Validate and build one job's args."
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    opts
    |> NimbleOptions.validate!(@options_schema)
    |> validate_combinations!()
    |> to_map()
  end

  @doc "Build prompt-optional worker defaults."
  @spec defaults(keyword()) :: t()
  def defaults(opts \\ []) when is_list(opts) do
    opts
    |> NimbleOptions.validate!(@defaults_schema)
    |> validate_combinations!()
    |> to_map()
  end

  @doc "The atom-keyed options accepted by the builders."
  @spec keys() :: [atom()]
  def keys, do: Keyword.keys(@schema)

  defp validate_combinations!(opts) do
    if opts[:session_id] && opts[:resume] do
      raise ArgumentError, "set only one of :session_id or :resume"
    end

    if opts[:ephemeral] && (opts[:session_id] || opts[:resume]) do
      raise ArgumentError, ":ephemeral sessions cannot be resumed"
    end

    overlap =
      opts
      |> Keyword.get(:enabled_features, [])
      |> MapSet.new()
      |> MapSet.intersection(MapSet.new(Keyword.get(opts, :disabled_features, [])))
      |> MapSet.to_list()

    if overlap != [] do
      raise ArgumentError,
            "features cannot be both enabled and disabled: #{inspect(Enum.sort(overlap))}"
    end

    opts
  end

  defp to_map(opts) do
    {meta, opts} = Keyword.pop(opts, :meta, %{})
    codex = Map.new(opts, fn {key, value} -> {Atom.to_string(key), serialize(value)} end)
    meta = meta |> stringify_keys() |> validate_meta!()
    Map.merge(meta, codex)
  end

  defp validate_meta!(meta) do
    for {key, _value} <- meta, key in @codex_option_keys do
      raise ArgumentError,
            "meta key #{inspect(key)} collides with the Codex option of the same name"
    end

    for {key, value} <- meta, not json_clean?(value) do
      raise ArgumentError,
            "meta value for #{inspect(key)} is not JSON-encodable (#{inspect(value)})"
    end

    meta
  end

  defp json_clean?(value) do
    match?({:ok, _}, Jason.encode(value))
  rescue
    Protocol.UndefinedError -> false
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp serialize(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp serialize(value), do: value
end
