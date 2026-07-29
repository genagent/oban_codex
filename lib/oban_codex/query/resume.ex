defmodule ObanCodex.Query.Resume do
  @moduledoc false

  @behaviour CodexWrapper.Command

  alias CodexWrapper.{ExecResume, Result}

  defstruct [:exec, :session_id, :prompt, :output_schema]

  @type t :: %__MODULE__{
          exec: ExecResume.t(),
          session_id: String.t(),
          prompt: String.t(),
          output_schema: String.t() | nil
        }

  @impl true
  def args(%__MODULE__{} = command) do
    # codex_wrapper 0.4's ExecResume predates the CLI's resume
    # --output-schema flag. Reuse its complete option builder and append the
    # missing flag before the two positional arguments.
    command.exec
    |> ExecResume.args()
    |> add_opt("--output-schema", command.output_schema)
    |> Kernel.++([command.session_id, command.prompt])
  end

  @impl true
  def parse_output(stdout, exit_code), do: {:ok, Result.from_cmd({stdout, exit_code})}

  defp add_opt(args, _flag, nil), do: args
  defp add_opt(args, flag, value), do: args ++ [flag, value]
end
