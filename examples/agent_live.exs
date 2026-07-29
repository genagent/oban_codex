# Two real structured Codex turns in one conversation. This demonstrates the
# provider mechanics used by ObanCodex.Agent and starts model work.
#
#     mix run examples/agent_live.exs

schema_path =
  Path.join(
    System.tmp_dir!(),
    "oban_codex_agent_live_#{System.unique_integer([:positive])}.json"
  )

schema = %{
  "type" => "object",
  "additionalProperties" => false,
  "required" => ["directive", "summary"],
  "properties" => %{
    "directive" => %{
      "type" => "string",
      "enum" => ["none", "ask_user", "request_permission"]
    },
    "summary" => %{"type" => "string"},
    "question" => %{"type" => "string"},
    "action" => %{"type" => "string"}
  }
}

File.write!(schema_path, Jason.encode!(schema))

base = [
  working_dir: File.cwd!(),
  sandbox: :read_only,
  approval_policy: :never,
  output_schema: schema_path,
  timeout: :timer.minutes(5)
]

{:ok, first} =
  [prompt: "Summarize this project. Return directive none." | base]
  |> ObanCodex.Args.new()
  |> ObanCodex.run()

IO.inspect(ObanCodex.structured(first), label: "turn 1")
thread_id = ObanCodex.session_id(first)

{:ok, second} =
  [prompt: "Now summarize the testing strategy. Return directive none.", session_id: thread_id]
  |> Keyword.merge(base)
  |> ObanCodex.Args.new()
  |> ObanCodex.run()

IO.inspect(ObanCodex.structured(second), label: "turn 2")
IO.puts("thread=#{ObanCodex.session_id(second)}")
File.rm(schema_path)
