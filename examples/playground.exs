# Offline seam playground. No Oban instance and no Codex process are required.
#
#     mix run examples/playground.exs

import ObanCodex.Testing

query =
  sequence([
    result("all good", session_id: "thread-1", usage: %{"output_tokens" => 4}),
    structured_result(%{"outcome" => "blocked", "reason" => "missing input"}),
    error(:timeout),
    failed_result("provider temporarily unavailable", exit_code: 2)
  ])

args =
  ObanCodex.Args.new(
    prompt: "inspect",
    model: "gpt-5",
    sandbox: :read_only,
    approval_policy: :never
  )

for n <- 1..4 do
  {verdict, payload} = ObanCodex.run(args, query_fun: query)

  IO.puts("""
  run #{n}
    verdict:    #{inspect(verdict)}
    payload:    #{inspect(payload.__struct__)}
    text:       #{inspect(if match?(%CodexWrapper.Result{}, payload), do: ObanCodex.text(payload))}
    structured: #{inspect(if match?(%CodexWrapper.Result{}, payload), do: ObanCodex.structured(payload))}
    session:    #{inspect(ObanCodex.session_id(payload))}
  """)
end
