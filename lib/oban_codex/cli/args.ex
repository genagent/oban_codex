defmodule ObanCodex.CLI.Args do
  @moduledoc false
  # `mix oban_codex args` -- build and print the validated ObanCodex.Args map
  # from flags WITHOUT running Codex. A dry-run/preview of `Args.new/1`: useful
  # to see exactly what a set of flags produces (and to debug the vocabulary)
  # before spending a paid run.

  use Cheer.Command
  require ObanCodex.CLI

  command "args" do
    about("Build and print the validated args map from flags, without running Codex.")

    ObanCodex.CLI.codex_options()

    option(:json, type: :boolean, help: "Print the args map as JSON instead of inspected form.")
  end

  @impl Cheer.Command
  def run(args, _raw) do
    {json?, args} = Map.pop(args, :json, false)
    args_map = ObanCodex.CLI.to_args(args)

    out =
      if json?, do: ObanCodex.CLI.encode_json(args_map), else: inspect(args_map, pretty: true)

    Mix.shell().info(out)
    :ok
  end
end
