defmodule ObanCodexTest do
  use ExUnit.Case, async: true

  import ObanCodex.Testing

  alias CodexWrapper.Result
  alias ObanCodex.Error

  describe "default outcome classification" do
    test "successful results pass through" do
      result = result("done")
      assert ObanCodex.Outcome.classify({:ok, result}) == {:ok, result}
    end

    test "ordinary non-zero exits retry with the exit code" do
      result = failed_result("provider unavailable", exit_code: 9)

      assert ObanCodex.Outcome.classify({:ok, result}) ==
               {{:error, {:command_failed, 9}}, result}
    end

    test "shell command-unavailable exits cancel" do
      for code <- [126, 127] do
        result = failed_result("not executable", exit_code: code)

        assert ObanCodex.Outcome.classify({:ok, result}) ==
                 {{:cancel, :command_unavailable}, result}
      end
    end

    test "timeouts retry and deterministic normalized faults cancel" do
      timeout = error(:timeout)
      auth = error(:auth)

      assert ObanCodex.Outcome.classify({:error, timeout}) == {{:error, :timeout}, timeout}
      assert ObanCodex.Outcome.classify({:error, auth}) == {{:cancel, :auth}, auth}
    end

    test "unknown normalized failures retry, raw off-contract failures cancel" do
      error = error(:transport)

      assert ObanCodex.Outcome.classify({:error, error}) == {{:error, :transport}, error}
      assert ObanCodex.Outcome.classify({:error, :odd}) == {{:cancel, :odd}, :odd}
    end
  end

  describe "run/2" do
    test "builds query options and coerces stored enum strings" do
      parent = self()

      query = fn prompt, opts ->
        send(parent, {:query, prompt, opts})
        {:ok, result("done")}
      end

      args = %{
        "prompt" => "review",
        "model" => "gpt-5",
        "sandbox" => "read_only",
        "approval_policy" => "on_request",
        "search" => "live",
        "color" => "never",
        "add_dir" => ["/a", "/b"],
        "ignored_meta" => 42
      }

      assert {:ok, %Result{success: true}} = ObanCodex.run(args, query_fun: query)

      assert_received {:query, "review", opts}
      assert opts[:model] == "gpt-5"
      assert opts[:sandbox] == :read_only
      assert opts[:approval_policy] == :on_request
      assert opts[:search] == :live
      assert opts[:color] == :never
      assert opts[:add_dir] == ["/a", "/b"]
      refute Keyword.has_key?(opts, :ignored_meta)
    end

    test "resume is a compatibility alias for session_id" do
      parent = self()

      query = fn _prompt, opts ->
        send(parent, {:opts, opts})
        {:ok, result("continued")}
      end

      assert {:ok, _} =
               ObanCodex.run(%{"prompt" => "continue", "resume" => "thread-1"},
                 query_fun: query
               )

      assert_received {:opts, opts}
      assert opts[:session_id] == "thread-1"
    end

    test "requires a prompt and rejects incompatible session flags" do
      assert_raise KeyError, fn -> ObanCodex.run(%{}, query_fun: respond("unused")) end

      assert_raise ArgumentError, ~r/only one/, fn ->
        ObanCodex.run(
          %{"prompt" => "x", "resume" => "a", "session_id" => "b"},
          query_fun: respond("unused")
        )
      end

      assert_raise ArgumentError, ~r/cannot be resumed/, fn ->
        ObanCodex.run(
          %{"prompt" => "x", "session_id" => "a", "ephemeral" => true},
          query_fun: respond("unused")
        )
      end
    end

    test "rejects malformed classifier envelopes" do
      assert_raise ArgumentError, ~r/required \{oban_return, payload\}/, fn ->
        ObanCodex.run(%{"prompt" => "x"},
          query_fun: respond("done"),
          classifier: fn _ -> {:cancel, :flat} end
        )
      end
    end

    test "accepts the complete Oban return vocabulary from a classifier" do
      for verdict <- [
            :ok,
            {:ok, :value},
            {:error, :retry},
            {:cancel, :done},
            {:snooze, 5},
            {:snooze, {2, :minutes}}
          ] do
        result = result("done")

        assert {^verdict, ^result} =
                 ObanCodex.run(%{"prompt" => "x"},
                   query_fun: respond(result),
                   classifier: fn _ -> {verdict, result} end
                 )
      end
    end
  end

  describe "result helpers" do
    test "read JSONL text, structured data, outcome, thread id, and usage" do
      result =
        structured_result(
          %{"outcome" => "done", "files" => ["a.ex"]},
          session_id: "thread-7",
          usage: %{"input_tokens" => 10, "output_tokens" => 4}
        )

      assert length(ObanCodex.events(result)) == 4
      assert Jason.decode!(ObanCodex.text(result))["outcome"] == "done"
      assert ObanCodex.structured(result) == %{"outcome" => "done", "files" => ["a.ex"]}
      assert ObanCodex.outcome(result) == "done"
      assert ObanCodex.session_id(result) == "thread-7"
      assert ObanCodex.usage(result) == %{"input_tokens" => 10, "output_tokens" => 4}
      assert ObanCodex.cost_usd(result) == nil
    end

    test "uses the last agent message and final usage event" do
      earlier = %{
        "type" => "item.completed",
        "item" => %{"type" => "agent_message", "text" => "first"}
      }

      result =
        result(
          text: "last",
          events: [
            earlier,
            %{"type" => "turn.completed", "usage" => %{"output_tokens" => 1}}
          ],
          usage: %{"output_tokens" => 2}
        )

      assert ObanCodex.text(result) == "last"
      assert ObanCodex.usage(result) == %{"output_tokens" => 2}
    end

    test "plain stdout is a compatibility fallback" do
      result = %Result{stdout: " plain output \n", stderr: "", exit_code: 0, success: true}
      assert ObanCodex.events(result) == []
      assert ObanCodex.text(result) == "plain output"
      assert ObanCodex.structured(result) == nil
      assert ObanCodex.session_id(result) == nil
      assert ObanCodex.usage(result) == nil
    end

    test "structured rejects scalar and malformed JSON" do
      assert ObanCodex.structured(result("true")) == nil
      assert ObanCodex.structured(result("{nope")) == nil
    end

    test "custom error reason maps retain parity readers" do
      error = %Error{kind: :budget, reason: %{session_id: "thread-9", cost_usd: 1.25}}
      assert ObanCodex.session_id(error) == "thread-9"
      assert ObanCodex.cost_usd(error) == 1.25
    end
  end

  describe "telemetry" do
    setup do
      id = "oban-codex-test-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach_many(
        id,
        [
          [:oban_codex, :run, :start],
          [:oban_codex, :run, :stop],
          [:oban_codex, :run, :exception]
        ],
        fn name, measurements, metadata, _ ->
          send(parent, {:telemetry, name, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)
      :ok
    end

    test "emits start and stop for a completed CLI result" do
      args = %{"prompt" => "x"}
      result = result("done")

      assert {:ok, ^result} = ObanCodex.run(args, query_fun: respond(result))

      assert_received {:telemetry, [:oban_codex, :run, :start], %{system_time: _},
                       %{args: ^args, job: nil}}

      assert_received {:telemetry, [:oban_codex, :run, :stop],
                       %{duration: duration, cost_usd: +0.0},
                       %{args: ^args, result: ^result, job: nil}}

      assert duration >= 0
    end

    test "emits exception for a pre-result error and includes slim job metadata" do
      job = %Oban.Job{
        id: 7,
        queue: "codex",
        worker: "Worker",
        attempt: 2,
        max_attempts: 3,
        meta: %{"trace" => "t"}
      }

      error = error(:timeout, reason: {:timeout, 1_000})

      assert {{:error, :timeout}, ^error} =
               ObanCodex.run(%{"prompt" => "x"}, query_fun: fail(error), job: job)

      assert_received {:telemetry, [:oban_codex, :run, :exception],
                       %{duration: _, cost_usd: +0.0}, %{error: ^error, job: metadata}}

      assert metadata ==
               Map.take(job, [:id, :queue, :worker, :attempt, :max_attempts, :meta])
    end
  end
end
