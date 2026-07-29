defmodule ObanCodex.Outcome do
  @moduledoc """
  Default mapping from Codex execution outcomes to Oban verdicts.

  | Codex outcome | Oban verdict | Why |
  |---|---|---|
  | `%Result{success: true}` | `:ok` | the worker's `handle_result/2` decides what follows |
  | `%Result{exit_code: 126 or 127}` | `{:cancel, :command_unavailable}` | the configured executable cannot run; retrying cannot repair it |
  | any other non-zero `%Result{}` | `{:error, {:command_failed, code}}` | bounded retry; Codex has no stable typed CLI-error envelope |
  | `%Error{kind: :timeout}` | `{:error, :timeout}` | transient and bounded by `max_attempts` |
  | `%Error{kind: :spawn}` | `{:cancel, :spawn}` | deterministic process setup failure |
  | other normalized `%Error{}` | `{:error, kind}` | retry under Oban's normal attempt bound |
  | an unnormalized error term | `{:cancel, term}` | off-contract and unsafe to retry blindly |

  The classifier returns an envelope, `{oban_return, payload}`. The worker
  unwraps the first element for Oban while preserving the payload for
  `handle_result/2` or `handle_error/3`.

  Override `:classifier` when your deployment can classify Codex's human-readable
  non-zero output more precisely (for example, distinguishing an expired login
  from a temporary provider outage).
  """

  alias CodexWrapper.Result
  alias ObanCodex.Error

  @config_faults [
    :auth,
    :binary_not_found,
    :command_unavailable,
    :invalid_args,
    :invalid_config,
    :version_mismatch
  ]

  @doc "Map a query outcome to the `{oban_return, payload}` envelope."
  @spec classify(ObanCodex.wrapper_outcome()) ::
          {ObanCodex.oban_return(), Result.t() | Error.t() | term()}
  def classify({:ok, %Result{success: true} = result}), do: {:ok, result}

  def classify({:ok, %Result{exit_code: code} = result}) when code in [126, 127],
    do: {{:cancel, :command_unavailable}, result}

  def classify({:ok, %Result{exit_code: code} = result}),
    do: {{:error, {:command_failed, code}}, result}

  def classify({:error, %Error{kind: :timeout} = error}),
    do: {{:error, :timeout}, error}

  def classify({:error, %Error{kind: :auth, reason: :rate_limit} = error}),
    do: {{:error, :rate_limit}, error}

  def classify({:error, %Error{kind: kind} = error}) when kind in @config_faults,
    do: {{:cancel, kind}, error}

  def classify({:error, %Error{kind: :spawn} = error}),
    do: {{:cancel, :spawn}, error}

  def classify({:error, %Error{kind: kind} = error}),
    do: {{:error, kind}, error}

  def classify({:error, other}), do: {{:cancel, other}, other}
end
