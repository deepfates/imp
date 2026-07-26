defmodule Imp.SingleFieldAdapterTest do
  use ExUnit.Case, async: true

  defmodule ChoiceLM do
    @behaviour Imp.LM
    defstruct [:owner]

    def response_format_capability(%__MODULE__{}),
      do: %Imp.LM.Capability{choice_values: true}

    def generate(%__MODULE__{owner: owner}, messages, opts) do
      send(owner, {:choice_request, messages, opts})
      {:ok, opts |> Keyword.fetch!(:allowed_values) |> hd()}
    end

    @impl true
    def generate(_messages, _opts), do: {:error, :instance_required}
  end

  defmodule SchemaLM do
    @behaviour Imp.LM
    defstruct [:owner]

    def response_format_capability(%__MODULE__{}),
      do: Imp.LM.Capability.json_schema()

    def generate(%__MODULE__{owner: owner}, messages, opts) do
      send(owner, {:schema_request, messages, opts})
      {:ok, %{"sentiment" => "positive"}}
    end

    @impl true
    def generate(_messages, _opts), do: {:error, :instance_required}
  end

  test "ordinary enum classifier renders a concise contract and parses only an exact value" do
    signature =
      Imp.signature(
        "utterance -> route: enum[R17,R42,R68,R93]",
        "Classify the customer request."
      )

    assert [
             %{role: :system, content: system},
             %{role: :user, content: "utterance: unfamiliar card payment"}
           ] =
             Imp.Adapter.SingleField.format(signature, %{utterance: "unfamiliar card payment"},
               demos: []
             )

    assert system =~ "Output value: route (Literal['R17', 'R42', 'R68', 'R93'])"
    assert system =~ "Return only the value for route"
    refute system =~ "[[ ##"

    assert {:ok, prediction} = Imp.Adapter.SingleField.parse(signature, "  R42\n", [])
    assert Imp.get(prediction, :route) == "R42"

    for malformed <- ["[R42]", "The answer is R42", ~s("R42"), ""] do
      assert {:error, _reason} = Imp.Adapter.SingleField.parse(signature, malformed, [])
    end
  end

  test "complete demonstrations use raw assistant values and partial demos fail loudly" do
    signature = Imp.signature("text -> sentiment: enum[positive,negative]", "Classify sentiment.")

    assert [
             %{role: :system},
             %{role: :user, content: "text: excellent"},
             %{role: :assistant, content: "positive"},
             %{role: :user, content: "text: awful"}
           ] =
             Imp.Adapter.SingleField.format(signature, %{text: "awful"},
               demos: [%{text: "excellent", sentiment: "positive"}]
             )

    assert_raise ArgumentError, ~r/demonstrations must be complete.*sentiment/s, fn ->
      Imp.Adapter.SingleField.format(signature, %{text: "awful"}, demos: [%{text: "excellent"}])
    end
  end

  test "multi-output programs are rejected before generation" do
    signature = Imp.signature("question -> answer, confidence: number")

    assert_raise ArgumentError, ~r/requires exactly one output field/, fn ->
      Imp.Adapter.SingleField.format(signature, %{question: "q"}, [])
    end

    assert_raise ArgumentError, ~r/requires exactly one output field/, fn ->
      Imp.Adapter.SingleField.parse(signature, "a", [])
    end
  end

  test "choice constraints are requested only from LMs that declare support" do
    signature = Imp.signature("text -> sentiment: enum[positive,negative]")

    assert Imp.Adapter.SingleField.lm_opts(signature, [], Imp.LM.Capability.none()) == []

    assert Imp.Adapter.SingleField.lm_opts(
             signature,
             [],
             %Imp.LM.Capability{choice_values: true}
           ) == [allowed_values: ["positive", "negative"]]
  end

  test "ordinary program calls bind declared enum choices only for capable LMs" do
    program =
      Imp.predict(
        Imp.signature("text -> sentiment: enum[positive,negative]", "Classify sentiment."),
        lm: %ChoiceLM{owner: self()},
        adapter: Imp.Adapter.SingleField
      )

    assert {:ok, prediction} = Imp.call(program, %{text: "excellent"})
    assert Imp.get(prediction, :sentiment) == "positive"

    assert_received {:choice_request, messages, [allowed_values: ["positive", "negative"]]}

    assert Enum.any?(messages, &String.contains?(&1.content, "positive"))
  end

  test "ordinary single-field programs use exact provider schemas without text repair" do
    program =
      Imp.predict(
        Imp.signature("text -> sentiment: enum[positive,negative]", "Classify sentiment."),
        lm: %SchemaLM{owner: self()},
        adapter: Imp.Adapter.SingleField,
        config: [json_fallback: false]
      )

    assert {:ok, prediction} = Imp.call(program, %{text: "excellent"})
    assert Imp.get(prediction, :sentiment) == "positive"

    assert_received {:schema_request, messages, opts}

    assert %{
             type: "json_schema",
             json_schema: %{name: "DSPyProgramOutputs", schema: schema, strict: true}
           } = opts[:response_format]

    assert schema["required"] == ["sentiment"]
    assert schema["properties"]["sentiment"]["enum"] == ["positive", "negative"]
    assert Enum.any?(messages, &String.contains?(&1.content, "Return only the value"))
  end

  test "adapter survives the public save/load boundary" do
    path =
      Path.join(System.tmp_dir!(), "imp-single-field-#{System.unique_integer([:positive])}.json")

    program =
      Imp.predict("utterance -> route: enum[R17,R42]", adapter: Imp.Adapter.SingleField)

    on_exit(fn -> File.rm(path) end)

    assert :ok = Imp.save!(program, path)
    loaded = Imp.load!(path)
    assert loaded.adapter == Imp.Adapter.SingleField

    assert [_, %{role: :user, content: "utterance: pending"}] =
             Imp.Adapter.SingleField.format(loaded.signature, %{utterance: "pending"}, [])
  end
end
