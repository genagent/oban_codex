defmodule ObanCodex.WorkerTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.Result
  alias ObanCodex.Error

  def query_ok(_prompt, _opts), do: {:ok, ObanCodex.Testing.result("done")}

  def query_blocked(_prompt, _opts),
    do: {:ok, ObanCodex.Testing.structured_result(%{"outcome" => "blocked"})}

  def query_auth(_prompt, _opts), do: {:error, ObanCodex.Testing.error(:auth)}

  def query_with_session(_prompt, _opts),
    do: {:ok, ObanCodex.Testing.result("done", session_id: "thread-9")}

  def echo(prompt, opts) do
    {:ok, ObanCodex.Testing.result(inspect({prompt, Enum.sort(opts)}))}
  end

  defmodule DefaultWorker do
    use ObanCodex.Worker, queue: :test, query_fun: &ObanCodex.WorkerTest.query_ok/2
  end

  defmodule BlockingWorker do
    use ObanCodex.Worker, queue: :test, query_fun: &ObanCodex.WorkerTest.query_blocked/2

    @impl ObanCodex.Worker
    def handle_result(result, _job) do
      if ObanCodex.outcome(result) == "blocked", do: {:cancel, :blocked}, else: :ok
    end
  end

  defmodule AuthWorker do
    use ObanCodex.Worker, queue: :test, query_fun: &ObanCodex.WorkerTest.query_auth/2
  end

  defmodule MergeWorker do
    use ObanCodex.Worker,
      queue: :test,
      query_fun: &ObanCodex.WorkerTest.echo/2,
      args: %{"model" => "default", "sandbox" => "read_only"}

    @impl ObanCodex.Worker
    def handle_result(result, _job), do: {:ok, ObanCodex.text(result)}
  end

  defmodule RoutineWorker do
    use ObanCodex.Worker,
      queue: :test,
      query_fun: &ObanCodex.WorkerTest.echo/2,
      args: %{"prompt" => "standing task", "model" => "gpt-5"}

    @impl ObanCodex.Worker
    def handle_result(result, _job), do: {:ok, ObanCodex.text(result)}
  end

  defmodule PinnedWorker do
    use ObanCodex.Worker,
      queue: :test,
      query_fun: &ObanCodex.WorkerTest.echo/2,
      args: ObanCodex.Args.defaults(model: "default"),
      pinned_args: ObanCodex.Args.defaults(sandbox: :read_only, approval_policy: :never)

    @impl ObanCodex.Worker
    def handle_result(result, _job), do: {:ok, ObanCodex.text(result)}
  end

  defmodule ClassifierWorker do
    use ObanCodex.Worker,
      queue: :test,
      query_fun: &ObanCodex.WorkerTest.query_ok/2,
      classifier: &__MODULE__.classify/1

    def classify({:ok, %Result{} = result}), do: {{:cancel, :always}, result}
  end

  defmodule ErrorHookWorker do
    use ObanCodex.Worker,
      queue: :test,
      query_fun: &ObanCodex.WorkerTest.query_auth/2

    @impl ObanCodex.Worker
    def handle_error({:cancel, :auth}, %Error{} = error, job) do
      {:cancel, {:observed, error.kind, job.attempt}}
    end
  end

  defmodule SessionWorker do
    use ObanCodex.Worker,
      queue: :test,
      query_fun: &ObanCodex.WorkerTest.query_with_session/2

    @impl ObanCodex.Worker
    def handle_result(result, _job), do: {:ok, ObanCodex.session_id(result)}
  end

  defmodule PerformOverrideWorker do
    use ObanCodex.Worker, queue: :test

    @impl Oban.Worker
    def perform(%Oban.Job{}), do: {:cancel, :overridden}
  end

  test "default worker returns :ok for a successful result" do
    assert :ok = DefaultWorker.perform(job(%{"prompt" => "x"}))
  end

  test "handle_result can map structured output" do
    assert {:cancel, :blocked} = BlockingWorker.perform(job(%{"prompt" => "x"}))
  end

  test "default handle_error preserves classifier verdicts" do
    assert {:cancel, :auth} = AuthWorker.perform(job(%{"prompt" => "x"}))
  end

  test "job args override ordinary worker defaults" do
    assert {:ok, output} =
             MergeWorker.perform(job(%{"prompt" => "x", "model" => "job-model"}))

    assert {prompt, opts} = Code.eval_string(output) |> elem(0)
    assert prompt == "x"
    assert opts[:model] == "job-model"
    assert opts[:sandbox] == :read_only
  end

  test "a worker can be a prompt-complete routine" do
    assert {:ok, output} = RoutineWorker.perform(job(%{}))
    assert {"standing task", opts} = Code.eval_string(output) |> elem(0)
    assert opts[:model] == "gpt-5"
  end

  test "pinned args override job args and defaults" do
    assert {:ok, output} =
             PinnedWorker.perform(
               job(%{
                 "prompt" => "x",
                 "model" => "job-model",
                 "sandbox" => "danger_full_access",
                 "approval_policy" => "on_request"
               })
             )

    assert {"x", opts} = Code.eval_string(output) |> elem(0)
    assert opts[:model] == "job-model"
    assert opts[:sandbox] == :read_only
    assert opts[:approval_policy] == :never
  end

  test "worker-level classifiers are honored" do
    assert {:cancel, :always} = ClassifierWorker.perform(job(%{"prompt" => "x"}))
  end

  test "handle_error receives the payload and job" do
    assert {:cancel, {:observed, :auth, 2}} =
             ErrorHookWorker.perform(job(%{"prompt" => "x"}, attempt: 2))
  end

  test "handle_result can read a Codex thread id through the seam" do
    assert {:ok, "thread-9"} = SessionWorker.perform(job(%{"prompt" => "x"}))
  end

  test "stored invalid args cancel instead of retrying to exhaustion" do
    assert {{:cancel, {:invalid_args, message}}, %ArgumentError{}} =
             ObanCodex.Worker.__run__(
               %{"prompt" => "x", "sandbox" => "unknown"},
               [query_fun: &__MODULE__.query_ok/2],
               job(%{"prompt" => "x"})
             )

    assert message =~ "unknown sandbox"
  end

  test "missing prompts cancel with a value-free message" do
    assert {{:cancel, {:invalid_args, "missing required arg \"prompt\""}}, %KeyError{}} =
             ObanCodex.Worker.__run__(
               %{},
               [query_fun: &__MODULE__.query_ok/2],
               job(%{})
             )
  end

  test "compile-time worker default keys must be strings" do
    assert_raise ArgumentError, ~r/keys must be strings/, fn ->
      ObanCodex.Worker.__validate_arg_keys__!(__MODULE__, :args, %{model: "gpt-5"})
    end

    assert :ok =
             ObanCodex.Worker.__validate_arg_keys__!(
               __MODULE__,
               :pinned_args,
               %{"sandbox" => "read_only"}
             )
  end

  test "perform/1 remains overridable" do
    assert {:cancel, :overridden} = PerformOverrideWorker.perform(job(%{}))
  end

  test "new/1 is still the normal Oban worker constructor" do
    changeset = DefaultWorker.new(ObanCodex.Args.new(prompt: "x"))
    assert changeset.changes.args == %{"prompt" => "x"}
    assert changeset.changes.queue == "test"
  end

  defp job(args, opts \\ []) do
    struct!(
      Oban.Job,
      Keyword.merge(
        [
          args: args,
          attempt: 1,
          max_attempts: 3,
          meta: %{},
          queue: "test",
          worker: "worker"
        ],
        opts
      )
    )
  end
end
