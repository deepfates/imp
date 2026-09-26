defmodule MultiChainComparisonTest do
  use ExUnit.Case, async: true

  test "normalizes candidate evidence to the first trimmed line" do
    parent = self()
    program = comparison(parent)

    assert {:ok, prediction} =
             Imp.call(program, %{
               question: "choose",
               completions: [
                 %{
                   rationale: "  first reason  \nignored reason",
                   answer: "  alpha  \nignored answer"
                 },
                 %{"reasoning" => :fallback, "answer" => 42}
               ]
             })

    assert Imp.get(prediction, :answer) == "alpha"
    assert_received {:lm_call, messages, _opts}

    prompt = messages |> Enum.map(&Map.get(&1, :content, "")) |> Enum.join("\n")

    assert prompt =~ "«I'm trying to first reason I'm not sure but my prediction is alpha»"
    assert prompt =~ "«I'm trying to fallback I'm not sure but my prediction is 42»"
    refute prompt =~ "ignored reason"
    refute prompt =~ "ignored answer"
  end

  test "uses temperature 0.7 by default and preserves an explicit config value" do
    parent = self()

    assert {:ok, _prediction} = Imp.call(comparison(parent), comparison_inputs())
    assert_received {:lm_call, _messages, default_opts}
    assert default_opts[:temperature] == 0.7

    assert {:ok, _prediction} =
             Imp.call(comparison(parent, config: [temperature: 0.2]), comparison_inputs())

    assert_received {:lm_call, _messages, explicit_opts}
    assert explicit_opts[:temperature] == 0.2
  end

  test "keeps malformed completion entries non-crashing" do
    parent = self()

    assert {:ok, _prediction} =
             Imp.call(comparison(parent), %{
               question: "choose",
               completions: [nil, %{reasoning: %{step: 1}, answer: [{:alpha}]}]
             })

    assert_received {:lm_call, messages, _opts}
    prompt = messages |> Enum.map(&Map.get(&1, :content, "")) |> Enum.join("\n")
    assert prompt =~ "«I'm trying to  I'm not sure but my prediction is »"
    assert prompt =~ "%{step: 1}"
    assert prompt =~ "my prediction is [{:alpha}]»"
  end

  defp comparison(parent, opts \\ []) do
    lm =
      Imp.LM.Static.new(
        handler: fn messages, lm_opts ->
          send(parent, {:lm_call, messages, lm_opts})
          %{rationale: "selected", answer: "alpha"}
        end
      )

    Imp.multi_chain_comparison("question -> answer", Keyword.merge([lm: lm, m: 2], opts))
  end

  defp comparison_inputs do
    %{
      question: "choose",
      completions: [
        %{reasoning: "first", answer: "alpha"},
        %{reasoning: "second", answer: "beta"}
      ]
    }
  end
end
