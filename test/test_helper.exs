# `:live` tests make a real Codex call. Excluded by default; run them
# explicitly with `mix test --only live`.
ExUnit.start(exclude: [:live])
