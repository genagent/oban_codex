defmodule ObanCodex.IntegrationTest do
  # Boots a REAL SQLite/Lite Oban and runs jobs through the executor -- not a
  # stub of it -- to pin the runtime seam semantics the library's docs rely on
  # but that pure `perform/1` tests cannot observe (#89):
  #
  #   * a transient `{:error, _}` verdict (the default `:timeout` mapping) retries
  #     WITHOUT growing `max_attempts` -- so the retry budget is bounded, which is
  #     what `ObanCodex.Outcome`'s "cancel vs retry" rationale leans on;
  #   * a `{:snooze, _}` verdict lands `scheduled` and INCREMENTS `max_attempts`
  #     -- i.e. a snooze does not consume an attempt, the fact the "never snooze a
  #     deterministically-failing run" default is designed around.
  #
  # Snooze/attempt accounting has shifted across Oban 2.x; this test fails loudly
  # if a codex_wrapper- or Oban-version bump regresses it.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  @oban __MODULE__.Oban

  # Verdicts are fixed at the query_fun / classifier seam (named functions, since
  # `use` captures them at compile time), so the EXECUTOR decides the job's fate.
  def timeout_query(_prompt, _opts), do: {:error, ObanCodex.Testing.error(:timeout)}
  def ok_query(_prompt, _opts), do: {:ok, ObanCodex.Testing.result("done")}

  def continuation_query(_prompt, _opts),
    do: {:error, ObanCodex.Testing.error(:auth, reason: %{session_id: "thread-9"})}

  def snooze_classify({:ok, %CodexWrapper.Result{} = r}), do: {{:snooze, 30}, r}
  def snooze_classify(outcome), do: ObanCodex.Outcome.classify(outcome)

  defmodule Repo do
    use Ecto.Repo, otp_app: :oban_codex, adapter: Ecto.Adapters.SQLite3
  end

  defmodule Migration do
    use Ecto.Migration
    def up, do: Oban.Migrations.up()
    def down, do: Oban.Migrations.down()
  end

  defmodule TimeoutWorker do
    use ObanCodex.Worker,
      queue: :integration,
      max_attempts: 3,
      query_fun: &ObanCodex.IntegrationTest.timeout_query/2
  end

  defmodule SnoozeWorker do
    use ObanCodex.Worker,
      queue: :integration,
      max_attempts: 3,
      query_fun: &ObanCodex.IntegrationTest.ok_query/2,
      classifier: &ObanCodex.IntegrationTest.snooze_classify/1
  end

  defmodule ResumeWorker do
    use ObanCodex.Worker,
      queue: :integration,
      max_attempts: 1,
      query_fun: &ObanCodex.IntegrationTest.continuation_query/2

    # A bounded resume handoff end to end under the executor. The custom error
    # carries a thread id to demonstrate the same hook used by deployment-
    # specific classifiers.
    @impl ObanCodex.Worker
    def handle_error({:cancel, _kind} = verdict, %ObanCodex.Error{} = error, job) do
      sid = ObanCodex.session_id(error)
      depth = String.to_integer(job.meta["resume_depth"] || "0")

      if is_binary(sid) and depth < 1 do
        ObanCodex.Args.new(prompt: "continue", session_id: sid)
        |> __MODULE__.new(meta: %{"resume_depth" => to_string(depth + 1)})
        |> then(&Oban.insert(ObanCodex.IntegrationTest.Oban, &1))
      end

      verdict
    end
  end

  setup_all do
    db = Path.join(System.tmp_dir!(), "oban_codex_integration_test.db")
    for suffix <- ["", "-shm", "-wal"], do: File.rm(db <> suffix)

    # pool_size: 1 (as the examples do) avoids a WAL cold-start "database is
    # locked" race between concurrent connection opens; the executor and the
    # test's polling serialize through the one connection under busy_timeout.
    Application.put_env(:oban_codex, Repo,
      database: db,
      pool_size: 1,
      busy_timeout: 5_000,
      log: false
    )

    start_supervised!(Repo)
    Ecto.Migrator.up(Repo, 1, Migration, log: false)

    start_supervised!(
      {Oban,
       name: @oban,
       repo: Repo,
       engine: Oban.Engines.Lite,
       peer: Oban.Peers.Isolated,
       notifier: Oban.Notifiers.PG,
       plugins: [],
       queues: [integration: 1]}
    )

    :ok
  end

  test "a transient {:error, :timeout} verdict retries without growing max_attempts" do
    {:ok, job} = Oban.insert(@oban, TimeoutWorker.new(%{"prompt" => "x"}))
    row = wait_until_settled(job.id)

    # retryable (attempts remain), attempt consumed, budget NOT extended.
    assert row.state == "retryable"
    assert row.attempt == 1
    assert row.max_attempts == 3
  end

  test "a {:snooze, n} verdict schedules the job and increments max_attempts (snooze != attempt)" do
    {:ok, job} = Oban.insert(@oban, SnoozeWorker.new(%{"prompt" => "x"}))
    row = wait_until_settled(job.id)

    assert row.state == "scheduled"
    # the load-bearing invariant: snooze grows the budget, so it does not burn an
    # attempt -- the exact behavior the default "never snooze" mapping avoids.
    assert row.max_attempts == 4
  end

  test "handle_error/3 can enqueue one bounded thread continuation" do
    {:ok, _} = Oban.insert(@oban, ResumeWorker.new(%{"prompt" => "x"}))

    jobs = wait_for_resume_jobs(2)
    assert length(jobs) == 2
    [original, resume] = jobs

    refute Map.has_key?(original.args, "session_id")
    assert resume.args["session_id"] == "thread-9"
    assert resume.meta["resume_depth"] == "1"
  end

  # Poll the row until the executor moves it out of the pre-run states. No Stager
  # plugin runs, so a retryable/scheduled job stays put once it lands there.
  defp wait_until_settled(id, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 4_000

    row =
      Repo.one(
        from(j in "oban_jobs",
          where: j.id == ^id,
          select: %{state: j.state, attempt: j.attempt, max_attempts: j.max_attempts}
        )
      )

    settled = ~w(retryable scheduled completed discarded cancelled)

    cond do
      row && row.state in settled ->
        row

      System.monotonic_time(:millisecond) > deadline ->
        flunk("job #{id} did not settle within 4s (last: #{inspect(row)})")

      true ->
        Process.sleep(25)
        wait_until_settled(id, deadline)
    end
  end

  # Poll until `expected` ResumeWorker jobs exist AND have all settled (a broken
  # enqueue never reaches the count and flunks on the deadline, rather than passing).
  defp wait_for_resume_jobs(expected, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    jobs =
      Repo.all(
        from(j in "oban_jobs",
          where: j.worker == "ObanCodex.IntegrationTest.ResumeWorker",
          order_by: [asc: j.id],
          select: %{args: j.args, meta: j.meta, state: j.state}
        )
      )
      # the schemaless query returns the JSON columns as raw strings under SQLite.
      |> Enum.map(fn j -> %{j | args: decode(j.args), meta: decode(j.meta)} end)

    terminal = ~w(cancelled discarded completed)

    cond do
      length(jobs) >= expected and Enum.all?(jobs, &(&1.state in terminal)) ->
        jobs

      System.monotonic_time(:millisecond) > deadline ->
        flunk("expected #{expected} settled ResumeWorker jobs, got #{inspect(jobs)}")

      true ->
        Process.sleep(25)
        wait_for_resume_jobs(expected, deadline)
    end
  end

  defp decode(json) when is_binary(json), do: Jason.decode!(json)
  defp decode(other), do: other
end
