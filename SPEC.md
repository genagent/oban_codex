# oban_codex contract

This document records the package boundary, provider translation, and backlog.
`oban_claude` is the reference architecture; parity is the default unless the
Codex CLI contract makes it misleading.

## Boundary

`oban_codex` owns:

- a string-keyed Oban args map to Codex query-options adapter;
- JSONL result readers;
- outcome-to-Oban classification;
- worker defaults, pinned args, and result/error hooks;
- offline testing fixtures;
- CLI, Igniter installer, telemetry;
- the opt-in experimental Agent lifecycle.

Oban owns storage, claiming, concurrency, retries, schedules, uniqueness,
recovery, and pruning. `codex_wrapper` owns CLI command construction and process
execution. The host application owns prompts, business policy, persistence,
external services, and isolated workspaces.

No GitHub-specific source/sink logic belongs here.

## Core contract

```elixir
ObanCodex.run(args, opts \\ [])
```

- `args` is a string-keyed map; `"prompt"` is required.
- known keys are forwarded; unknown raw-map keys are ignored.
- enum strings are converted through explicit allowlists.
- the default query path always forces Codex JSONL.
- a completed CLI invocation returns the underlying
  `%CodexWrapper.Result{}`, including non-zero exits.
- pre-result errors are normalized as `%ObanCodex.Error{}`.
- the classifier must return `{oban_return, payload}`.

Curated args are the schema in `ObanCodex.Args`: model/profile, process config,
sandbox/approval controls, context directories, search, structured output,
images, config/feature controls, local-provider controls, and explicit session
resume.

`:env` is intentionally excluded because Oban stores args in plaintext.

## Result contract

Codex emits NDJSON, not a rich result struct. Public readers are:

- `events/1`
- `text/1`
- `structured/1`
- `outcome/1`
- `session_id/1`
- `usage/1`
- `cost_usd/1` (currently `nil` for normal Codex results)

Structured output is JSON text in the final `agent_message` event. A decoded
object or array is returned; malformed JSON and scalars return `nil`.

The thread identifier is `thread_id`, with `session_id` accepted as a defensive
event fallback.

## Resume compatibility shim

Codex CLI supports `codex exec resume --output-schema`, but
`codex_wrapper 0.4`'s `ExecResume` builder doesn't expose that flag.
`ObanCodex.Query.Resume` delegates every other option to `ExecResume.args/1`
and inserts `--output-schema` before the positional thread id and prompt.

Remove the shim after the minimum wrapper version exposes this option, with a
regression test proving identical arguments.

## Intentional divergence from oban_claude

- Codex policy is `sandbox` + `approval_policy`, not `permission_mode`.
- structured schema is a node-local file path, not inline JSON.
- no native worktree option is promised.
- no cost, max-turn, or max-budget fields are synthesized.
- Codex non-zero output has no stable typed error-kind contract; arbitrary
  failures retry bounded by `max_attempts` unless a custom classifier knows
  more.
- `session_id` is canonical; `resume` is only an API-parity alias.

## Agent contract

The Agent state machine remains provider-independent and matches
`oban_claude`:

```text
idle -> running -> idle
              -> waiting_for_user
              -> awaiting_permission
any state -> paused
```

Turns are ordinary Oban jobs. Results feed the machine through
`Agent.Job.handle_result/2`; retrying attempts stay logically in `running`;
completed failures return to idle or re-gate an incomplete approved action.
The captured Codex thread id is placed in the next turn's `"session_id"`.

## Backlog

- Remove the resume output-schema shim after a wrapper release exposes it.
- Add wrapper-backed typed CLI failure events if Codex gains a stable machine
  error envelope; then refine `Outcome` without parsing prose.
- Consider a pluggable cost calculator from token usage and model pricing. Do
  not bake mutable pricing into the core package.
- Add a deployment recipe for external checkout/worktree managers.
- Exercise initial + resumed structured turns in the opt-in live suite.
- Keep the parity table checked whenever either Oban integration adds a public
  feature.

## Release gate

- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix test`
- `mix credo --strict`
- `mix dialyzer`
- `mix docs`
- package build against the released `codex_wrapper` dependency (no path dep)
