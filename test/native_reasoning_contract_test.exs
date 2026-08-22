defmodule Imp.NativeReasoningContractTest do
  use ExUnit.Case, async: true

  alias Imp.Adapter.Types.Reasoning

  defmodule NativeLM do
    defstruct [:owner, :supported?, opts: []]

    def response_format_capability(_lm), do: Imp.LM.Capability.none()
    def reasoning_capability(%__MODULE__{supported?: supported?}), do: supported?
    def configured_option(%__MODULE__{opts: opts}, key), do: Keyword.fetch(opts, key)

    def generate(%__MODULE__{owner: owner, supported?: true}, messages, opts) do
      send(owner, {:request, messages, opts})

      result = fn index ->
        %{
          __imp_lm_output__: %{"answer" => "Paris #{index}"},
          __imp_lm_metadata__: %{native_reasoning: "follow clue #{index}"}
        }
      end

      case Keyword.get(opts, :n, 1) do
        1 -> {:ok, result.(1)}
        n -> {:ok, Enum.map(1..n, result)}
      end
    end

    def generate(%__MODULE__{owner: owner}, messages, opts) do
      send(owner, {:request, messages, opts})
      {:ok, %{"reasoning" => "recall the capital", "answer" => "Paris"}}
    end
  end

  test "a capable LM supplies a typed reasoning field without asking for it as text" do
    lm = %NativeLM{owner: self(), supported?: true}

    program =
      Imp.chain_of_thought("question -> answer",
        lm: lm,
        adapter: Imp.Adapter.JSON,
        rationale_field_type: :reasoning
      )

    assert {:ok, prediction} = Imp.call(program, %{question: "Capital of France?"})
    assert %Reasoning{text: "follow clue 1"} = Imp.get(prediction, :reasoning)
    assert Imp.get(prediction, :answer) == "Paris 1"

    assert_received {:request, messages, opts}
    rendered = inspect(messages)
    refute rendered =~ "reasoning"
    assert rendered =~ "answer"
    assert Keyword.fetch!(opts, :reasoning_effort) == "low"
  end

  test "native reasoning remains paired with each multi-completion result" do
    lm = %NativeLM{owner: self(), supported?: true}

    program =
      Imp.chain_of_thought("question -> answer",
        lm: lm,
        adapter: Imp.Adapter.JSON,
        rationale_field_type: :reasoning,
        config: [n: 2]
      )

    assert {:ok, prediction} = Imp.call(program, %{question: "Capital of France?"})
    assert Enum.map(prediction.completions, &Imp.get(&1, :answer)) == ["Paris 1", "Paris 2"]

    assert Enum.map(prediction.completions, &Imp.get(&1, :reasoning)) == [
             %Reasoning{text: "follow clue 1"},
             %Reasoning{text: "follow clue 2"}
           ]
  end

  test "an incapable LM keeps reasoning in the rendered contract and coerces text" do
    lm = %NativeLM{owner: self(), supported?: false}

    program =
      Imp.chain_of_thought("question -> answer",
        lm: lm,
        adapter: Imp.Adapter.JSON,
        rationale_field_type: :reasoning
      )

    assert {:ok, prediction} = Imp.call(program, %{question: "Capital of France?"})
    assert %Reasoning{text: "recall the capital"} = Imp.get(prediction, :reasoning)

    assert_received {:request, messages, opts}
    assert inspect(messages) =~ "reasoning"
    refute Keyword.has_key?(opts, :reasoning_effort)
  end

  test "an explicit nil effort disables native reasoning even on a capable LM" do
    lm = %NativeLM{owner: self(), supported?: true}

    program =
      Imp.chain_of_thought("question -> answer",
        lm: lm,
        adapter: Imp.Adapter.JSON,
        rationale_field_type: :reasoning,
        config: [reasoning_effort: nil]
      )

    # The fixture's native branch intentionally omits the manual field. If Imp
    # really keeps the ordinary contract, parsing must fail loudly.
    assert {:error, %{reason: {:error, {:missing_output_fields, [:reasoning]}}}} =
             Imp.call(program, %{question: "Capital of France?"})

    assert_received {:request, messages, opts}
    assert inspect(messages) =~ "reasoning"
    assert Keyword.fetch!(opts, :reasoning_effort) == nil
  end

  test "a configured LM effort is respected when the call does not override it" do
    lm = %NativeLM{owner: self(), supported?: true, opts: [reasoning_effort: "high"]}

    program =
      Imp.chain_of_thought("question -> answer",
        lm: lm,
        adapter: Imp.Adapter.JSON,
        rationale_field_type: :reasoning
      )

    assert {:ok, _prediction} = Imp.call(program, %{question: "Capital of France?"})
    assert_received {:request, _messages, opts}
    assert Keyword.fetch!(opts, :reasoning_effort) == "high"
  end

  test "reasoning formats and JSON-encodes as content without leaking metadata" do
    reasoning = %Reasoning{text: "compact plan", metadata: %{private: "do not serialize"}}
    assert to_string(reasoning) == "compact plan"
    assert Jason.encode!(reasoning) == ~s("compact plan")
  end

  test "ChainOfThought preserves DSPy's string default and custom rationale precedence" do
    default = Imp.chain_of_thought("question -> answer")
    assert [%{name: :reasoning, type: :string} | _] = default.predict.signature.outputs

    custom =
      Imp.chain_of_thought("question -> answer",
        rationale_field: %{desc: "Show the decisive evidence", type: :reasoning},
        rationale_field_type: :string
      )

    assert [%{name: :reasoning, type: :reasoning, desc: "Show the decisive evidence"} | _] =
             custom.predict.signature.outputs
  end
end
