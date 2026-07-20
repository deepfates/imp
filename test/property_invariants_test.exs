defmodule PropertyInvariantsTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  setup_all do
    _ = Imp.Sandbox.eval("warmup_identifier", %{})
    _ = Imp.Sandbox.eval("x + 1", %{"x" => 1})
    :ok
  end

  defp identifier do
    gen all(
          prefix <- string([?a..?z], length: 1),
          rest <- string([?a..?z, ?0..?9, ?_], max_length: 8)
        ) do
      prefix <> rest
    end
  end

  defp field_type do
    member_of(["string", "int", "number", "float", "bool", "array[string]"])
  end

  defp field_spec do
    gen all(name <- identifier(), type <- field_type()) do
      "#{name}: #{type}"
    end
  end

  defp signature_spec do
    # Names must be distinct ACROSS the arrow too: duplicate input/output
    # names now raise, matching upstream (dee-1nkd; the raise itself is
    # covered by the ported upstream test). A round-trip property should
    # generate valid signatures, so uniqueness is enforced over the union.
    gen all(
          names <- uniq_list_of(identifier(), min_length: 2, max_length: 6),
          types <- list_of(field_type(), length: length(names)),
          split <- integer(1..(length(names) - 1))
        ) do
      fields = Enum.zip_with(names, types, fn name, type -> "#{name}: #{type}" end)
      {inputs, outputs} = Enum.split(fields, split)
      Enum.join(inputs, ", ") <> " -> " <> Enum.join(outputs, ", ")
    end
  end

  property "signature dump/load round-trips the serialized contract" do
    check all(spec <- signature_spec(), max_runs: 100) do
      signature = Imp.signature(spec)
      loaded = signature |> Imp.Signature.dump() |> Imp.Signature.load()

      assert Imp.Signature.dump(loaded) == Imp.Signature.dump(signature)
      assert Imp.Signature.input_names(loaded) == Imp.Signature.input_names(signature)
      assert Imp.Signature.output_names(loaded) == Imp.Signature.output_names(signature)
    end
  end

  property "JSON adapter accepts schema-shaped maps and preserves typed outputs" do
    signature = Imp.signature("question -> answer: string, score: int, ok: bool")

    check all(
            answer <- string(:printable, min_length: 1, max_length: 40),
            score <- integer(-100..100),
            ok <- boolean(),
            max_runs: 100
          ) do
      assert {:ok, prediction} =
               Imp.Adapter.JSON.parse(
                 signature,
                 %{
                   "answer" => answer,
                   "score" => score,
                   "ok" => ok
                 },
                 []
               )

      assert Imp.Prediction.get(prediction, :answer) == answer
      assert Imp.Prediction.get(prediction, :score) == score
      assert Imp.Prediction.get(prediction, :ok) == ok
    end
  end

  property "Predict save/load preserves serializable program state" do
    check all(spec <- signature_spec(), max_runs: 50) do
      program =
        spec
        |> Imp.predict(
          lm: Imp.req_llm("openai:gpt-test", temperature: 0),
          adapter: Imp.Adapter.JSON,
          demos: [Imp.example(%{question: "q", answer: "a"})],
          metadata: %{"source" => "property"}
        )

      loaded = program |> Imp.Saving.dump() |> Imp.Saving.load()

      assert Imp.Saving.dump(loaded) == Imp.Saving.dump(program)
    end
  end

  property "metric normalization keeps numeric scores and pass state coherent" do
    check all(
            value <- one_of([boolean(), integer(-5..5), float(min: -5.0, max: 5.0)]),
            max_runs: 100
          ) do
      result = Imp.Metrics.normalize_result(value)

      assert is_float(result.score)
      assert result.passed? == result.score > 0
    end
  end

  property "sandbox rejects unknown generated identifiers without interning atoms" do
    check all(suffix <- string(:alphanumeric, min_length: 8, max_length: 24), max_runs: 100) do
      unknown = "imp_unknown_prop_" <> suffix

      refute_existing_atom(unknown)
      before_count = :erlang.system_info(:atom_count)

      assert {:error, {:unknown_variable, ^unknown}} = Imp.Sandbox.eval(unknown, %{})
      assert :erlang.system_info(:atom_count) == before_count
      refute_existing_atom(unknown)
    end
  end

  defp refute_existing_atom(name) do
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end
end
