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

  defp propose_with_lm(lm, program, trainset, opts, count, fallback) do
    lm
    |> DSEx.LM.generate(messages(program, trainset, opts), [])
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
          Jason.encode!(%{
            current_instruction: DSEx.Optimizer.InstructionSearch.current_instruction(program),
            signature: signature_spec(program),
            train_examples: Enum.map(trainset, &DSEx.Example.to_map/1),
            scored_examples: scored_examples
          })
      }
    ]
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

  defp signature_spec(%DSEx.Predict.Predict{signature: signature}),
    do: DSEx.Signature.to_spec(signature)

  defp signature_spec(%DSEx.Predict.ChainOfThought{predict: predict}), do: signature_spec(predict)
  defp signature_spec(_program), do: nil
end
