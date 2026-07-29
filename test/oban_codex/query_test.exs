defmodule ObanCodex.QueryTest do
  use ExUnit.Case, async: false

  alias ObanCodex.Query

  defmodule Runner do
    @behaviour CodexWrapper.Runner

    @impl true
    def run(binary, args, opts, timeout) do
      send(Application.fetch_env!(:oban_codex, :query_test_pid), {
        :runner,
        binary,
        args,
        opts,
        timeout
      })

      case Application.get_env(:oban_codex, :query_test_result, :ok) do
        :ok ->
          stdout =
            [
              %{"type" => "thread.started", "thread_id" => "thread-1"},
              %{
                "type" => "item.completed",
                "item" => %{"type" => "agent_message", "text" => "done"}
              },
              %{"type" => "turn.completed", "usage" => %{}}
            ]
            |> Enum.map_join("\n", &Jason.encode!/1)

          {:ok, {stdout, 0}}

        {:exit, code, output} ->
          {:ok, {output, code}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def effective_timeout(nil), do: 60_000
    def effective_timeout(timeout), do: timeout
  end

  setup do
    previous_runner = Application.get_env(:codex_wrapper, :runner)
    Application.put_env(:codex_wrapper, :runner, Runner)
    Application.put_env(:oban_codex, :query_test_pid, self())
    Application.put_env(:oban_codex, :query_test_result, :ok)

    on_exit(fn ->
      if previous_runner do
        Application.put_env(:codex_wrapper, :runner, previous_runner)
      else
        Application.delete_env(:codex_wrapper, :runner)
      end

      Application.delete_env(:oban_codex, :query_test_pid)
      Application.delete_env(:oban_codex, :query_test_result)
    end)

    :ok
  end

  test "fresh turns map curated options onto Exec and force JSONL" do
    assert {:ok, result} =
             Query.run("prompt",
               binary: "codex-test",
               working_dir: "/repo",
               timeout: 12_000,
               model: "gpt-5",
               profile: "batch",
               sandbox: :read_only,
               approval_policy: :never,
               add_dir: ["/a", "/b"],
               search: :live,
               output_schema: "/repo/schema.json",
               images: ["one.png"],
               config_overrides: ["x=1"],
               enabled_features: ["alpha"],
               disabled_features: ["beta"],
               strict_config: true,
               ignore_user_config: true,
               ignore_rules: true,
               color: :never
             )

    assert ObanCodex.text(result) == "done"
    assert ObanCodex.session_id(result) == "thread-1"

    assert_received {:runner, "codex-test", args, opts, 12_000}
    assert Keyword.get(opts, :cd) == "/repo"
    assert Enum.take(args, 1) == ["exec"]
    assert "--json" in args
    assert "--output-schema" in args
    assert "/repo/schema.json" in args
    assert "--profile" in args
    assert "--add-dir" in args
    assert "one.png" in args
    assert List.last(args) == "prompt"
  end

  test "resumed turns preserve common policy and structured-output options" do
    assert {:ok, _result} =
             Query.run("continue",
               binary: "codex-test",
               working_dir: "/repo",
               session_id: "thread-9",
               model: "gpt-5",
               sandbox: :workspace_write,
               approval_policy: :on_request,
               search: :disabled,
               config_overrides: [
                 ~s(approval_policy="untrusted"),
                 ~s(web_search="live")
               ],
               output_schema: "/repo/schema.json",
               profile: "initial-only",
               add_dir: "/initial-only",
               images: ["context.png"],
               ignore_user_config: true
             )

    assert_received {:runner, "codex-test", args, opts, nil}
    assert Keyword.get(opts, :cd) == "/repo"
    assert Enum.take(args, 2) == ["exec", "resume"]
    assert "--json" in args
    assert "--output-schema" in args
    assert "/repo/schema.json" in args
    assert "thread-9" in args
    assert List.last(args) == "continue"
    refute "--profile" in args
    refute "--add-dir" in args

    schema_index = Enum.find_index(args, &(&1 == "--output-schema"))
    session_index = Enum.find_index(args, &(&1 == "thread-9"))
    assert schema_index < session_index

    assert ~s(approval_policy="on-request") in args
    assert ~s(web_search="disabled") in args
    assert ~s(sandbox_mode="workspace-write") in args

    user_approval = Enum.find_index(args, &(&1 == ~s(approval_policy="untrusted")))
    derived_approval = Enum.find_index(args, &(&1 == ~s(approval_policy="on-request")))
    user_search = Enum.find_index(args, &(&1 == ~s(web_search="live")))
    derived_search = Enum.find_index(args, &(&1 == ~s(web_search="disabled")))

    assert user_approval < derived_approval
    assert user_search < derived_search
  end

  test "normalizes runner timeouts" do
    Application.put_env(:oban_codex, :query_test_result, {:error, :timeout})

    assert {:error,
            %ObanCodex.Error{
              kind: :timeout,
              reason: {:timeout, 5_000}
            }} = Query.run("x", binary: "codex-test", timeout: 5_000)
  end

  test "retains non-zero exits as results for the outcome classifier" do
    Application.put_env(:oban_codex, :query_test_result, {:exit, 4, "bad config"})

    assert {:ok, %CodexWrapper.Result{success: false, exit_code: 4, stdout: "bad config"}} =
             Query.run("x", binary: "codex-test")
  end
end
