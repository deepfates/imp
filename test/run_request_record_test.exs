defmodule Imp.RunRequestRecordTest do
  use ExUnit.Case, async: true

  # A recorded request has to be reproducible. The messages are the event's
  # input, the rest of the request is its metadata, and the tool definitions —
  # the largest and least variable part — are recorded once per roster as their
  # own event, with every request naming its roster by hash.

  defmodule RosterProgram do
    @behaviour Imp.Module
    defstruct [:lm, :rosters]

    @impl true
    def call(program, _inputs) do
      Enum.each(program.rosters, fn tools ->
        {:ok, _response} =
          Imp.LM.generate(program.lm, [%{role: :user, content: "hi"}],
            tools: tools,
            tool_choice: "auto",
            temperature: 0.0,
            api_key: "sk-test-secret-1234567890"
          )
      end)

      {:ok, Imp.Prediction.new(%{answer: "done"})}
    end
  end

  defp tool(name) do
    %{
      type: "function",
      function: %{name: name, description: "does #{name}", parameters: %{"type" => "object"}}
    }
  end

  defp run_events(rosters) do
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> "ok" end)
    program = %RosterProgram{lm: lm, rosters: rosters}

    {:ok, run} = Imp.Run.start(program, %{question: "q"})
    assert {:ok, _prediction} = Task.await(run.task)
    events = Imp.Run.events(run)
    Imp.Run.stop(run)
    events
  end

  test "a request records its options without the tools, and names its roster by hash" do
    events = run_events([[tool("look")], [tool("look")]])

    requests = Enum.filter(events, &(&1.kind == :model_request))
    offered = Enum.filter(events, &(&1.kind == :tools_offered))

    assert length(requests) == 2
    # The roster did not change, so it is recorded once for the whole run.
    assert [one_offer] = offered

    assert Enum.map(one_offer.input, & &1.function.name) == ["look"]
    assert one_offer.metadata.tools_hash == hd(requests).metadata.tools_hash

    for request <- requests do
      options = request.metadata.options
      refute Keyword.has_key?(options, :tools)
      assert options[:tool_choice] == "auto"
      assert options[:temperature] == 0.0
      assert is_binary(request.metadata.tools_hash)
      assert request.metadata.model_call_id
    end

    assert Enum.map(requests, & &1.metadata.tools_hash) |> Enum.uniq() |> length() == 1

    # The definitions precede the request that was sent by them.
    kinds = Enum.map(events, & &1.kind)

    assert Enum.find_index(kinds, &(&1 == :tools_offered)) <
             Enum.find_index(kinds, &(&1 == :model_request))
  end

  test "a run whose roster changes records the new definitions once more" do
    events = run_events([[tool("look")], [tool("look"), tool("write")], [tool("look")]])

    offered = Enum.filter(events, &(&1.kind == :tools_offered))
    requests = Enum.filter(events, &(&1.kind == :model_request))

    # Three requests, two distinct rosters, and the third request repeats the
    # first roster, so it is not offered a third time.
    assert length(requests) == 3
    assert length(offered) == 2

    [first, second, third] = Enum.map(requests, & &1.metadata.tools_hash)
    assert first != second
    assert first == third
    assert Enum.map(offered, & &1.metadata.tools_hash) == [first, second]

    assert Enum.map(Enum.at(offered, 1).input, & &1.function.name) == ["look", "write"]
  end

  test "a request offering no tools has no hash and no definitions event" do
    events = run_events([[]])

    assert [request] = Enum.filter(events, &(&1.kind == :model_request))
    assert request.metadata.tools_hash == nil
    assert Enum.filter(events, &(&1.kind == :tools_offered)) == []
  end

  test "the recorded options are redacted like every other event payload" do
    events = run_events([[tool("look")]])

    assert [request] = Enum.filter(events, &(&1.kind == :model_request))
    refute inspect(request.metadata.options) =~ "sk-test-secret-1234567890"
    assert inspect(request.metadata.options) =~ "REDACTED"
  end
end
