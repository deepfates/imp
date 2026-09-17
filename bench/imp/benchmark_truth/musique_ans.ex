defmodule Imp.BenchmarkTruth.MusiqueAns do
  @moduledoc false

  @behaviour Imp.Module

  alias Imp.{Example, Prediction}

  @repository "https://github.com/StonyBrookNLP/musique"
  @commit "922ac98f19a201998dbdae6d7f2887a5258dbdeb"
  @archive_sha256 "98f839bf2fd5319f5c688aed77901a6d5c30b3b9f9f691ab9a8ecafb045ee0cd"
  @train_sha256 "83a75b1e11e4e9bb8f8308e72ac40ca617ae4431b3a0d955b61cab259248490a"
  @dev_sha256 "15fa63794d18a94ce12411aca6e2327e65b6e83b0b1490efab3f1962e48abf3b"
  @test_sha256 "92ee3067957b8ebce885baa71156a7c0c29f3bc72cca04510aef506911dd768f"
  @counts %{train: 19_938, dev: 2_417, test: 2_459}
  @selector_top_k 7
  @components [:selector, :answerer]

  defstruct [:selector, :answerer]

  def authority do
    %{
      repository: @repository,
      commit: @commit,
      license: "CC BY 4.0",
      archive: %{bytes: 272_049_578, sha256: @archive_sha256},
      splits: %{
        train: %{rows: @counts.train, sha256: @train_sha256},
        dev: %{
          rows: @counts.dev,
          sha256: @dev_sha256,
          status: :audit_exposed_model_optimizer_treatment_unseen
        },
        test: %{
          rows: @counts.test,
          sha256: @test_sha256,
          hash_scope: :locally_measured_archive_member,
          status: :audit_exposed_inputs_only_labels_hidden_treatment_excluded,
          path: "data/musique_ans_v1.0_test.jsonl"
        }
      }
    }
  end

  def new(lm, opts \\ []) do
    adapter = Keyword.get(opts, :adapter, Imp.Adapter.Chat)
    config = Keyword.get(opts, :config, cache: false, json_fallback: false)

    %__MODULE__{
      selector:
        Imp.predict(
          Imp.signature(
            "question, paragraphs: array[object] -> ordered_paragraph_idxs: array[integer]",
            "Return exactly seven unique original paragraph indices, ranked by relevance."
          ),
          lm: lm,
          adapter: adapter,
          config: config
        ),
      answerer:
        Imp.predict(
          Imp.signature(
            "question, selected_paragraphs: array[object] -> answer, support_positions: array[integer]",
            "Answer and identify supporting positions within the selected paragraph list."
          ),
          lm: lm,
          adapter: adapter,
          config: config
        )
    }
  end

  @impl true
  def optimizer_predictors(program), do: [selector: program.selector, answerer: program.answerer]

  @impl true
  def update_optimizer_predictor(program, name, update) when name in @components,
    do: Map.update!(program, name, update)

  @impl true
  def call(program, inputs) when is_map(inputs) or is_list(inputs) do
    inputs = Map.new(inputs)
    question = Map.get(inputs, :question, Map.get(inputs, "question"))
    paragraphs = Map.get(inputs, :paragraphs, Map.get(inputs, "paragraphs"))

    with true <- (is_binary(question) and is_list(paragraphs)) || {:error, :invalid_inputs},
         {:ok, selected} <-
           Imp.call(program.selector, %{question: question, paragraphs: paragraphs}),
         ordered_idxs when is_list(ordered_idxs) <-
           Prediction.get(selected, :ordered_paragraph_idxs),
         {:ok, selected_paragraphs} <- select_paragraphs(paragraphs, ordered_idxs),
         {:ok, answered} <-
           Imp.call(program.answerer, %{
             question: question,
             selected_paragraphs: selected_paragraphs
           }),
         answer when is_binary(answer) <- Prediction.get(answered, :answer),
         support_positions when is_list(support_positions) <-
           Prediction.get(answered, :support_positions),
         {:ok, support_idxs} <- map_support_positions(selected_paragraphs, support_positions) do
      {:ok, Prediction.new(answer: answer, support_idxs: support_idxs)}
    else
      {:error, reason} -> {:error, {:musique_ans_failed, reason}}
      _ -> {:error, {:musique_ans_failed, :invalid_stage_output}}
    end
  end

  def model_inputs(row) do
    %{
      question: Map.fetch!(row, "question"),
      paragraphs:
        Enum.map(Map.fetch!(row, "paragraphs"), fn paragraph ->
          %{
            "idx" => Map.fetch!(paragraph, "idx"),
            "title" => Map.fetch!(paragraph, "title"),
            "text" => Map.fetch!(paragraph, "paragraph_text")
          }
        end)
    }
  end

  def example(row) do
    inputs = model_inputs(row)
    support = for paragraph <- row["paragraphs"], paragraph["is_supporting"], do: paragraph["idx"]

    Example.new(
      id: row["id"],
      question: inputs.question,
      paragraphs: inputs.paragraphs,
      answer: row["answer"],
      answer_aliases: row["answer_aliases"],
      support_idxs: support
    )
    |> Example.with_inputs([:question, :paragraphs])
  end

  def score(gold, prediction) do
    predicted_answer = Prediction.get(prediction, :answer, "")
    predicted_support = Prediction.get(prediction, :support_idxs, [])
    answers = [Example.get(gold, :answer) | Example.get(gold, :answer_aliases, [])]
    answer_em = Enum.map(answers, &answer_em(predicted_answer, &1)) |> Enum.max()
    answer_f1 = Enum.map(answers, &answer_f1(predicted_answer, &1)) |> Enum.max()
    support_f1 = support_f1(predicted_support, Example.get(gold, :support_idxs, []))

    %{answer_em: answer_em, answer_f1: answer_f1, support_f1: support_f1}
  end

  def answer_em(predicted, gold),
    do: if(normalize(predicted) == normalize(gold), do: 1.0, else: 0.0)

  def answer_f1(predicted, gold) do
    predicted = tokens(predicted)
    gold = tokens(gold)

    cond do
      predicted == [] or gold == [] ->
        if predicted == gold, do: 1.0, else: 0.0

      true ->
        common = multiset_intersection(predicted, gold)
        if common == 0, do: 0.0, else: 2 * common / (length(predicted) + length(gold))
    end
  end

  def support_f1(predicted, gold) do
    unless Enum.all?(predicted, &is_integer/1) and Enum.all?(gold, &is_integer/1),
      do: raise(ArgumentError, "MuSiQue support indices must be integers")

    predicted = MapSet.new(predicted)
    gold = MapSet.new(gold)

    if MapSet.size(predicted) == 0 and MapSet.size(gold) == 0 do
      1.0
    else
      common = predicted |> MapSet.intersection(gold) |> MapSet.size()
      denominator = MapSet.size(predicted) + MapSet.size(gold)
      if common == 0, do: 0.0, else: 2 * common / denominator
    end
  end

  def verify_data!(archive_path, data_root) do
    verify_file!(archive_path, @archive_sha256)

    train =
      load_split!(
        Path.join(data_root, "musique_ans_v1.0_train.jsonl"),
        @train_sha256,
        @counts.train
      )

    dev_path = Path.join(data_root, "musique_ans_v1.0_dev.jsonl")
    verify_file!(dev_path, @dev_sha256)
    verify_line_count!(dev_path, @counts.dev)

    %{
      train: train,
      train_rows: length(train),
      dev: %{
        decoded_in_this_entry: false,
        rows: @counts.dev,
        sha256: @dev_sha256,
        status: :audit_exposed_model_optimizer_treatment_unseen
      },
      test: %{
        decoded_in_this_entry: false,
        rows: @counts.test,
        status: :audit_exposed_inputs_only_labels_hidden_treatment_excluded,
        path: "data/musique_ans_v1.0_test.jsonl"
      }
    }
  end

  defp select_paragraphs(paragraphs, indices) do
    by_index = Map.new(paragraphs, &{Map.get(&1, "idx", Map.get(&1, :idx)), &1})

    if length(indices) == @selector_top_k and length(Enum.uniq(indices)) == @selector_top_k and
         Enum.all?(indices, &(is_integer(&1) and Map.has_key?(by_index, &1))),
       do: {:ok, Enum.map(indices, &Map.fetch!(by_index, &1))},
       else: {:error, :invalid_top7_ranking}
  end

  defp map_support_positions(selected, positions) do
    if length(positions) == length(Enum.uniq(positions)) and
         Enum.all?(positions, &(is_integer(&1) and &1 >= 0 and &1 < length(selected))) do
      {:ok,
       Enum.map(positions, fn position -> selected |> Enum.at(position) |> Map.fetch!("idx") end)}
    else
      {:error, :unknown_support_position}
    end
  end

  defp normalize(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[!"#$%&'()*+,\-.\/:;<=>?@\[\\\]^_`{|}~]/u, "")
    |> String.replace(~r/\b(a|an|the)\b/u, " ")
    |> String.split()
    |> Enum.join(" ")
  end

  defp tokens(value), do: value |> normalize() |> String.split()

  defp multiset_intersection(left, right) do
    left = Enum.frequencies(left)
    right = Enum.frequencies(right)

    Enum.reduce(left, 0, fn {token, count}, total ->
      total + min(count, Map.get(right, token, 0))
    end)
  end

  defp load_split!(path, expected_sha256, expected_count) do
    verify_file!(path, expected_sha256)
    rows = path |> File.stream!() |> Enum.map(&Jason.decode!/1)
    if length(rows) != expected_count, do: raise(ArgumentError, "MuSiQue split row-count drift")
    rows
  end

  defp verify_line_count!(path, expected_count) do
    if Enum.count(File.stream!(path)) != expected_count,
      do: raise(ArgumentError, "MuSiQue split row-count drift")
  end

  defp verify_file!(path, expected) do
    digest =
      path
      |> File.stream!([], 1_048_576)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if digest != expected,
      do: raise(ArgumentError, "MuSiQue authority hash drift for #{path}")
  end
end
