defmodule ObanCodex.Error do
  @moduledoc """
  A normalized execution error from the Codex wrapper.

  `CodexWrapper.Exec.execute/2` returns a `%CodexWrapper.Result{}` whenever the
  CLI starts and exits, including non-zero exits. Failures before a result is
  available (timeouts, spawn failures, signals, and I/O failures) are plain
  terms. `ObanCodex.Query` wraps those terms in this small stable shape so
  workers and classifiers don't need to know runner internals.

  A non-zero Codex exit remains a `%CodexWrapper.Result{success: false}` and is
  classified separately as `:command_failed`.
  """

  @type kind :: :timeout | :spawn | :signal | :io | :execution | atom()

  @type t :: %__MODULE__{
          kind: kind(),
          reason: term(),
          message: String.t() | nil
        }

  defstruct [:kind, :reason, :message]

  @doc "Build an error, primarily for custom query functions and tests."
  @spec new(kind(), keyword()) :: t()
  def new(kind, opts \\ []) when is_atom(kind) and is_list(opts) do
    opts = Keyword.validate!(opts, reason: nil, message: nil)

    %__MODULE__{
      kind: kind,
      reason: opts[:reason],
      message: opts[:message]
    }
  end

  @doc false
  @spec from_reason(term()) :: t()
  def from_reason(%__MODULE__{} = error), do: error

  def from_reason({:timeout, milliseconds} = reason) do
    new(:timeout,
      reason: reason,
      message: "Codex execution timed out after #{inspect(milliseconds)}ms"
    )
  end

  def from_reason({kind, _detail} = reason) when kind in [:spawn, :signal, :io] do
    new(kind, reason: reason, message: "Codex execution failed: #{inspect(reason)}")
  end

  def from_reason(reason) do
    new(:execution, reason: reason, message: "Codex execution failed: #{inspect(reason)}")
  end
end
