defmodule ObanCodex.TestingTest do
  use ExUnit.Case, async: true

  import ObanCodex.Testing

  alias CodexWrapper.Result
  alias ObanCodex.Error

  test "result/1 builds production-shaped JSONL" do
    result = result(text: "done", session_id: "thread-1", usage: %{"output_tokens" => 2})

    assert %Result{success: true, exit_code: 0, stderr: ""} = result
    assert ObanCodex.text(result) == "done"
    assert ObanCodex.session_id(result) == "thread-1"
    assert ObanCodex.usage(result) == %{"output_tokens" => 2}
  end

  test "result accepts the oban_claude-compatible :result option alias" do
    assert "done" == result(result: "done") |> ObanCodex.text()
  end

  test "structured_result round trips objects and arrays" do
    assert %{"outcome" => "blocked"} ==
             structured_result(%{"outcome" => "blocked"}) |> ObanCodex.structured()

    assert [1, 2] == structured_result([1, 2]) |> ObanCodex.structured()
  end

  test "failed_result represents a completed non-zero command" do
    result = failed_result("bad config", exit_code: 2)
    assert %Result{success: false, exit_code: 2, stdout: "bad config"} = result
  end

  test "error builds a normalized execution error" do
    assert %Error{kind: :timeout, reason: :idle} = error(:timeout, reason: :idle)
  end

  test "builders reject fields that don't exist in the Codex result contract" do
    assert_raise ArgumentError, ~r/unknown option/, fn -> result(cost_usd: 0.1) end
    assert_raise ArgumentError, ~r/unknown option/, fn -> error(:timeout, exit_code: 1) end
  end

  test "respond and fail return query functions" do
    assert {:ok, result} = respond("done").("prompt", [])
    assert ObanCodex.text(result) == "done"

    assert {:error, %Error{kind: :timeout}} = fail(:timeout).("prompt", [])
  end

  test "sequence scripts mixed outcomes and raises after exhaustion" do
    query = sequence(["first", error(:timeout), structured_result(%{"n" => 3})])

    assert {:ok, first} = query.("x", [])
    assert ObanCodex.text(first) == "first"
    assert {:error, %Error{kind: :timeout}} = query.("x", [])
    assert {:ok, third} = query.("x", [])
    assert ObanCodex.structured(third) == %{"n" => 3}

    assert_raise RuntimeError, ~r/exhausted/, fn -> query.("x", []) end
  end
end
