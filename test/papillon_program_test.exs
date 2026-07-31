defmodule Imp.BenchmarkTruth.PapillonProgramTest do
  use ExUnit.Case, async: true

  alias Imp.BenchmarkTruth.Papillon
  alias Imp.ProgramParameters

  defmodule SafetyLM do
    defstruct [:error]

    def generate(%__MODULE__{error: error}, _messages, _opts), do: {:error, error}
    def generate(_messages, _opts), do: {:error, :instance_required}
  end

  test "constructs the source-faithful ChainOfThought and Predict stages" do
    program = Papillon.new(static_lm(fn _messages -> "external" end))

    assert %Imp.Predict.ChainOfThought{} = program.craft_redacted_request
    assert %Imp.Predict.Predict{} = program.respond_to_query

    craft = program.craft_redacted_request.predict.signature
    assert Imp.Signature.input_names(craft) == [:user_query]
    assert Imp.Signature.output_names(craft) == [:reasoning, :llm_request]
    assert craft.instructions =~ "privacy-preserving request"

    respond = program.respond_to_query.signature

    assert Imp.Signature.input_names(respond) == [
             :related_llm_request,
             :related_llm_response,
             :user_query
           ]

    assert Imp.Signature.output_names(respond) == [:response]
    refute :reasoning in Imp.Signature.output_names(respond)

    assert Enum.find(respond.inputs, &(&1.name == :related_llm_response)).desc ==
             "information from a powerful LLM responding to a related request"
  end

  test "delegates through a separate untrusted LM and returns all three outputs" do
    owner = self()

    trusted_lm =
      static_lm(fn messages ->
        prompt = prompt(messages)
        send(owner, {:trusted_prompt, prompt})

        if prompt =~ "related_llm_response" do
          %{response: "Final private answer"}
        else
          %{reasoning: "Remove private details", llm_request: "Explain account recovery"}
        end
      end)

    untrusted_lm =
      static_lm(fn messages ->
        send(owner, {:untrusted_messages, messages})
        "Use the provider's recovery form"
      end)

    program = Papillon.new(untrusted_lm, lm: trusted_lm)

    assert {:ok, prediction} =
             Imp.Module.call(program, %{"user_query" => "Recover alice@example.com's account"})

    assert Imp.Prediction.to_map(prediction) == %{
             llm_request: "Explain account recovery",
             llm_response: "Use the provider's recovery form",
             response: "Final private answer"
           }

    assert_received {:untrusted_messages, [%{role: :user, content: "Explain account recovery"}]}

    assert_received {:trusted_prompt, craft_prompt}
    assert craft_prompt =~ "alice@example.com"
    assert_received {:trusted_prompt, respond_prompt}
    assert respond_prompt =~ "Use the provider's recovery form"
  end

  test "exposes independently mutable source-named optimizer parameters" do
    program = Papillon.new(static_lm(fn _messages -> "external" end))

    assert Enum.map(ProgramParameters.predictors(program), & &1.name) == [
             :craft_redacted_request,
             :respond_to_query
           ]

    updated =
      program
      |> ProgramParameters.put_instruction(:craft_redacted_request, "Redact exactly.")
      |> ProgramParameters.put_instruction(:respond_to_query, "Answer exactly.")

    assert updated.craft_redacted_request.predict.signature.instructions == "Redact exactly."
    assert updated.respond_to_query.signature.instructions == "Answer exactly."
  end

  test "returns source-compatible empty outputs with reconstructable stage diagnostics" do
    craft_failure =
      Papillon.new(static_lm(fn _messages -> "unused" end),
        lm: static_lm(fn _messages -> raise "craft failed" end)
      )

    untrusted_failure =
      Papillon.new(static_lm(fn _messages -> raise "untrusted failed" end),
        lm: trusted_success_lm()
      )

    respond_failure =
      Papillon.new(static_lm(fn _messages -> "external answer" end),
        lm:
          static_lm(fn messages ->
            if prompt(messages) =~ "related_llm_response" do
              raise "respond failed"
            else
              %{reasoning: "redact", llm_request: "safe request"}
            end
          end)
      )

    missing_input =
      Papillon.new(static_lm(fn _messages -> "external" end), lm: trusted_success_lm())

    for {program, inputs, stage} <- [
          {craft_failure, %{user_query: "private"}, :craft_redacted_request},
          {untrusted_failure, %{user_query: "private"}, :untrusted_model},
          {respond_failure, %{user_query: "private"}, :respond_to_query},
          {missing_input, %{}, :input}
        ] do
      assert {:ok, prediction} = Imp.Module.call(program, inputs)
      assert Imp.Prediction.to_map(prediction) == empty_fields()
      assert %{stage: ^stage, reason: reason} = prediction.metadata.papillon_failure
      refute is_nil(reason)
    end
  end

  test "operational safety remains fatal across every task stage" do
    safety = Imp.OperationalSafetyError.exception(kind: :budget, reason: :exhausted)

    program = Papillon.new(%SafetyLM{error: safety}, lm: trusted_success_lm())

    example =
      Imp.example(user_query: "private", target_response: "unused")
      |> Imp.with_inputs(:user_query)

    assert_raise Imp.OperationalSafetyError, fn ->
      Imp.Evaluate.new([example], fn _example, _prediction -> 1.0 end, max_errors: :infinity)
      |> Imp.Evaluate.run(program)
    end
  end

  test "public GEPA builds component-scoped reflection records for both predictors" do
    owner = self()
    program = Papillon.new(static_lm(fn _messages -> "external" end), lm: trusted_success_lm())

    example =
      Imp.example(
        user_query: "Recover access",
        target_response: "final",
        pii_str: ""
      )
      |> Imp.with_inputs(:user_query)

    proposer = fn candidate, records, components ->
      send(owner, {:papillon_reflection, components, records})
      %{new_texts: Map.new(components, &{&1, Map.fetch!(candidate, &1) <> " Improved."})}
    end

    {_selected, report} =
      Imp.Optimizer.GEPA.new(fn _example, _prediction -> 0.0 end,
        generations: 2,
        minibatch_size: 1,
        module_selector: :round_robin,
        reflection_strategy: proposer
      )
      |> Imp.Optimizer.GEPA.compile_with_report(program, [example], [example])

    reflected =
      for _ <- 1..2 do
        assert_receive {:papillon_reflection, [component], records}
        assert %{^component => [record]} = records
        assert is_map(record)
        component
      end

    assert reflected == [:craft_redacted_request, :respond_to_query]
    assert report.metadata.reflection_calls == 2
  end

  defp trusted_success_lm do
    static_lm(fn messages ->
      if prompt(messages) =~ "related_llm_response" do
        %{response: "final"}
      else
        %{reasoning: "redact", llm_request: "safe request"}
      end
    end)
  end

  defp static_lm(handler) do
    %{
      module: Imp.LM.Static,
      opts: [handler: fn messages, _opts -> handler.(messages) end]
    }
  end

  defp prompt(messages), do: Enum.map_join(messages, "\n", &Map.get(&1, :content, ""))

  defp empty_fields, do: %{llm_request: "", llm_response: "", response: ""}
end
