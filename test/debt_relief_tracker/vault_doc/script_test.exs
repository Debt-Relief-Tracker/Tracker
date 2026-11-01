defmodule DebtReliefTracker.VaultDoc.ScriptTest do
  use ExUnit.Case, async: true

  alias DebtReliefTracker.VaultDoc.Json
  alias DebtReliefTracker.VaultDocScript

  def id_source do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    fn ->
      n = Agent.get_and_update(agent, &{&1 + 1, &1 + 1})
      "id-" <> String.pad_leading(Integer.to_string(n), 4, "0")
    end
  end

  def run, do: VaultDocScript.run(id_source())

  test "the script is deterministic and behaves as designed" do
    out = run()
    assert out == run()
    {:ok, result} = Json.decode(out)

    steps = result["steps"]
    assert length(steps) == 20
    # steps that must be rejected
    for n <- [5, 8, 15, 18, 20], do: assert(String.starts_with?(Enum.at(steps, n - 1), "error:"), "step #{n}")
    for n <- [1, 2, 3, 4, 6, 7, 9, 10, 11, 12, 14, 16, 17, 19], do: refute(String.starts_with?(Enum.at(steps, n - 1), "error:"), "step #{n}")
    # a skip after a post of the same cycle is not due
    assert Enum.at(steps, 12) =~ "not_due"
    assert result["merge_commutes"] and result["roundtrip"] and result["tricky_roundtrip"]
    assert result["bad_json"] == [true, true, true, true]
  end
end
