defmodule ObanCodex.ArgsTest do
  use ExUnit.Case, async: true

  alias ObanCodex.Args

  test "new/1 builds the minimal stored map" do
    assert Args.new(prompt: "hello") == %{"prompt" => "hello"}
  end

  test "defaults/1 makes prompt optional" do
    assert Args.defaults(model: "gpt-5", sandbox: :read_only) ==
             %{"model" => "gpt-5", "sandbox" => "read_only"}
  end

  test "serializes the complete curated option vocabulary" do
    args =
      Args.new(
        prompt: "work",
        model: "gpt-5",
        profile: "batch",
        working_dir: "/repo",
        binary: "/opt/codex",
        timeout: 30_000,
        verbose: true,
        sandbox: :workspace_write,
        approval_policy: :never,
        full_auto: false,
        dangerously_bypass_approvals_and_sandbox: false,
        dangerously_bypass_hook_trust: true,
        skip_git_repo_check: true,
        add_dir: ["/a", "/b"],
        search: :cached,
        ephemeral: false,
        output_schema: "/repo/schema.json",
        output_last_message: "/tmp/final.txt",
        images: ["a.png"],
        config_overrides: [~s(model_reasoning_effort="high")],
        enabled_features: ["one"],
        disabled_features: ["two"],
        strict_config: true,
        ignore_user_config: true,
        ignore_rules: true,
        color: :never,
        oss: true,
        local_provider: "ollama",
        meta: %{"trace" => "abc", issue: 42}
      )

    assert args["sandbox"] == "workspace_write"
    assert args["approval_policy"] == "never"
    assert args["search"] == "cached"
    assert args["color"] == "never"
    assert args["add_dir"] == ["/a", "/b"]
    assert args["issue"] == 42
    assert args["trace"] == "abc"

    expected =
      Args.keys()
      |> Enum.reject(&(&1 in [:meta, :session_id, :resume]))
      |> Enum.map(&Atom.to_string/1)
      |> MapSet.new()

    assert MapSet.subset?(expected, Map.keys(args) |> MapSet.new())
  end

  test "accepts a single add_dir and explicit session aliases" do
    assert Args.new(prompt: "x", add_dir: "/extra")["add_dir"] == "/extra"
    assert Args.new(prompt: "x", session_id: "thread")["session_id"] == "thread"
    assert Args.new(prompt: "x", resume: "thread")["resume"] == "thread"
  end

  test "requires prompt for jobs and validates enum vocabularies" do
    assert_raise NimbleOptions.ValidationError, fn -> Args.new(model: "gpt-5") end

    assert_raise NimbleOptions.ValidationError, fn ->
      Args.new(prompt: "x", sandbox: :unrestricted)
    end

    assert_raise NimbleOptions.ValidationError, fn ->
      Args.new(prompt: "x", approval_policy: :on_failure)
    end

    assert_raise NimbleOptions.ValidationError, fn ->
      Args.new(prompt: "x", search: true)
    end
  end

  test "rejects unknown options and invalid types" do
    assert_raise NimbleOptions.ValidationError, fn ->
      Args.new(prompt: "x", system_prompt: "Claude-only")
    end

    assert_raise NimbleOptions.ValidationError, fn ->
      Args.new(prompt: "x", timeout: 0)
    end

    assert_raise NimbleOptions.ValidationError, fn ->
      Args.new(prompt: "x", images: "image.png")
    end
  end

  test "rejects incompatible session combinations" do
    assert_raise ArgumentError, ~r/only one/, fn ->
      Args.new(prompt: "x", session_id: "a", resume: "b")
    end

    assert_raise ArgumentError, ~r/cannot be resumed/, fn ->
      Args.new(prompt: "x", session_id: "a", ephemeral: true)
    end
  end

  test "rejects a feature in both enable and disable lists" do
    assert_raise ArgumentError, ~r/both enabled and disabled/, fn ->
      Args.new(prompt: "x", enabled_features: ["shell"], disabled_features: ["shell"])
    end
  end

  test "meta keys are stringified and values must be JSON safe" do
    assert Args.new(prompt: "x", meta: %{issue: 12})["issue"] == 12

    assert_raise ArgumentError, ~r/collides/, fn ->
      Args.new(prompt: "x", meta: %{model: "smuggled"})
    end

    assert_raise ArgumentError, ~r/not JSON-encodable/, fn ->
      Args.new(prompt: "x", meta: %{bad: {:tuple, 1}})
    end
  end

  test "env is deliberately absent from persisted args" do
    refute :env in Args.keys()

    assert_raise NimbleOptions.ValidationError, fn ->
      Args.new(prompt: "x", env: [{"SECRET", "value"}])
    end
  end

  test "every built Codex option reaches the run query seam" do
    args =
      Args.new(
        prompt: "x",
        model: "gpt-5",
        sandbox: :read_only,
        approval_policy: :never,
        search: :disabled,
        color: :auto,
        images: ["one.png"],
        config_overrides: ["x=1"],
        enabled_features: ["a"],
        disabled_features: ["b"],
        meta: %{trace: "not-forwarded"}
      )

    parent = self()

    query = fn _prompt, opts ->
      send(parent, {:query_opts, opts})
      {:ok, ObanCodex.Testing.result("done")}
    end

    assert {:ok, _} = ObanCodex.run(args, query_fun: query)
    assert_received {:query_opts, opts}

    assert Keyword.keys(opts) |> Enum.sort() ==
             [
               :approval_policy,
               :color,
               :config_overrides,
               :disabled_features,
               :enabled_features,
               :images,
               :model,
               :sandbox,
               :search
             ]

    refute Keyword.has_key?(opts, :trace)
  end
end
