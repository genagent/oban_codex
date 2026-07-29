defmodule ObanCodex.CLITest do
  use ExUnit.Case, async: true

  alias ObanCodex.CLI
  alias ObanCodex.CLI.Doctor

  test "to_args/1 validates and serializes Codex flags" do
    args =
      CLI.to_args(%{
        prompt: "review",
        model: "gpt-5",
        sandbox: "read_only",
        approval_policy: "never",
        search: "cached",
        color: "never",
        add_dir: ["/a", "/b"],
        images: ["one.png"],
        json: true,
        rest: []
      })

    assert args == %{
             "prompt" => "review",
             "model" => "gpt-5",
             "sandbox" => "read_only",
             "approval_policy" => "never",
             "search" => "cached",
             "color" => "never",
             "add_dir" => ["/a", "/b"],
             "images" => ["one.png"]
           }
  end

  test "to_args rejects incompatible session flags as a clean Mix error" do
    assert_raise Mix.Error, ~r/only one/, fn ->
      CLI.to_args(%{prompt: "x", session_id: "one", resume: "two"})
    end
  end

  test "renders a successful result as text" do
    result =
      ObanCodex.Testing.result("done",
        session_id: "thread-1",
        usage: %{"output_tokens" => 3}
      )

    text = CLI.render({:ok, result}, false)
    assert text =~ "verdict: :ok"
    assert text =~ "done"
    assert text =~ "thread-1"
    assert text =~ "output_tokens"
  end

  test "renders results as machine-readable JSON" do
    result =
      ObanCodex.Testing.structured_result(%{"outcome" => "done"},
        session_id: "thread-2"
      )

    decoded = CLI.render({:ok, result}, true) |> Jason.decode!()

    assert decoded["verdict"] == "ok"
    assert decoded["success"] == true
    assert decoded["exit_code"] == 0
    assert decoded["session_id"] == "thread-2"
    assert decoded["structured"] == %{"outcome" => "done"}
  end

  test "renders normalized errors in text and JSON" do
    error = ObanCodex.Testing.error(:timeout, reason: {:timeout, 1_000}, message: "timed out")

    assert CLI.render({{:error, :timeout}, error}, false) =~ "error [timeout]: timed out"

    decoded = CLI.render({{:error, :timeout}, error}, true) |> Jason.decode!()
    assert decoded["verdict"] == "error"
    assert decoded["error_kind"] == "timeout"
    assert decoded["message"] == "timed out"
  end

  test "renders non-zero results without treating them as normalized errors" do
    result = ObanCodex.Testing.failed_result("login required", exit_code: 1)
    decoded = CLI.render({{:error, {:command_failed, 1}}, result}, true) |> Jason.decode!()

    assert decoded["verdict"] == "error"
    assert decoded["success"] == false
    assert decoded["exit_code"] == 1
    assert decoded["text"] == "login required"
  end

  test "success?/1 follows the Oban verdict" do
    result = ObanCodex.Testing.result("done")
    assert CLI.success?({:ok, result})
    assert CLI.success?({{:ok, :value}, result})
    refute CLI.success?({{:error, :retry}, result})
    refute CLI.success?({{:cancel, :done}, result})
  end

  test "doctor report accounts for the JSON overall status" do
    checks = [
      {"version", {:ok, %{version: "codex 0.145.0"}}},
      {"authentication", {:ok, "Logged in"}},
      {"doctor", {:ok, %{"overallStatus" => "ok"}}}
    ]

    assert {report, true} = Doctor.report(checks)
    assert report =~ "Codex environment OK"

    warning = List.replace_at(checks, 2, {"doctor", {:ok, %{"overallStatus" => "warning"}}})
    assert {_report, true} = Doctor.report(warning)

    failed = List.replace_at(checks, 2, {"doctor", {:ok, %{"overallStatus" => "error"}}})
    assert {_report, false} = Doctor.report(failed)
  end

  test "doctor JSON report is valid" do
    output =
      Doctor.json_report(
        [{"version", {:ok, %{version: "codex 1"}}}, {"auth", {:error, :missing}}],
        false
      )
      |> Jason.decode!()

    assert output["ok"] == false
    assert Enum.map(output["checks"], & &1["status"]) == ["ok", "error"]
  end
end
