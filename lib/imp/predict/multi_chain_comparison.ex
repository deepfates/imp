defmodule Imp.Predict.MultiChainComparison do
  @moduledoc """
  Compare several candidate completions and ask a predictor for the final output.

  `MultiChainComparison` is a composition primitive for self-consistency style
  workflows. You generate `m` candidate predictions elsewhere, pass them under
  `:completions` or `"completions"`, and this module builds a comparison
  prompt with one `:reasoning_attempt_N` input per candidate.

  Completions may be maps with atom or string keys, or `%Imp.Prediction{}`
  values. Imp reads `:rationale`/`:reasoning` plus the signature's final
  output field and sends those attempt summaries to the wrapped predictor.

  ## Example

      iex> lm = %{
      ...>   module: Imp.LM.Static,
      ...>   opts: [handler: fn _messages, _opts -> %{rationale: "two attempts agree", answer: "Paris"} end]
      ...> }
      iex> program = Imp.Predict.MultiChainComparison.new("question -> answer", lm: lm, m: 2)
      iex> {:ok, prediction} =
      ...>   Imp.Predict.MultiChainComparison.call(program, %{
      ...>     "question" => "Capital of France?",
      ...>     "completions" => [
      ...>       %{"reasoning" => "geography", "answer" => "Paris"},
      ...>       Imp.Prediction.new(reasoning: "landmark clue", answer: "Paris")
      ...>     ]
      ...>   })
      iex> Imp.Prediction.get(prediction, :answer)
      "Paris"
  """

  @behaviour Imp.Module

  defstruct [:predict, :last_key, m: 3]

  @option_schema [
    lm: [type: {:custom, Imp.LM, :validate_lm, []}],
    adapter: [type: {:custom, Imp.Adapter, :validate_adapter, []}],
    demos: [type: {:list, :any}, default: []],
    config: [type: :keyword_list, default: []],
    metadata: [type: {:map, :any, :any}, default: %{}],
    m: [type: {:custom, __MODULE__, :validate_m, []}],
    M: [type: {:custom, __MODULE__, :validate_m, []}]
  ]

  @doc """
  Builds a multi-chain comparison program.

  `:m` (or uppercase `:M`) is the exact number of completions expected at call
  time and must be a positive integer.
  """
  def new(signature, opts \\ []) do
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Predict.MultiChainComparison.new/2")
    signature = Imp.Signature.ensure(signature)
    last_key = signature |> Imp.Signature.output_names() |> List.last()
    m = Keyword.get(opts, :m, Keyword.get(opts, :M, 3))

    predict_opts =
      opts
      |> Imp.Predict.Predict.take_options()
      |> Keyword.put(:config, Keyword.put_new(opts[:config], :temperature, 0.7))

    comparison_signature =
      Enum.reduce(1..m, signature, fn index, acc ->
        Imp.Signature.extend(
          acc,
          [%{name: :"reasoning_attempt_#{index}", desc: "Reasoning attempt"}],
          :input
        )
      end)
      |> Imp.Signature.prepend_output(%{name: :rationale, desc: "Corrected reasoning"})

    %__MODULE__{
      predict: Imp.Predict.Predict.new(comparison_signature, predict_opts),
      last_key: last_key,
      m: m
    }
  end

  @doc false
  def validate_m(m) when is_integer(m) and m > 0, do: {:ok, m}

  def validate_m(m) do
    {:error, "expected a positive integer, got: #{inspect(m)}"}
  end

  @impl true
  @doc """
  Runs the comparison over a map or keyword list containing completions.

  Returns `{:error, {:wrong_completion_count, expected: m, got: count}}` when
  the completion count does not match the configured `m`, and
  `{:error, {:invalid_completions, value}}` when the completions field is not a
  list.
  """
  def call(%__MODULE__{} = mcc, inputs) when is_list(inputs) or is_map(inputs) do
    with {:ok, inputs} <- normalize_inputs(inputs) do
      compare(mcc, inputs)
    end
  end

  def call(%__MODULE__{}, inputs),
    do:
      {:error,
       {:invalid_multi_chain_inputs,
        "expected a map or keyword/list of input pairs, got: #{inspect(inputs)}"}}

  defp normalize_inputs(inputs) do
    {:ok, Map.new(inputs)}
  rescue
    _error -> {:error, {:invalid_multi_chain_inputs, "expected inputs as {key, value} pairs"}}
  end

  defp compare(%__MODULE__{} = mcc, inputs) do
    completions = Map.get(inputs, :completions, Map.get(inputs, "completions", []))

    cond do
      not is_list(completions) ->
        {:error, {:invalid_completions, inspect(completions)}}

      length(completions) != mcc.m ->
        {:error, {:wrong_completion_count, expected: mcc.m, got: length(completions)}}

      true ->
        attempts =
          completions
          |> Enum.with_index(1)
          |> Map.new(fn {completion, index} ->
            rationale =
              completion_value(completion, :rationale) || completion_value(completion, :reasoning) ||
                ""

            rationale = normalize_evidence(rationale)
            answer = completion |> completion_value(mcc.last_key) |> normalize_evidence()

            attempt =
              "«I'm trying to #{rationale} I'm not sure but my prediction is #{answer}»"

            {:"reasoning_attempt_#{index}", attempt}
          end)

        inputs =
          inputs
          |> Map.drop([:completions, "completions"])
          |> Map.merge(attempts)

        Imp.Predict.Predict.call(mcc.predict, inputs)
    end
  end

  defp completion_value(%Imp.Prediction{} = prediction, field),
    do: Imp.Prediction.get(prediction, field)

  defp completion_value(completion, field) when is_map(completion) do
    Map.get(completion, field) || Map.get(completion, to_string(field))
  end

  defp completion_value(_completion, _field), do: nil

  defp normalize_evidence(value) do
    value
    |> evidence_string()
    |> String.split(~r/\R/, parts: 2)
    |> hd()
    |> String.trim()
  end

  defp evidence_string(nil), do: ""
  defp evidence_string(value) when is_binary(value), do: value

  defp evidence_string(value) do
    to_string(value)
  rescue
    _error -> inspect(value)
  end
end
