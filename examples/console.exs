# Load from iex:
#
#     iex -S mix
#     c "examples/console.exs"
#     ObanCodex.Console.run("summarize this repository")
#     ObanCodex.Console.continue("thread-id", "now list the risks")
#
# These are real, queueless Codex turns.

defmodule ObanCodex.Console do
  @moduledoc false

  def run(prompt, opts \\ []) do
    opts =
      Keyword.merge(
        [
          prompt: prompt,
          working_dir: File.cwd!(),
          sandbox: :read_only,
          approval_policy: :never,
          timeout: :timer.minutes(5)
        ],
        opts
      )

    opts |> ObanCodex.Args.new() |> execute()
  end

  def continue(thread_id, prompt, opts \\ []) do
    run(prompt, Keyword.put(opts, :session_id, thread_id))
  end

  defp execute(args) do
    case ObanCodex.run(args) do
      {:ok, result} ->
        IO.puts(ObanCodex.text(result) || "")

        IO.puts(
          "\nthread=#{ObanCodex.session_id(result)} usage=#{inspect(ObanCodex.usage(result))}"
        )

        {:ok, result}

      {verdict, payload} ->
        IO.puts("Codex failed: #{inspect(verdict)}")
        {:error, payload}
    end
  end
end
