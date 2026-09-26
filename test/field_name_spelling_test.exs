defmodule FieldNameSpellingTest do
  @moduledoc """
  A field name written in the string syntax is an atom only when that atom
  already exists, and a string otherwise. Each test here parses a name no code
  has made an atom, so the signature holds a string, and then uses the atom
  spelling (created afterwards) for an option or a key. Behaviour must not
  change with the spelling.
  """

  use ExUnit.Case, async: true

  alias Imp.Predict.{Avatar, MultiChainComparison, ProgramOfThought, ReActV2, RLM}

  # A name no module or earlier test has turned into an atom.
  defp fresh(prefix) do
    name = "#{prefix}_#{System.unique_integer([:positive])}_spelled"

    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    name
  end

  defp string_signature(input, output) do
    signature = Imp.signature("#{input} -> #{output}")
    assert Imp.Signature.input_names(signature) == [input]
    assert Enum.map(Imp.Signature.output_names(signature), &to_string/1) == [output]
    signature
  end

  defp static_lm(handler), do: %{module: Imp.LM.Static, opts: [handler: handler]}

  defp prompt(messages), do: Enum.map_join(messages, "\n", &to_string(&1.content))

  test "ProgramOfThought accepts the atom spelling of a string output as :output_field" do
    input = fresh("pot_in")
    output = fresh("pot_out")
    signature = string_signature(input, output)

    pot = ProgramOfThought.new(signature, output_field: String.to_atom(output))

    assert pot.output_field == output
  end

  # A program saved where the atom existed stores the name as an atom tag; a
  # fresh VM that parses the signature again holds the name as a string.
  defp saved_atom(name), do: %{"__imp_type__" => "atom", "value" => name}

  test "a saved ProgramOfThought loads when its output field was saved as an atom" do
    input = fresh("saved_pot_in")
    output = fresh("saved_pot_out")
    state = input |> string_signature(output) |> ProgramOfThought.new() |> Imp.Saving.dump()

    loaded = state |> Map.put("output_field", saved_atom(output)) |> Imp.Saving.load()

    assert loaded.output_field == output
  end

  test "a saved MultiChainComparison loads when its last key was saved as an atom" do
    input = fresh("mcc_in")
    output = fresh("mcc_out")

    state =
      input |> string_signature(output) |> MultiChainComparison.new(m: 2) |> Imp.Saving.dump()

    loaded = state |> Map.put("last_key", saved_atom(output)) |> Imp.Saving.load()

    assert loaded.last_key == output
  end

  test "RLM finds a required string input given under its atom spelling" do
    input = fresh("rlm_in")
    signature = string_signature(input, "answer")

    lm =
      static_lm(fn _messages, _opts ->
        %{reasoning: "read it", code: ~s|submit(%{answer: load("#{input}")})|}
      end)

    rlm = RLM.new(signature, lm: lm, max_iterations: 2)

    assert {:ok, prediction} = RLM.call(rlm, %{String.to_atom(input) => "needle"})
    assert Imp.get(prediction, :answer) == "needle"
  end

  test "ReActV2 passes a string input given under its atom spelling to the model" do
    input = fresh("react_in")
    signature = string_signature(input, "answer")
    parent = self()

    lm =
      static_lm(fn messages, _opts ->
        send(parent, {:react_prompt, prompt(messages)})
        "done"
      end)

    react = ReActV2.new(signature, [], lm: lm, max_iters: 1)

    assert {:ok, _prediction} = Imp.call(react, %{String.to_atom(input) => "needle-value"})
    assert_receive {:react_prompt, prompt}
    assert prompt =~ "needle-value"
  end

  test "Avatar accepts a required string input given under its atom spelling" do
    input = fresh("avatar_in")
    signature = string_signature(input, "answer")

    lm =
      static_lm(fn messages, _opts ->
        if prompt(messages) =~ "Do not request another tool.",
          do: %{answer: "finished"},
          else: %{action: %{tool_name: "Finish", tool_input_query: %{}}}
      end)

    avatar = Avatar.new(signature, [], lm: lm, max_iters: 1)

    assert {:ok, prediction} = Imp.call(avatar, %{String.to_atom(input) => "needle"})
    assert Imp.get(prediction, :answer) == "finished"
  end

  test "the single-field adapter renders a string input given under its atom spelling" do
    input = fresh("single_in")
    output = fresh("single_out")
    signature = string_signature(input, output)

    messages =
      Imp.Adapter.SingleField.format(signature, %{String.to_atom(input) => "needle"}, [])

    assert prompt(messages) =~ "#{input}: needle"
  end

  test "the chat adapter reads a string output returned under its atom spelling" do
    input = fresh("chat_in")
    output = fresh("chat_out")
    signature = string_signature(input, output)

    assert {:ok, prediction} =
             Imp.Adapter.Chat.parse(signature, %{String.to_atom(output) => "value"}, [])

    assert Imp.get(prediction, output) == "value"
  end

  test "the JSON adapter reads a string output returned under its atom spelling" do
    input = fresh("json_in")
    output = fresh("json_out")
    signature = string_signature(input, output)

    assert {:ok, prediction} =
             Imp.Adapter.JSON.parse(signature, %{String.to_atom(output) => "value"}, [])

    assert Imp.get(prediction, output) == "value"
  end

  test "majority voting reads a string field from atom-keyed maps" do
    field = fresh("vote")
    key = String.to_atom(field)

    assert Imp.Predict.Aggregation.majority([%{key => "a"}, %{key => "b"}, %{key => "a"}],
             field: field
           ) == "a"
  end

  # `:hint_` exists once Refine is loaded, so a signature parsed earlier holds
  # the name as a string; build that signature directly.
  test "Refine passes its advice to a string hint_ input the caller also filled" do
    signature = Imp.signature("question, hint_ -> answer")

    signature = %{
      signature
      | inputs: Enum.map(signature.inputs, &%{&1 | name: to_string(&1.name)})
    }

    parent = self()

    lm =
      static_lm(fn messages, _opts ->
        send(parent, {:prompt, prompt(messages)})
        %{answer: "bad"}
      end)

    refine =
      Imp.Predict.Refine.new(Imp.Predict.Predict.new(signature, lm: lm), fn _, _ -> false end,
        max_attempts: 2,
        feedback_fn: fn _history -> "repair advice" end
      )

    Imp.Predict.Refine.call(refine, %{"question" => "q", "hint_" => "caller hint"})

    assert_received {:prompt, first}
    assert_received {:prompt, second}
    assert first =~ "caller hint"
    assert second =~ "repair advice"
    refute second =~ "caller hint"
  end
end
