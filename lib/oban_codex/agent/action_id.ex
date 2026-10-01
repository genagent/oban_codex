defmodule ObanCodex.Agent.ActionId do
  @moduledoc false

  @spec new(String.t(), pos_integer()) :: String.t()
  def new(generation, sequence)
      when is_binary(generation) and byte_size(generation) > 0 and
             is_integer(sequence) and sequence > 0 do
    "act_" <> generation <> "_" <> Integer.to_string(sequence)
  end
end
