defmodule PredictJsonRetriesTest do
  use ExUnit.Case, async: true

  # `json_retries: n` answers a parse failure with up to n more requests, each
  # carrying the latest failure's message, and stops at the first that parses.

  defp lm(owner, replies) do
    counter = :counters.new(1, [])

    Imp.LM.Static.new(
      handler: fn messages, _opts ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)
        send(owner, {:request, n, messages})
        Enum.at(replies, n - 1, List.last(replies))
      end
    )
  end

  defp requests(owner_count \\ 0) do
    receive do
      {:request, _n, _messages} -> requests(owner_count + 1)
    after
      0 -> owner_count
    end
  end

  defp program(lm, retries),
    do:
      Imp.predict("ticket -> team, severity: integer",
        lm: lm,
        adapter: Imp.Adapter.JSON,
        config: [json_retries: retries]
      )

  test "n retries make up to n more requests" do
    for n <- [0, 1, 3] do
      assert {:error, _reason} =
               Imp.call(program(lm(self(), ["not json"]), n), %{ticket: "t"})

      assert requests() == n + 1
    end
  end

  test "the retries stop at the first reply that parses, which is the answer" do
    replies = ["not json", "still not", ~s({"team":"atlas","severity":2})]

    assert {:ok, prediction} = Imp.call(program(lm(self(), replies), 3), %{ticket: "t"})
    assert {Imp.get(prediction, :team), Imp.get(prediction, :severity)} == {"atlas", 2}
    assert requests() == 3
  end
end
