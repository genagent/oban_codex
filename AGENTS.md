# oban_codex contributor guide

`oban_codex` runs Codex CLI turns as Oban jobs. It should remain a thin,
provider-aware seam: Oban owns queue semantics, `codex_wrapper` owns command
execution, and the host application owns business policy and external effects.

`../oban_claude` is the reference architecture. Keep public concepts, module
layout, worker hooks, CLI shape, testing ergonomics, and the experimental Agent
lifecycle aligned when the providers support equivalent behavior. Record
intentional differences in the README parity table and `SPEC.md`.

## Public surface

- `ObanCodex.run/2` — string-keyed args to `{oban_return, payload}`.
- `ObanCodex.Query` — fresh/resumed Codex command adapter; always JSONL.
- `ObanCodex.Worker` — defaults, pinned args, classifier, result/error hooks.
- `ObanCodex.Args` — validated job and worker-default builders.
- `ObanCodex.Outcome` / `ObanCodex.Error` — default classification.
- `ObanCodex.Testing` — production-shaped JSONL fixtures.
- `ObanCodex.CLI` and `mix oban_codex` — run, doctor, args.
- `mix oban_codex.install` — Igniter SQLite/Lite scaffold.
- `ObanCodex.Agent.*` — opt-in experimental conversational lifecycle.

## Provider rules

- Do not invent fields on `%CodexWrapper.Result{}`. Use public helper functions
  over JSONL events.
- `output_schema` is a file path, not inline schema JSON.
- `session_id` is the canonical Codex resume key; `resume` is an alias.
- Do not promise native worktree isolation, cost, max-turn, or max-budget
  behavior that Codex doesn't expose.
- Never add `env` to persisted args; it creates a secrets-at-rest hazard.
- Dangerous bypass flags must remain explicit and pinnable.
- Keep the `ExecResume --output-schema` compatibility shim isolated and remove
  it when the minimum wrapper version supports the flag.

## Conventions

- Public docs and examples use `ObanCodex.Args`.
- Worker macro maps must be string-keyed.
- Classifiers return `{oban_return, payload}`, never a flat verdict.
- Tests use `ObanCodex.Testing`; live Codex calls carry the `:live` tag and are
  excluded by default.
- Preserve unrelated local changes and use conventional commits.

## Checks

```console
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix credo --strict
mix dialyzer
mix docs
```

Run live smoke tests only when the CLI is installed and authenticated:

```console
mix test --only live
```
