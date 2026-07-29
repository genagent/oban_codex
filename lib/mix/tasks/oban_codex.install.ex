defmodule Mix.Tasks.ObanCodex.Install.Docs do
  @moduledoc false

  def short_doc, do: "Scaffold a runnable SQLite-backed oban_codex setup."

  def example, do: "mix oban_codex.install"

  def long_doc do
    """
    #{short_doc()}

    Composes `oban.install` (steering it to SQLite and the `Oban.Engines.Lite`
    engine) and adds the Codex-specific pieces on top: a sample worker, a
    telemetry logger, and a boot-time demo enqueue so `iex -S mix` shows a job
    run end to end.

    ## Example

        # into a fresh project
        mix igniter.new my_app --install oban_codex

        # or into an existing project
        mix igniter.install oban_codex

    Then:

        iex -S mix

    ## What it produces

      * an Ecto SQLite3 repo (module, dev/test config, supervision child)
      * Oban configured with `Oban.Engines.Lite`, its migration, and supervision
      * a sample `ObanCodex.Worker` on a `:codex` queue
      * a telemetry logger + a dev-only boot enqueue (the "watch" demo)

    The sample worker ships with a stubbed, offline `query_fun` so the demo runs
    without a real Codex call. Delete that one option to call Codex.
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.ObanCodex.Install do
    @shortdoc __MODULE__.Docs.short_doc()

    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    alias Igniter.Project.{Application, Config, Module}

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :oban_codex,
        example: __MODULE__.Docs.example(),
        composes: ["oban.install"],
        adds_deps: [{:oban, "~> 2.23"}, {:ecto_sqlite3, "~> 0.17"}],
        installs: [],
        schema: [],
        defaults: [],
        aliases: [],
        positional: [],
        required: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      app_name = Application.app_name(igniter)
      repo = Module.module_name(igniter, "Repo")
      worker = Module.module_name(igniter, "SampleCodexWorker")
      demo = Module.module_name(igniter, "ObanCodexDemo")

      igniter
      |> ensure_sqlite_repo(app_name, repo)
      |> Igniter.compose_task("oban.install", [
        "--engine",
        "Oban.Engines.Lite",
        "--repo",
        inspect(repo)
      ])
      |> configure_codex_queue(app_name)
      |> create_worker(worker)
      |> create_demo(app_name, worker, demo)
      |> Application.add_new_child(demo, after: [Oban])
      |> Igniter.add_notice(notice(worker))
    end

    # A SQLite repo has to exist before `oban.install` runs (it errors when no
    # repo is found), so create the module, its config, and its supervision
    # child up front.
    defp ensure_sqlite_repo(igniter, app_name, repo) do
      db_dev = "#{app_name}_dev.db"
      db_test = "#{app_name}_test.db"

      igniter
      |> Module.create_module(repo, """
      use Ecto.Repo, otp_app: #{inspect(app_name)}, adapter: Ecto.Adapters.SQLite3
      """)
      |> Config.configure_new("config.exs", app_name, [:ecto_repos], [repo])
      |> Config.configure_new("dev.exs", app_name, [repo], database: db_dev, pool_size: 5)
      |> Config.configure_new("test.exs", app_name, [repo],
        database: db_test,
        pool_size: 5,
        pool: Ecto.Adapters.SQL.Sandbox
      )
      |> Application.add_new_child(repo)
    end

    # `oban.install` writes `queues: [default: 10]`; add the `:codex` queue the
    # sample worker runs on. Use an `:updater` that *merges* `codex: 5` into the
    # existing keyword list rather than replacing it -- a bare `configure/5`
    # would overwrite an app's other queues (mailers, events, ...) and silently
    # stop them processing on the next boot.
    defp configure_codex_queue(igniter, app_name) do
      Config.configure(
        igniter,
        "config.exs",
        app_name,
        [Oban, :queues],
        [default: 10, codex: 5],
        updater: fn zipper ->
          Igniter.Code.Keyword.set_keyword_key(zipper, :codex, 5, fn z -> {:ok, z} end)
        end
      )
    end

    defp create_worker(igniter, worker) do
      Module.create_module(igniter, worker, ~S'''
      @moduledoc """
      A sample oban_codex worker.

      It ships with a stubbed, offline `query_fun` so the boot demo runs without
      a real Codex call. To call Codex for real, delete the `query_fun`
      option from the `use` below.
      """
      # Fleet rails (see the "Agent worker patterns" guide): `max_attempts` is
      # explicit because every retry is a fresh model run -- use 1 for a mutating
      # worker; `timeout` bounds a wedged CLI; add `forcola` + the runner config
      # so a timed-out or cancelled run is actually killed, not orphaned.
      # `ignore_user_config` avoids ambient developer config drift.
      use ObanCodex.Worker,
        queue: :codex,
        max_attempts: 3,
        args: ObanCodex.Args.defaults(
          timeout: :timer.minutes(10),
          sandbox: :read_only,
          approval_policy: :never,
          ignore_user_config: true
        ),
        query_fun: &__MODULE__.demo_query/2

      require Logger

      @impl ObanCodex.Worker
      def handle_result(result, _job) do
        Logger.info("[oban_codex] sample job result: #{inspect(ObanCodex.text(result))}")
        :ok
      end

      @doc false
      # Offline stand-in for `ObanCodex.Query.run/2`, built with
      # `ObanCodex.Testing` (so it never hard-codes codex_wrapper's struct).
      # Delete the `query_fun` option above to run the real Codex CLI instead.
      def demo_query(prompt, _opts) do
        {:ok, ObanCodex.Testing.result("demo run for: #{prompt}")}
      end
      ''')
    end

    # The "watch" demo: a supervised process that attaches a telemetry logger for
    # the run events and, in dev, enqueues one sample job on boot so `iex -S mix`
    # immediately shows a job run. Delete this module (and its child) for a real
    # app.
    defp create_demo(igniter, app_name, worker, demo) do
      Module.create_module(igniter, demo, """
      @moduledoc \"\"\"
      Watch demo for oban_codex: logs run telemetry and enqueues one sample job
      on boot (dev only). Delete this module and its child in your Application to
      remove the demo.

      > #### Telemetry carries sensitive data {: .warning}
      >
      > The `:args` (prompt and metadata), `:result`, and `:error`
      > metadata on these events can contain prompts and raw CLI stdout/stderr.
      > This demo logs only duration/usage and the error *kind*; redact before shipping
      > telemetry to a log aggregator.
      \"\"\"
      use GenServer

      require Logger

      @events [[:oban_codex, :run, :stop], [:oban_codex, :run, :exception]]

      def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

      @impl true
      def init(_) do
        :telemetry.attach_many("#{app_name}-oban-codex", @events, &__MODULE__.handle_event/4, nil)
        # Enqueue after init returns, so a boot before `mix ecto.migrate` does not
        # crash the app on a missing table (the enqueue is guarded below).
        {:ok, nil, {:continue, :maybe_enqueue}}
      end

      @impl true
      def handle_continue(:maybe_enqueue, state) do
        if dev?(), do: enqueue_sample()
        {:noreply, state}
      end

      # Guarded so this never crashes in a release, where Mix is unavailable.
      defp dev?, do: Code.ensure_loaded?(Mix) and Mix.env() == :dev

      @impl true
      def terminate(_reason, _state) do
        :telemetry.detach("#{app_name}-oban-codex")
        :ok
      end

      def handle_event([:oban_codex, :run, :stop], meas, meta, _) do
        Logger.info(
          "[oban_codex] run finished in \#{System.convert_time_unit(meas.duration, :native, :millisecond)}ms " <>
            "usage=\#{inspect(ObanCodex.usage(meta.result))}"
        )
      end

      def handle_event([:oban_codex, :run, :exception], meas, meta, _) do
        # Log the normalized kind, not the whole reason, which may carry paths.
        kind =
          case meta.error do
            %ObanCodex.Error{kind: k} -> k
            other -> inspect(other)
          end

        Logger.warning(
          "[oban_codex] run errored (\#{kind}) after " <>
            "\#{System.convert_time_unit(meas.duration, :native, :millisecond)}ms"
        )
      end

      defp enqueue_sample do
        ObanCodex.Args.new(prompt: "hello from oban_codex")
        |> #{inspect(worker)}.new()
        |> Oban.insert()
      rescue
        e ->
          Logger.warning("[oban_codex] demo enqueue skipped -- run mix ecto.migrate first (\#{Exception.message(e)})")
      end
      """)
    end

    defp notice(worker) do
      """
      oban_codex is installed. Next:

        mix ecto.create
        mix ecto.migrate
        iex -S mix

      On boot (in dev) a sample job is enqueued and #{inspect(worker)} runs it
      offline, logging via telemetry. To call Codex for real, delete the
      `query_fun` option in #{inspect(worker)}.

      Before running a fleet unattended, set up the fleet rails (see the
      "Agent worker patterns" guide):

        * add {:forcola, "~> 0.3"} and `config :codex_wrapper, runner:
          CodexWrapper.Runner.Forcola` so a timed-out/cancelled run is killed,
          not orphaned;
        * add {Oban.Plugins.Lifeline, rescue_after: <above your args timeout>}
          to the Oban `plugins:` so jobs orphaned by a deploy are rescued;
        * add {Oban.Plugins.Pruner, max_age: <sized to data sensitivity>} -- job
          args (prompt and metadata) are stored plaintext in oban_jobs
          and kept forever without it. Never put secrets/PII in a prompt;
        * keep `max_attempts` low (retries are paid) and raise
          `shutdown_grace_period` above your worst-case run.
      """
    end
  end
else
  defmodule Mix.Tasks.ObanCodex.Install do
    @shortdoc "Scaffold a runnable SQLite-backed oban_codex setup (requires Igniter)."
    @moduledoc @shortdoc

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      mix oban_codex.install requires Igniter, which is not available.

      Add it to your deps and re-run:

          {:igniter, "~> 0.6", only: [:dev, :test]}
      """)

      exit({:shutdown, 1})
    end
  end
end
