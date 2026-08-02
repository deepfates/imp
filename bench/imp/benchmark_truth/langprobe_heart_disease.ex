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
  @dataset_path Path.join(__DIR__, "langprobe_heart_disease.csv")
  @split_path Path.join(__DIR__, "langprobe_heart_disease_split.json")
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

  def data!(dataset_path \\ @dataset_path, split_path \\ @split_path) do
    assert_sha256!(dataset_path, @langprobe_dataset_sha256, "LangProBe Heart Disease dataset")
    receipt = split_path |> File.read!() |> Jason.decode!()

    unless get_in(receipt, ["authority", "source_lf_sha256"]) == @langprobe_dataset_sha256 do
      raise ArgumentError,
            "LangProBe Heart Disease split receipt does not bind the pinned dataset"
    end

    examples =
      dataset_path
      |> Imp.Datasets.csv(@input_fields)
      |> Enum.with_index()
      |> Map.new(fn {example, index} -> {index, normalize_source_example(example, index)} end)

    splits =
      Map.new(["train", "selection", "test"], fn name ->
        indices = get_in(receipt, ["splits", name, "source_indices"])
        expected_count = get_in(receipt, ["splits", name, "count"])

        unless is_list(indices) and length(indices) == expected_count do
          raise ArgumentError, "invalid #{name} split in LangProBe Heart Disease receipt"
        end

        {String.to_existing_atom(name), Enum.map(indices, &Map.fetch!(examples, &1))}
      end)

    all_ids = splits |> Map.values() |> List.flatten() |> Enum.map(&Imp.Example.fetch!(&1, :id))

    unless length(all_ids) == 303 and MapSet.size(MapSet.new(all_ids)) == 303 do
      raise ArgumentError,
            "LangProBe Heart Disease split receipt is not a disjoint full partition"
    end

    Map.put(splits, :receipt, receipt)
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

  def dataset_path, do: @dataset_path
  def split_path, do: @split_path

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

  defp normalize_source_example(example, index) do
    mappings = %{
      sex: %{"0" => "female", "1" => "male"},
      cp: %{
        "1" => "typical angina",
        "2" => "atypical angina",
        "3" => "non-anginal pain",
        "4" => "asymptomatic"
      },
      restecg: %{
        "0" => "normal",
        "1" => "ST-T wave abnormality",
        "2" => "left ventricular hypertrophy"
      },
      exang: %{"0" => "no", "1" => "yes"},
      slope: %{"1" => "upsloping", "2" => "flat", "3" => "downsloping"},
      thal: %{"3" => "normal", "6" => "fixed defect", "7" => "reversible defect"}
    }

    normalized =
      Enum.reduce(mappings, example, fn {field, mapping}, current ->
        Imp.Example.put(
          current,
          field,
          Map.get(mapping, Imp.Example.fetch!(current, field), Imp.Example.fetch!(current, field))
        )
      end)

    answer = Map.fetch!(%{"0" => "no", "1" => "yes"}, Imp.Example.fetch!(normalized, :target))

    normalized
    |> Imp.Example.delete(:target)
    |> Imp.Example.put(:answer, answer)
    |> Imp.Example.put(:id, "heart-source-#{index}")
    |> Imp.Example.with_inputs(@input_fields)
  end

  defp assert_sha256!(path, expected, label) do
    bytes = File.read!(path)

    # Git keeps the repository mirror newline-terminated. The pinned
    # Hugging Face LFS object is the same CSV without that final byte.
    source_bytes =
      if String.ends_with?(bytes, "\n"),
        do: binary_part(bytes, 0, byte_size(bytes) - 1),
        else: bytes

    actual = source_bytes |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    unless actual == expected do
      raise ArgumentError, "#{label} SHA-256 drift: expected #{expected}, got #{actual}"
    end
  end
end
