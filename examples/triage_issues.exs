# Read-only issue triage. Offline by default; pass --live for real Codex turns.
#
#     mix run examples/triage_issues.exs
#     mix run examples/triage_issues.exs --live

live? = "--live" in System.argv()

issues = [
  %{"number" => 901, "title" => "Worker drops stored args", "body" => "Looks like a merge bug."},
  %{"number" => 902, "title" => "Document classifier override", "body" => "README gap."},
  %{"number" => 903, "title" => "Add unknown sandbox test", "body" => "Pin the error."}
]

schema_path =
  Path.join(
    System.tmp_dir!(),
    "oban_codex_triage_#{System.unique_integer([:positive])}.json"
  )

schema = %{
  "type" => "object",
  "additionalProperties" => false,
  "required" => ["label", "priority", "summary"],
  "properties" => %{
    "label" => %{"type" => "string", "enum" => ~w(bug enhancement documentation test chore)},
    "priority" => %{"type" => "string", "enum" => ~w(high medium low)},
    "summary" => %{"type" => "string"}
  }
}

File.write!(schema_path, Jason.encode!(schema))

offline = fn prompt, _opts ->
  label =
    cond do
      prompt =~ "bug" -> "bug"
      prompt =~ "Document" -> "documentation"
      true -> "test"
    end

  {:ok,
   ObanCodex.Testing.structured_result(%{
     "label" => label,
     "priority" => "medium",
     "summary" => prompt |> String.split("\n") |> hd() |> String.slice(0, 60)
   })}
end

for issue <- issues do
  prompt = "Issue ##{issue["number"]}: #{issue["title"]}\n\n#{issue["body"]}"

  args =
    ObanCodex.Args.new(
      prompt: prompt,
      working_dir: File.cwd!(),
      sandbox: :read_only,
      approval_policy: :never,
      skip_git_repo_check: true,
      output_schema: schema_path,
      ephemeral: true,
      timeout: :timer.minutes(3)
    )

  options = if live?, do: [], else: [query_fun: offline]

  case ObanCodex.run(args, options) do
    {:ok, result} ->
      IO.puts("##{issue["number"]} #{inspect(ObanCodex.structured(result))}")

    other ->
      IO.puts("##{issue["number"]} failed: #{inspect(other)}")
  end
end

File.rm(schema_path)
