defmodule Imp.Optimizer.GEPA.ComponentParityTest do
  use ExUnit.Case, async: false

  alias Imp.Optimizer.GEPA.{
    Adapter,
    Candidate,
    Engine,
    Evaluation,
    InstructionProposal,
    ModuleSelector,
    ProgramAdapter,
    Stopper
  }

  @python "tmp/dspy-parity-venv/bin/python"
  @dspy_source "tmp/dspy-3.2.1"
  @gepa_source "tmp/gepa-v0.1.4/src"
  @runner "test/support/dspy_3_2_1_gepa_component_tape.py"

  @tag :evidence_infrastructure
  @tag :requires_dspy_capture
  test "two named components match pinned feedback, reflection, rotation, and stopping" do
    python_path =
      [Path.expand(@dspy_source), Path.expand(@gepa_source)]
      |> Enum.join(":")

    {output, 0} =
      System.cmd(Path.expand(@python), [Path.expand(@runner)],
        env: [{"PYTHONPATH", python_path}],
        stderr_to_stdout: false
      )

    upstream = Jason.decode!(output)

    assert upstream["dspy_commit"] == "29448ae12756abdd14bd8796c819247ebb83673c"
    assert upstream["gepa_commit"] == "8b0ce6cd99a234f6b74daf37558a2ac0ce18f975"

    task_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          if Enum.any?(messages, &(to_string(&1.content) =~ "final_response")),
            do: %{reasoning: "review reasoning", final_response: "FINAL"},
            else: %{reasoning: "draft reasoning", response: "DRAFT"}
        end
      )

    program =
      Imp.BenchmarkTruth.IFBenchTwoStage.new(task_lm,
        adapter: Imp.Adapter.Chat,
        config: [json_fallback: false]
      )

    metric = fn _example, _prediction -> %{score: 0.25, feedback: "overall"} end

    component_feedback = %{
      generate_response_module: fn context ->
        %{feedback_text: "draft-feedback:#{context.predictor_output.response}"}
      end,
      ensure_correct_response_module: fn context ->
        %{feedback_text: "review-feedback:#{context.predictor_output.final_response}"}
      end
    }

    adapter =
      ProgramAdapter.new(program, metric,
        component_feedback: component_feedback,
        reflection_record_mode: :gepa_v0_1_4
      )

    candidate = Candidate.from_program(program)
    example = Imp.example(prompt: "Route request R17") |> Imp.with_inputs(:prompt)
    result = Evaluation.evaluate(adapter, [example], candidate, capture_traces: true)
    components = adapter.component_order
    dataset = Adapter.make_reflective_dataset(adapter, candidate, result, components)

    upstream_dataset = normalize_upstream_components(upstream["reflective_dataset"])
    assert stringify(dataset) == upstream_dataset

    field_orders =
      program
      |> Imp.ProgramParameters.predictors()
      |> Map.new(fn %{name: name, predictor: predictor} ->
        {name,
         %{
           "Inputs" => Enum.map(predictor.signature.inputs, &to_string(&1.name)),
           "Generated Outputs" => Enum.map(predictor.signature.outputs, &to_string(&1.name))
         }}
      end)

    prompts =
      Map.new(components, fn component ->
        [%{content: prompt}] =
          InstructionProposal.messages(
            Map.fetch!(candidate, component),
            Map.fetch!(dataset, component),
            nil,
            :gepa_v0_1_4,
            Map.fetch!(field_orders, component)
          )

        {to_string(component), prompt}
      end)

    assert prompts == normalize_upstream_components(upstream["reflection_prompts"])

    owner = self()

    reflection_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          send(owner, {:public_reflection, messages})
          "```replacement instruction```"
        end
      )

    optimizer =
      Imp.Optimizer.GEPA.new(metric,
        execution_profile: :gepa_v0_1_4,
        generations: 2,
        minibatch_size: 1,
        reflection_lm: reflection_lm,
        component_feedback: component_feedback
      )

    {_compiled, report} =
      Imp.Optimizer.GEPA.compile_with_report(optimizer, program, [example], [example])

    assert report.metadata.reflection_calls == 3

    public_prompts =
      for _ <- 1..3 do
        assert_receive {:public_reflection, [%{content: content}]}
        content
      end

    assert public_prompts ==
             upstream["round_robin"]
             |> Enum.take(3)
             |> Enum.map(&Map.fetch!(prompts, normalize_component(&1)))

    selector = ModuleSelector.ordered_round_robin(components)

    {selected, _entry} =
      Enum.map_reduce(1..5, %Engine.Entry{id: 0, candidate: candidate, validation: result}, fn _,
                                                                                               entry ->
        state = %Engine.State{budget: %{}, rng_state: %{}, candidates: [entry]}
        [selected] = ModuleSelector.select(selector, state, %{}, [], 0, candidate)
        {to_string(selected), %{entry | next_component: entry.next_component + 1}}
      end)

    assert selected == Enum.map(upstream["round_robin"], &normalize_component/1)

    policy = Stopper.max_metric_calls(80)
    stopper_state = Stopper.new(policy)

    decisions =
      Map.new([79, 80, 120], fn calls ->
        decision = Stopper.check(policy, stopper_state, %{metric_calls: calls})
        {Integer.to_string(calls), match?({:stop, _, _}, decision)}
      end)

    assert decisions == upstream["max_metric_calls_stops"]

    assert Imp.Optimizer.GEPA.v014_budget_envelope(32, 8, 80) == %{
             max_metric_calls: 120,
             max_reflection_calls: 12,
             max_iterations: 6
           }
  end

  defp normalize_upstream_components(map) do
    Map.new(map, fn {name, value} -> {normalize_component(name), value} end)
  end

  defp normalize_component(name), do: String.replace_suffix(name, ".predict", "")

  defp stringify(%_{} = struct), do: struct |> Map.from_struct() |> stringify()

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
