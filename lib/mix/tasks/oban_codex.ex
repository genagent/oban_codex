defmodule Mix.Tasks.ObanCodex do
  @shortdoc "Run Codex from the CLI: `mix oban_codex <run|doctor|args>`."

  @moduledoc """
  #{@shortdoc}

  A [`cheer`](https://hexdocs.pm/cheer) command tree over `ObanCodex`, so the
  CLI shares one declarative definition (parsing, validation, `--help`, and shell
  completion) across its subcommands:

    * `mix oban_codex run "<prompt>" [flags]` -- fire a single, queueless Codex
      run and print the verdict.
    * `mix oban_codex doctor` -- a fleet pre-flight check (binary present, usable
      version, authenticated); exits non-zero if the environment is not ready.
    * `mix oban_codex args "<prompt>" [flags]` -- build and print the validated
      `ObanCodex.Args` map from flags, without running Codex (a dry run).

  Every `run` / `args` flag maps to an `ObanCodex.Args.new/1` option; the prompt
  is the first positional argument. `mix oban_codex <cmd> --help` shows the full
  flag list. Scaffolding a project is separate: `mix oban_codex.install` (an
  Igniter task).

  ## Examples

      mix oban_codex run "summarize the repo" --working-dir . --sandbox read_only
      mix oban_codex run "extract the facts" --output-schema schema.json --json
      mix oban_codex args "review this" --model gpt-5 --approval-policy never
      mix oban_codex doctor
  """

  use Cheer.MixTask

  command "oban_codex" do
    about("Run Codex from the command line.")
    subcommand_required(true)

    subcommand(ObanCodex.CLI.Run)
    subcommand(ObanCodex.CLI.Doctor)
    subcommand(ObanCodex.CLI.Args)
  end

  # Override the generated Mix entry point to map our leaf commands' failure
  # verdict onto a conventional nonzero exit (a failed run is exit 1; a usage
  # error stays the cheer/Mix idiom of exit 2).
  @impl Mix.Task
  def run(argv) do
    case Cheer.run(__MODULE__, argv, prog: "mix oban_codex") do
      {:error, :usage} -> exit({:shutdown, 2})
      {:error, :run_failed} -> exit({:shutdown, 1})
      _ -> :ok
    end
  end
end
