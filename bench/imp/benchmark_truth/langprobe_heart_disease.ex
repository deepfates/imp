defmodule Imp.BenchmarkTruth.LangProBeHeartDisease do
  @moduledoc false

  @behaviour Imp.Module

  alias Imp.Predict.ChainOfThought

  @mipro_paper "https://arxiv.org/abs/2406.11695"
  @langprobe_repository "https://github.com/Shangyint/langProBe"
  @langprobe_commit "f0061917f0e33ad141013d720c2ddea89c245da9"
  @langprobe_dataset_commit "4e539bff1729a7a4fd72fcdbb2dfbfcff71574fe"
  @langprobe_dataset_sha256 "3369f450e6fdbad6019755437f0228109cb457e62b8cf7c4b29799ba1f8fc884"
  @tensorflow_dataset_url "https://storage.googleapis.com/download.tensorflow.org/data/heart.csv"
  @tensorflow_dataset_sha256 "a91c81831bb2126e5fde6ce4ebde147a78429da12005108a6677ba57ecde9244"
  @uci_doi "10.24432/C52P4X"
  @uci_license "CC BY 4.0"
  @uci_archive_sha256 "b17cd273da9ce1caa4710fce80227ea454d4dbf9fcbc8e6a9121672751563adc"
  @components [:opinion_1, :opinion_2, :opinion_3, :vote]
  @input_fields [
    :age,
    :sex,
    :cp,
    :trestbps,
    :chol,
    :fbs,
    :restecg,
    :thalach,
    :exang,
    :oldpeak,
    :slope,
    :ca,
    :thal
  ]

  defstruct @components

  def authority do
    %{
      mipro_paper: @mipro_paper,
      langprobe: %{repository: @langprobe_repository, commit: @langprobe_commit},
      dataset: %{
        benchmark_snapshot: %{
          authority: :tensorflow_derived_langprobe_snapshot,
          hugging_face_commit: @langprobe_dataset_commit,
          lf_normalized_sha256: @langprobe_dataset_sha256,
          tensorflow_url: @tensorflow_dataset_url,
          tensorflow_crlf_sha256: @tensorflow_dataset_sha256
        },
        upstream_authority: %{
          authority: :uci_heart_disease,
          doi: @uci_doi,
          license: @uci_license,
          archive_sha256: @uci_archive_sha256
        },
        equivalence: %{
          status: :falsified,
          exact_feature_matches: 297,
          unmatched_benchmark_rows: 6,
          matched_target_rule: :uci_severity_greater_than_or_equal_to_2,
          disclosed_prompt_label_mismatch: true
        }
      },
      status: :provider_free_product_fit_only,
      study_identity: :adapted_current_source_not_exact_paper_reproduction
    }
  end

  def new(lm, opts \\ []) do
    adapter = Keyword.get(opts, :adapter, Imp.Adapter.Chat)
    config = Keyword.get(opts, :config, cache: false, json_fallback: false)
    opinion = opinion_signature()

    %__MODULE__{
      opinion_1: predictor(opinion, lm, adapter, config, :opinion_1, 0.70),
      opinion_2: predictor(opinion, lm, adapter, config, :opinion_2, 0.71),
      opinion_3: predictor(opinion, lm, adapter, config, :opinion_3, 0.72),
      vote: predictor(vote_signature(), lm, adapter, config, :vote, nil)
    }
  end

  @impl true
  def optimizer_predictors(%__MODULE__{} = program) do
    Enum.map(@components, fn name -> {name, Map.fetch!(program, name).predict} end)
  end

  @impl true
  def update_optimizer_predictor(%__MODULE__{} = program, name, update)
      when name in @components and is_function(update, 1) do
    component = Map.fetch!(program, name)
    Map.put(program, name, %{component | predict: update.(component.predict)})
  end

  @impl true
  def call(%__MODULE__{} = program, inputs) when is_map(inputs) or is_list(inputs) do
    inputs = Map.new(inputs)

    with {:ok, clinical_inputs} <- clinical_inputs(inputs),
         {:ok, first} <- opinion(program.opinion_1, clinical_inputs),
         {:ok, second} <- opinion(program.opinion_2, clinical_inputs),
         {:ok, third} <- opinion(program.opinion_3, clinical_inputs),
         {:ok, prediction} <-
           Imp.call(program.vote, Map.put(clinical_inputs, :context, [first, second, third])) do
      {:ok, prediction}
    else
      {:error, reason} -> {:error, {:langprobe_heart_disease_failed, reason}}
    end
  end

  def call(%__MODULE__{}, inputs),
    do: {:error, {:langprobe_heart_disease_failed, {:invalid_inputs, inputs}}}

  def example(id, row, answer) when is_map(row) and is_binary(answer) do
    values = Map.take(row, @input_fields)

    unless map_size(values) == length(@input_fields),
      do: raise(ArgumentError, "Heart Disease row is missing one or more of the 13 input fields")

    values
    |> Map.merge(%{id: id, answer: answer})
    |> then(&Imp.Example.new(&1))
    |> Imp.Example.with_inputs(@input_fields)
  end

  def metric(expected, prediction) do
    normalize_answer(Imp.Example.get(expected, :answer)) ==
      normalize_answer(Imp.Prediction.get(prediction, :answer, ""))
  end

  def input_fields, do: @input_fields

  defp predictor(signature, lm, adapter, config, name, temperature) do
    config =
      if is_number(temperature), do: Keyword.put(config, :temperature, temperature), else: config

    ChainOfThought.new(signature,
      lm: lm,
      adapter: adapter,
      config: config,
      metadata: %{optimizer_predictor_name: name}
    )
  end

  defp opinion_signature do
    Imp.signature(
      "#{input_spec()} -> answer",
      "Given patient information, predict the presence of heart disease. Answer yes or no."
    )
  end

  defp vote_signature do
    Imp.signature(
      "#{input_spec()}, context: array[string] -> answer",
      "Given patient information, predict the presence of heart disease. Critically assess the trainee opinions and answer yes or no."
    )
  end

  defp input_spec, do: Enum.join(@input_fields, ", ")

  defp clinical_inputs(inputs) do
    missing = Enum.reject(@input_fields, &Map.has_key?(inputs, &1))

    if missing == [],
      do: {:ok, Map.take(inputs, @input_fields)},
      else: {:error, {:missing_input_fields, missing}}
  end

  defp opinion(component, inputs) do
    with {:ok, prediction} <- Imp.call(component, inputs),
         reasoning when is_binary(reasoning) <- Imp.Prediction.get(prediction, :reasoning),
         answer when is_binary(answer) <- Imp.Prediction.get(prediction, :answer) do
      {:ok,
       "I'm a trainee doctor, reasoning that #{String.trim(reasoning, ".")}. Hence, my answer is #{String.trim(answer, ".")}."}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_opinion}
    end
  end

  defp normalize_answer(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.trim()
    |> String.trim_trailing(".")
  end
end
