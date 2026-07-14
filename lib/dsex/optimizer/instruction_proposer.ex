defmodule DSEx.Optimizer.InstructionProposer do
  @moduledoc "LM-backed instruction proposal engine shared by prompt optimizers."

  def propose(program, trainset, opts \\ []) do
    count = Keyword.get(opts, :count, 5)
    fallback = fallback_candidates(program, trainset, opts)

    case Keyword.get(opts, :lm) || Keyword.get(opts, :proposer_lm) do
      nil ->
        fallback

      lm ->
        propose_with_lm(lm, program, trainset, opts, count, fallback)
    end
  end

  def propose_with_report(program, trainset, opts \\ []) do
    count = Keyword.get(opts, :count, 5)
    fallback = fallback_candidates(program, trainset, opts)

    case Keyword.get(opts, :lm) || Keyword.get(opts, :proposer_lm) do
      nil ->
        {fallback_slots(fallback, count, opts),
         %{status: :fallback, calls: 0, errors: [:proposal_lm_not_configured]}}

      lm ->
        proposal_indices(count)
        |> Enum.map_reduce(%{calls: 0, errors: []}, fn index, metadata ->
          proposal_opts =
            opts
            |> Keyword.update(:seed, index, &(&1 + index))
            |> Keyword.put(:proposal_index, index)
            |> Keyword.put(:demos, proposal_demos(opts, index))

          result =
            DSEx.LM.generate(
              lm,
              messages(program, trainset, proposal_opts),
              rollout_id: Keyword.get(proposal_opts, :seed, index),
              temperature: Keyword.get(opts, :temperature, 1.0)
            )

          case DSEx.LM.Result.unwrap(result) do
            {:ok, raw} ->
              case parse(raw, 1, []) do
                [instruction | _] ->
                  {instruction, %{metadata | calls: metadata.calls + 1}}

                [] ->
                  {fallback_at(fallback, index),
                   %{
                     metadata
                     | calls: metadata.calls + 1,
                       errors: metadata.errors ++ [{:invalid_proposal, index}]
                   }}
              end

            {:error, reason} ->
              {fallback_at(fallback, index),
               %{
                 metadata
                 | calls: metadata.calls + 1,
                   errors: metadata.errors ++ [{:proposal_lm_error, index, reason}]
               }}
          end
        end)
        |> then(fn {candidates, metadata} ->
          status = if metadata.errors == [], do: :ok, else: :with_fallbacks

          candidates =
            if Keyword.get(opts, :preserve_slots, false),
              do: candidates,
              else: Enum.uniq(candidates)

          {candidates, Map.put(metadata, :status, status)}
        end)
    end
  rescue
    error ->
      {fallback_slots(
         fallback_candidates(program, trainset, opts),
         Keyword.get(opts, :count, 5),
         opts
       ),
       %{status: :fallback, calls: 0, errors: [{:proposal_exception, Exception.message(error)}]}}
  catch
    kind, reason ->
      {fallback_slots(
         fallback_candidates(program, trainset, opts),
         Keyword.get(opts, :count, 5),
         opts
       ), %{status: :fallback, calls: 0, errors: [{:proposal_throw, kind, reason}]}}
  end

  @doc false
  def grounded_demo_rotation(demo_sets, proposal_index, max_examples \\ 3)

  def grounded_demo_rotation(_demo_sets, 0, _max_examples), do: []

  def grounded_demo_rotation(demo_sets, proposal_index, max_examples)
      when is_list(demo_sets) and demo_sets != [] and is_integer(proposal_index) and
             proposal_index > 0 and is_integer(max_examples) and max_examples >= 0 do
    demo_sets
    |> rotate(proposal_index)
    |> List.flatten()
    |> Enum.take(max_examples)
  end

  def grounded_demo_rotation(_demo_sets, _proposal_index, _max_examples), do: []

  defp propose_with_lm(lm, program, trainset, opts, count, fallback) do
    lm
    |> DSEx.LM.generate(messages(program, trainset, opts), [])
    |> DSEx.LM.Result.unwrap()
    |> case do
      {:ok, raw} -> parse(raw, count, fallback)
      {:error, _reason} -> fallback
    end
  rescue
    _error -> fallback
  catch
    _kind, _reason -> fallback
  end

  defp messages(program, trainset, opts) do
    scored_examples =
      opts
      |> Keyword.get(:scores, [])
      |> Enum.map(&inspect/1)
      |> Enum.join("\n")

    [
      %{
        role: :system,
        content:
          "Propose DSEx instruction candidates. Return JSON list of strings or newline-separated instructions."
      },
      %{
        role: :user,
        content:
          program
          |> prompt_payload(trainset, scored_examples, opts)
          |> Jason.encode!()
      }
    ]
  end

  defp prompt_payload(program, trainset, scored_examples, opts) do
    payload = %{
      current_instruction: DSEx.Optimizer.InstructionSearch.current_instruction(program),
      predictor_name: Keyword.get(opts, :predictor_name, :main),
      proposal_index: Keyword.get(opts, :proposal_index, 0),
      scored_examples: scored_examples
    }

    payload
    |> maybe_put(
      :program,
      Keyword.get(opts, :program_aware, true),
      program_context(Keyword.get(opts, :program_context, program))
    )
    |> maybe_put(
      :train_examples,
      Keyword.get(opts, :data_aware, true),
      data_context(trainset, opts)
    )
    |> maybe_put(
      :demonstrations,
      Keyword.get(opts, :fewshot_aware, true),
      demo_context(Keyword.get(opts, :demos, []))
    )
    |> maybe_put(:prompting_tip, Keyword.get(opts, :tip_aware, true), tip(opts))
  end

  defp program_context(program) do
    module = Map.get(program, :__struct__)

    %{
      module: inspect(module),
      source: module_source(module),
      structure: program |> Map.from_struct() |> Map.keys() |> Enum.sort(),
      predictors:
        Enum.map(DSEx.ProgramParameters.predictors(program), fn entry ->
          %{
            name: entry.name,
            signature: signature_spec(entry.predictor.signature),
            instructions: entry.predictor.signature.instructions
          }
        end),
      signature: signature_spec(DSEx.ProgramAccess.task_signature(program)),
      lm_signature: signature_spec(DSEx.ProgramAccess.lm_signature(program))
    }
  end

  defp module_source(module) when is_atom(module) do
    source = module.module_info(:compile)[:source]

    if source && File.regular?(source) do
      source |> File.read!() |> String.slice(0, 20_000)
    else
      nil
    end
  rescue
    _error -> nil
  end

  defp module_source(_module), do: nil

  defp data_context(trainset, opts) do
    count = Keyword.get(opts, :view_data_batch_size, 10)
    seed = Keyword.get(opts, :seed, 0)

    trainset
    |> Enum.to_list()
    |> seeded_take(count, seed)
    |> Enum.map(&normalize_example/1)
  end

  defp demo_context(demos), do: Enum.map(demos, &normalize_example/1)

  defp proposal_demos(opts, 0) do
    if Keyword.has_key?(opts, :demo_sets), do: [], else: Keyword.get(opts, :demos, [])
  end

  defp proposal_demos(opts, index) do
    case Keyword.get(opts, :demo_sets) do
      sets when is_list(sets) and sets != [] ->
        grounded_demo_rotation(sets, index, Keyword.get(opts, :num_demos_in_context, 3))

      _ ->
        Keyword.get(opts, :demos, [])
    end
  end

  defp rotate(values, index) do
    offset = rem(index, length(values))
    {before, after_offset} = Enum.split(values, offset)
    after_offset ++ before
  end

  defp normalize_example(%DSEx.Example{} = example), do: DSEx.Example.to_map(example)
  defp normalize_example(example) when is_map(example), do: example
  defp normalize_example(example), do: inspect(example)

  defp tip(opts) do
    tips = [
      "Be creative while remaining faithful to the output contract.",
      "Be concise and avoid unnecessary intermediate prose.",
      "Use the observed task structure and demonstrations.",
      "Make the instruction robust to difficult or atypical inputs."
    ]

    {tip, _state} =
      DSEx.Optimizer.Sampling.choose(
        tips,
        DSEx.Optimizer.Sampling.new(Keyword.get(opts, :seed, 0))
      )

    tip
  end

  defp seeded_take(_values, count, _seed) when count <= 0, do: []
  defp seeded_take(values, count, _seed) when length(values) <= count, do: values

  defp seeded_take(values, count, seed) do
    {values, _state} =
      DSEx.Optimizer.Sampling.shuffle(values, DSEx.Optimizer.Sampling.new(seed))

    Enum.take(values, count)
  end

  defp maybe_put(payload, _key, false, _value), do: payload
  defp maybe_put(payload, key, true, value), do: Map.put(payload, key, value)

  defp proposal_indices(count) when count > 0, do: 0..(count - 1)
  defp proposal_indices(_count), do: []

  defp fallback_at([], _index), do: "Complete the task."
  defp fallback_at(fallback, index), do: Enum.at(fallback, rem(index, length(fallback)))

  defp fallback_slots(fallback, count, opts) do
    if Keyword.get(opts, :preserve_slots, false) do
      Enum.map(proposal_indices(count), &fallback_at(fallback, &1))
    else
      Enum.take(fallback, count)
    end
  end

  defp parse(raw, count, fallback) when is_list(raw) do
    raw |> Enum.map(&to_string/1) |> clean(count, fallback)
  end

  defp parse(%{"instructions" => instructions}, count, fallback),
    do: parse(instructions, count, fallback)

  defp parse(%{instructions: instructions}, count, fallback),
    do: parse(instructions, count, fallback)

  defp parse(raw, count, fallback) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} ->
        parse(decoded, count, fallback)

      {:error, _} ->
        raw
        |> String.split(["\n", "\r"], trim: true)
        |> Enum.map(&String.trim_leading(&1, "- "))
        |> clean(count, fallback)
    end
  end

  defp parse(_raw, _count, fallback), do: fallback

  defp clean(candidates, count, fallback) do
    candidates =
      candidates
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.take(count)

    if candidates == [], do: fallback, else: candidates
  end

  defp fallback_candidates(program, trainset, opts) do
    base = DSEx.Optimizer.InstructionSearch.current_instruction(program) || "Complete the task."
    labels = infer_labels(trainset)

    [
      base,
      base <> "\nBe concise and exact.",
      base <> "\nUse the demonstrations as ground truth patterns.",
      base <> "\nReturn only fields requested by the signature.",
      "Solve the task by matching inputs to outputs. Expected labels include: #{labels}."
    ] ++ Keyword.get(opts, :extra_instructions, [])
  rescue
    _error -> fallback_without_labels(program, opts)
  catch
    _kind, _reason -> fallback_without_labels(program, opts)
  end

  defp infer_labels(trainset) do
    trainset
    |> Enum.flat_map(fn example ->
      example |> DSEx.Example.labels() |> DSEx.Example.to_map() |> Map.keys()
    end)
    |> Enum.uniq()
    |> Enum.map(&to_string/1)
    |> Enum.join(", ")
  end

  defp fallback_without_labels(program, opts) do
    base = DSEx.Optimizer.InstructionSearch.current_instruction(program) || "Complete the task."

    [
      base,
      base <> "\nBe concise and exact.",
      base <> "\nUse the demonstrations as ground truth patterns.",
      base <> "\nReturn only fields requested by the signature."
    ] ++ Keyword.get(opts, :extra_instructions, [])
  end

  defp signature_spec(%DSEx.Signature{} = signature), do: DSEx.Signature.to_spec(signature)
  defp signature_spec(nil), do: nil
end
