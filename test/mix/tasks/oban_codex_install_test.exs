defmodule Mix.Tasks.ObanCodex.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  defp install do
    test_project()
    |> Igniter.compose_task("oban_codex.install", [])
  end

  test "creates a SQLite repo module" do
    install()
    |> assert_creates("lib/test/repo.ex", """
    defmodule Test.Repo do
      use Ecto.Repo, otp_app: :test, adapter: Ecto.Adapters.SQLite3
    end
    """)
  end

  test "creates a sample worker on the :codex queue with an offline query_fun" do
    igniter = install()

    assert_creates(igniter, "lib/test/sample_codex_worker.ex")

    worker = source_content(igniter, "lib/test/sample_codex_worker.ex")
    assert worker =~ "use ObanCodex.Worker"
    assert worker =~ "queue: :codex"
    assert worker =~ "query_fun: &__MODULE__.demo_query/2"
    assert worker =~ "timeout: :timer.minutes(10)"
    assert worker =~ "sandbox: :read_only"
    assert worker =~ "approval_policy: :never"
    assert worker =~ "ignore_user_config: true"
    assert worker =~ "max_attempts: 3"
  end

  test "creates the watch-demo module that logs telemetry and enqueues on boot" do
    igniter = install()

    assert_creates(igniter, "lib/test/oban_codex_demo.ex")

    demo = source_content(igniter, "lib/test/oban_codex_demo.ex")
    assert demo =~ "[:oban_codex, :run, :stop]"
    assert demo =~ "Test.SampleCodexWorker.new("
    assert demo =~ "Oban.insert()"
    # enqueue moved out of init/1 so a pre-migrate boot doesn't crash the app
    assert demo =~ "handle_continue"
    # the :exception handler logs the error kind, not the whole struct
    assert demo =~ "run errored"
  end

  test "configures Oban with the Lite engine and merges the :codex queue" do
    config = install() |> source_content("config/config.exs")

    assert config =~ "Oban.Engines.Lite"
    assert config =~ "codex:"
    # the merge keeps oban.install's existing default queue rather than replacing it
    assert config =~ "default:"
    assert config =~ "ecto_repos"
  end

  # Igniter.Test exposes created/updated file bodies via the rewrite sources;
  # read one out of the applied igniter for content assertions.
  defp source_content(igniter, path) do
    igniter = Igniter.Test.apply_igniter!(igniter)
    Rewrite.source!(igniter.rewrite, path) |> Rewrite.Source.get(:content)
  end
end
