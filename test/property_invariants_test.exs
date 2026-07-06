defmodule PropertyInvariantsTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  setup_all do
    _ = DSEx.Sandbox.eval("warmup_identifier", %{})
    _ = DSEx.Sandbox.eval("x + 1", %{"x" => 1})
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
    gen all(
          inputs <- uniq_list_of(field_spec(), min_length: 1, max_length: 3),
          outputs <- uniq_list_of(field_spec(), min_length: 1, max_length: 3)
        ) do
      Enum.join(inputs, ", ") <> " -> " <> Enum.join(outputs, ", ")
    end
  end

  property "signature dump/load round-trips the serialized contract" do
    check all(spec <- signature_spec(), max_runs: 100) do
      signature = DSEx.signature(spec)
      loaded = signature |> DSEx.Signature.dump() |> DSEx.Signature.load()

      assert DSEx.Signature.dump(loaded) == DSEx.Signature.dump(signature)
      assert DSEx.Signature.input_names(loaded) == DSEx.Signature.input_names(signature)
      assert DSEx.Signature.output_names(loaded) == DSEx.Signature.output_names(signature)
    end
  end

  property "JSON adapter accepts schema-shaped maps and preserves typed outputs" do
    signature = DSEx.signature("question -> answer: string, score: int, ok: bool")

    check all(
            answer <- string(:printable, min_length: 1, max_length: 40),
            score <- integer(-100..100),
            ok <- boolean(),
            max_runs: 100
          ) do
      assert {:ok, prediction} =
               DSEx.Adapter.JSON.parse(
                 signature,
                 %{
                   "answer" => answer,
                   "score" => score,
                   "ok" => ok
                 },
                 []
               )

      assert DSEx.Prediction.get(prediction, :answer) == answer
      assert DSEx.Prediction.get(prediction, :score) == score
      assert DSEx.Prediction.get(prediction, :ok) == ok
    end
  end

  property "Predict save/load preserves serializable program state" do
    check all(spec <- signature_spec(), max_runs: 50) do
      program =
        spec
        |> DSEx.predict(
          lm: DSEx.req_llm("openai:gpt-test", temperature: 0),
          adapter: DSEx.Adapter.JSON,
          demos: [DSEx.example(%{question: "q", answer: "a"})],
          metadata: %{"source" => "property"}
        )

      loaded = program |> DSEx.Saving.dump() |> DSEx.Saving.load()

      assert DSEx.Saving.dump(loaded) == DSEx.Saving.dump(program)
    end
  end

  property "metric normalization keeps numeric scores and pass state coherent" do
    check all(
            value <- one_of([boolean(), integer(-5..5), float(min: -5.0, max: 5.0)]),
            max_runs: 100
          ) do
      result = DSEx.Metrics.normalize_result(value)

      assert is_float(result.score)
      assert result.passed? == result.score > 0
    end
  end

  property "sandbox rejects unknown generated identifiers without interning atoms" do
    check all(suffix <- string(:alphanumeric, min_length: 8, max_length: 24), max_runs: 100) do
      unknown = "dsex_unknown_prop_" <> suffix

      refute_existing_atom(unknown)
      before_count = :erlang.system_info(:atom_count)

      assert {:error, {:unknown_variable, ^unknown}} = DSEx.Sandbox.eval(unknown, %{})
      assert :erlang.system_info(:atom_count) == before_count
      refute_existing_atom(unknown)
    end
  end

  defp refute_existing_atom(name) do
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end
end
