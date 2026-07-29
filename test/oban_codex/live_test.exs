defmodule ObanCodex.LiveTest.EchoWorker do
  use ObanCodex.Worker,
    queue: :live_test,
    max_attempts: 1,
    args:
      ObanCodex.Args.defaults(
        sandbox: :read_only,
        approval_policy: :never,
        skip_git_repo_check: true,
        ephemeral: true,
        timeout: 120_000
      )

  @impl ObanCodex.Worker
  def handle_result(result, _job), do: {:cancel, {:handled, result.success}}
end

defmodule ObanCodex.LiveTest do
  use ExUnit.Case, async: false

  @moduletag :live
  @moduletag timeout: 180_000

  alias CodexWrapper.Result
  alias ObanCodex.LiveTest.EchoWorker

  test "run/2 maps a real Codex turn and extracts its JSONL helpers" do
    args =
      ObanCodex.Args.new(
        prompt: "Reply with exactly the word OK and nothing else.",
        sandbox: :read_only,
        approval_policy: :never,
        skip_git_repo_check: true,
        ephemeral: true,
        timeout: 120_000
      )

    assert {:ok, %Result{success: true} = result} = ObanCodex.run(args)
    assert is_binary(ObanCodex.text(result))
    assert ObanCodex.text(result) != ""
    assert is_binary(ObanCodex.session_id(result))
    assert is_map(ObanCodex.usage(result))
  end

  test "run/2 round-trips structured output from an output schema" do
    path =
      Path.join(
        System.tmp_dir!(),
        "oban_codex_live_schema_#{System.unique_integer([:positive])}.json"
      )

    schema = %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{"outcome" => %{"type" => "string", "enum" => ["done"]}},
      "required" => ["outcome"]
    }

    File.write!(path, Jason.encode!(schema))
    on_exit(fn -> File.rm(path) end)

    args =
      ObanCodex.Args.new(
        prompt: "Return outcome set to done.",
        sandbox: :read_only,
        approval_policy: :never,
        skip_git_repo_check: true,
        ephemeral: true,
        output_schema: path,
        timeout: 120_000
      )

    assert {:ok, %Result{success: true} = result} = ObanCodex.run(args)
    assert ObanCodex.structured(result) == %{"outcome" => "done"}
    assert ObanCodex.outcome(result) == "done"
  end

  test "worker perform/1 reaches handle_result/2 for a real turn" do
    job = %Oban.Job{args: %{"prompt" => "Reply with exactly the word OK."}}
    assert {:cancel, {:handled, true}} = EchoWorker.perform(job)
  end
end
