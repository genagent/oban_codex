defmodule ObanCodex.CLI.Doctor do
  @moduledoc false

  use Cheer.Command

  alias CodexWrapper.Commands.{Auth, Doctor}
  alias CodexWrapper.Config

  command "doctor" do
    about("Check the Codex CLI, authentication, config, and runtime health.")

    long_about("""
    Runs read-only wrapper probes and exits non-zero if any check fails. No
    model turn is started.
    """)

    option(:binary, type: :string, help: "Path to the codex CLI binary.")
    option(:working_dir, type: :string, short: :w, help: "Working directory to inspect.")
    option(:json, type: :boolean, help: "Print the report as JSON.")
  end

  @impl Cheer.Command
  def run(args, _raw) do
    {:ok, _} = Application.ensure_all_started(:codex_wrapper)
    json? = Map.get(args, :json, false)

    config =
      args
      |> Map.take([:binary, :working_dir])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Config.new()

    checks = [
      {"version", CodexWrapper.version(binary: config.binary)},
      {"authentication", Auth.status(config)},
      {"doctor", Doctor.execute_json(Doctor.new(), config)}
    ]

    {text, ok?} = report(checks)

    cond do
      json? -> Mix.shell().info(json_report(checks, ok?))
      ok? -> Mix.shell().info(text)
      true -> Mix.shell().error(text)
    end

    if ok?, do: :ok, else: {:error, :run_failed}
  end

  @doc false
  @spec report([{String.t(), {:ok, term()} | {:error, term()}}]) :: {String.t(), boolean()}
  def report(checks) do
    ok? =
      Enum.all?(checks, fn
        {"doctor", {:ok, %{"overallStatus" => status}}} -> status in ["ok", "warning"]
        {_label, {:ok, _}} -> true
        _ -> false
      end)

    lines =
      Enum.map_join(checks, "\n", fn
        {label, {:ok, info}} -> "  [ok]   #{label}: #{format_info(info)}"
        {label, {:error, reason}} -> "  [FAIL] #{label}: #{inspect(reason)}"
      end)

    header = if ok?, do: "Codex environment OK", else: "Codex environment NOT ready"
    {header <> "\n" <> lines, ok?}
  end

  @doc false
  @spec json_report([{String.t(), {:ok, term()} | {:error, term()}}], boolean()) :: String.t()
  def json_report(checks, ok?) do
    %{
      ok: ok?,
      checks:
        Enum.map(checks, fn
          {label, {:ok, info}} -> %{name: label, status: "ok", info: normalize(info)}
          {label, {:error, reason}} -> %{name: label, status: "error", reason: inspect(reason)}
        end)
    }
    |> ObanCodex.CLI.encode_json()
  end

  defp format_info(%{"overallStatus" => status}), do: "overallStatus=#{status}"

  defp format_info(info) when is_map(info),
    do: Enum.map_join(info, " ", fn {key, value} -> "#{key}=#{inspect(value)}" end)

  defp format_info(info) when is_binary(info), do: info
  defp format_info(info), do: inspect(info)

  defp normalize(info) when is_map(info), do: info
  defp normalize(info) when is_binary(info) or is_number(info) or is_boolean(info), do: info
  defp normalize(info), do: inspect(info)
end
