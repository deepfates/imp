defmodule Imp.Adapter.ChatToolResultRendererTest do
  use ExUnit.Case, async: true

  alias Imp.Adapter.Chat

  # A host that must bound what the model reads of a tool result used to wrap
  # the tool's run function, which cut the value the loop recorded. Bounding
  # belongs in rendering: the loop keeps the whole result in history and
  # events, and the adapter renders a bounded view into the prompt.

  defp big, do: String.duplicate("x", 10_000)

  defp recording_lm(owner) do
    counter = :counters.new(1, [])

    Imp.LM.Static.new(
      handler: fn messages, opts ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)
        send(owner, {:request, n, messages, opts})

        if n == 1,
          do: %{
            next_thought: "look",
            tool_calls: [%{id: "c1", name: "look", arguments: %{}}]
          },
          else: %{tool_calls: [%{id: "s", name: "submit", arguments: %{answer: "ok"}}]}
      end
    )
  end

  defp request(i), do: receive(do: ({:request, ^i, messages, _opts} -> messages))

  defp tool_contents(messages),
    do: messages |> Enum.filter(&(&1[:role] == :tool)) |> Enum.map(& &1[:content])

  test "the renderer bounds what the prompt carries while history keeps the whole result" do
    owner = self()
    look = Imp.tool(:look, "Look", fn _ -> big() end)

    program =
      Imp.react_v2("intent -> answer", [look],
        lm: recording_lm(owner),
        adapter_opts: [
          tool_result_renderer: fn result, call ->
            "#{call.name}:#{call.id}:#{String.length(to_string(result))}"
          end
        ]
      )

    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
    assert tool_contents(request(2)) == ["look:c1:10000"]

    [turn | _] = Imp.History.messages(Imp.get(prediction, :history))
    assert [%{result: recorded}] = turn.tool_call_results
    assert recorded == big()
  end

  test "the default renderer is today's prose" do
    owner = self()
    look = Imp.tool(:look, "Look", fn _ -> "seen" end)
    program = Imp.react_v2("intent -> answer", [look], lm: recording_lm(owner))

    assert {:ok, _} = Imp.call(program, %{intent: "hello"})
    assert tool_contents(request(2)) == ["seen"]
  end

  test "errors go through the renderer too, so a host decides how they read" do
    history =
      Imp.History.new([
        %{
          intent: "hello",
          next_thought: "look",
          tool_calls: %{tool_calls: [%{id: "c1", name: "look", arguments: %{}}]},
          tool_call_results: [%{id: "c1", name: "look", result: {:error, :nope}}]
        }
      ])

    signature = %Imp.Signature{
      inputs: [
        Imp.Signature.Field.new(:intent, :input),
        Imp.Signature.Field.new(%{name: :history, type: :history}, :input)
      ],
      outputs: [Imp.Signature.Field.new(:answer, :output)]
    }

    messages =
      Chat.format(signature, %{intent: "hello", history: history},
        tool_result_renderer: fn {:error, reason}, call ->
          "#{call.name} said #{inspect(reason)}"
        end
      )

    assert Enum.any?(messages, &(&1[:role] == :tool and &1[:content] == "look said :nope"))
  end

  test "the option must be a 2-arity function" do
    signature = Imp.Signature.ensure("intent -> answer")

    assert_raise ArgumentError, ~r/tool_result_renderer/, fn ->
      Chat.format(signature, %{intent: "hello"}, tool_result_renderer: fn r -> r end)
    end
  end
end
