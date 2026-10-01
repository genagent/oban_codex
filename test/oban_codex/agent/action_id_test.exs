defmodule ObanCodex.Agent.ActionIdTest do
  use ExUnit.Case, async: true

  alias ObanCodex.Agent.ActionId

  test "a restarted generator cannot reuse a prior sequence's ID" do
    first = ActionId.new("first-generation", 1)
    restarted = ActionId.new("second-generation", 1)

    assert first == "act_first-generation_1"
    assert restarted == "act_second-generation_1"
    refute first == restarted
  end

  test "actions in one generation have distinct opaque IDs" do
    first = ActionId.new("same-generation", 1)
    second = ActionId.new("same-generation", 2)

    assert String.starts_with?(first, "act_")
    assert String.starts_with?(second, "act_")
    refute first == second
  end
end
