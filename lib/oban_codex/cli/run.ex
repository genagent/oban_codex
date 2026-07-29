defmodule ObanCodex.CLI.Run do
  @moduledoc false
  # `mix oban_codex run` -- the one-shot, queueless counterpart to the Oban
  # worker. CLI flags parse into the same `ObanCodex.Args.new/1` vocabulary, run
  # through `ObanCodex.run/2`, and the `{oban_return, result}` verdict prints.

  use Cheer.Command
  require ObanCodex.CLI

  command "run" do
    about("Fire a single Codex run (no queue, no database).")

    long_about("""
    Parse CLI flags into the ObanCodex.Args vocabulary, run one Codex call via
    ObanCodex.run/2, and print the {oban_return, result} verdict. Makes a real
    model call using the CLI's own authentication. The task exits
    non-zero when the verdict is {:error, _} or {:cancel, _}.
    """)

    ObanCodex.CLI.codex_options()

    option(:json, type: :boolean, help: "Print a machine-readable JSON summary instead of text.")
  end

  @impl Cheer.Command
  def run(args, _raw) do
    {:ok, _} = Application.ensure_all_started(:codex_wrapper)
    {json?, args} = Map.pop(args, :json, false)

    outcome = args |> ObanCodex.CLI.to_args() |> ObanCodex.run()

    if ObanCodex.CLI.emit(outcome, json?), do: :ok, else: {:error, :run_failed}
  end
end
