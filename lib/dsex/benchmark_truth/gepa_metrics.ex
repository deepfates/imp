defmodule DSEx.BenchmarkTruth.GepaMetrics do
  @moduledoc false

  def metric(spec, opts \\ []) do
    output_key = spec["output_key"]
    judge_lm = Keyword.get(opts, :judge_lm)

    case spec["upstream_metric"] do
      "AIME.metric integer exact match" ->
        &aime_integer_exact/2

      "dspy.evaluate.answer_exact_match" ->
        &hotpot_answer_exact/2

      "hover_utils.discrete_retrieval_eval" ->
        &hover_retrieval/2

      "IFBench.ifbench_metric.metric" ->
        &ifbench_instruction_following/2

      "livebench_math.calculate_livebench_score" ->
        &livebench_math/2

      "papillon_utils.compute_overall_score" ->
        papillon_overall(judge_lm)

      _other ->
        exact_output(output_key)
    end
  end

  @doc false
  def metric_with_feedback(spec, opts \\ [])

  def metric_with_feedback(%{"upstream_metric" => "IFBench.ifbench_metric.metric"}, opts) do
    fn example, prediction ->
      ifbench_instruction_following_with_feedback(example, prediction, opts)
    end
  end

  def metric_with_feedback(spec, opts) do
    metric(spec, opts)
  end

  defp aime_integer_exact(example, prediction) do
    with {gold, ""} <- example |> DSEx.Example.get(:answer) |> to_string() |> Integer.parse(),
         {predicted, ""} <-
           prediction |> DSEx.Prediction.get(:answer) |> to_string() |> Integer.parse() do
      gold == predicted
    else
      _ -> false
    end
  end

  defp hotpot_answer_exact(example, prediction) do
    answer = DSEx.Example.get(example, :answer)
    predicted = DSEx.Prediction.get(prediction, :answer)
    DSEx.Metrics.em(predicted, answer)
  end

  defp hover_retrieval(example, prediction) do
    gold_titles =
      example
      |> DSEx.Example.get(:supporting_facts, [])
      |> Enum.map(&supporting_fact_title/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&DSEx.Metrics.normalize_text/1)
      |> MapSet.new()

    found_titles =
      prediction
      |> DSEx.Prediction.get(:retrieved_docs, [])
      |> List.wrap()
      |> Enum.map(&retrieved_title/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&DSEx.Metrics.normalize_text/1)
      |> MapSet.new()

    MapSet.subset?(gold_titles, found_titles)
  end

  defp supporting_fact_title(%{"key" => key}), do: key
  defp supporting_fact_title(%{key: key}), do: key
  defp supporting_fact_title(_other), do: nil

  defp retrieved_title(value) when is_binary(value) do
    value |> String.split(" | ", parts: 2) |> hd()
  end

  defp retrieved_title(%{"title" => title}), do: title
  defp retrieved_title(%{title: title}), do: title
  defp retrieved_title(_other), do: nil

  defp ifbench_instruction_following(example, prediction) do
    example
    |> ifbench_outcomes(prediction)
    |> then(fn outcomes ->
      case outcomes do
        [] -> 0.0
        outcomes -> Enum.count(outcomes, & &1.following?) / length(outcomes)
      end
    end)
  end

  defp ifbench_instruction_following_with_feedback(example, prediction, opts) do
    outcomes = ifbench_outcomes(example, prediction)
    correct = Enum.filter(outcomes, & &1.following?)
    incorrect = Enum.reject(outcomes, & &1.following?)
    descriptions = ifbench_descriptions(outcomes, DSEx.Example.get(example, :prompt, ""), opts)

    feedback =
      [
        instruction_feedback(
          correct,
          descriptions,
          "Your response correctly followed the following instructions:"
        ),
        instruction_feedback(
          incorrect,
          descriptions,
          if(correct == [],
            do: "Your response did not follow the following instructions properly:",
            else: "However, your response did not follow the following instructions properly:"
          )
        )
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    score = if(outcomes == [], do: 0.0, else: length(correct) / length(outcomes))
    %{score: score, feedback: feedback}
  end

  defp ifbench_outcomes(example, prediction) do
    response = prediction |> DSEx.Prediction.get(:response) |> to_string()
    variants = response_variants(response)

    instructions = DSEx.Example.get(example, :instruction_id_list, [])
    kwargs = DSEx.Example.get(example, :kwargs, [])
    prompt = DSEx.Example.get(example, :prompt, "")

    instructions
    |> Enum.with_index()
    |> Enum.map(fn {instruction_id, index} ->
      args = Enum.at(kwargs, index, %{}) |> strip_nil_values()

      following? =
        Enum.any?(variants, fn variant ->
          String.trim(variant) != "" and ifbench_following?(instruction_id, args, prompt, variant)
        end)

      %{index: index, instruction_id: instruction_id, args: args, following?: following?}
    end)
  end

  defp instruction_feedback([], _descriptions, _heading), do: nil

  defp instruction_feedback(outcomes, descriptions, heading) do
    descriptions =
      Enum.map_join(outcomes, "\n", fn outcome ->
        Map.fetch!(descriptions, outcome.index)
      end)

    heading <> "\n" <> descriptions
  end

  defp ifbench_descriptions(outcomes, prompt, opts) do
    if Keyword.get(opts, :upstream_descriptions, false) do
      upstream_ifbench_descriptions!(outcomes, prompt, opts)
    else
      Map.new(outcomes, fn outcome ->
        {outcome.index, "#{outcome.instruction_id} #{Jason.encode!(outcome.args)}"}
      end)
    end
  end

  defp upstream_ifbench_descriptions!(outcomes, prompt, opts) do
    artifact_root = Keyword.fetch!(opts, :gepa_root)
    python = opts |> Keyword.get(:python, "python3") |> resolve_executable()
    bridge = Keyword.get(opts, :ifbench_description_bridge, default_ifbench_description_bridge())

    unless is_binary(artifact_root) and File.dir?(artifact_root) do
      raise ArgumentError, "IFBench upstream descriptions require an existing GEPA artifact root"
    end

    unless executable_available?(python) do
      raise ArgumentError, "IFBench upstream descriptions require an available Python executable"
    end

    payload = %{
      "instructions" =>
        Enum.map(outcomes, fn outcome ->
          %{
            "instruction_id" => outcome.instruction_id,
            "args" => outcome.args,
            "prompt" => prompt
          }
        end)
    }

    path =
      Path.join(
        System.tmp_dir!(),
        "dsex-ifbench-descriptions-#{System.unique_integer([:positive])}.json"
      )

    try do
      File.write!(path, Jason.encode!(payload))

      case System.cmd(
             python,
             [bridge, "--artifact-root", artifact_root, "--payload", path],
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          descriptions = output |> Jason.decode!() |> Map.fetch!("descriptions")

          unless length(descriptions) == length(outcomes) and
                   Enum.all?(descriptions, &(is_binary(&1) and String.trim(&1) != "")) do
            raise ArgumentError,
                  "IFBench upstream description bridge returned invalid descriptions"
          end

          outcomes
          |> Enum.zip(descriptions)
          |> Map.new(fn {outcome, description} -> {outcome.index, description} end)

        {output, status} ->
          raise RuntimeError,
                "IFBench upstream description bridge failed with status #{status}: #{String.trim(output)}"
      end
    after
      File.rm(path)
    end
  end

  defp default_ifbench_description_bridge do
    Path.expand("../../../scripts/ifbench_upstream_describe.py", __DIR__)
  end

  defp executable_available?(executable) when is_binary(executable) do
    if Path.type(executable) == :absolute or String.contains?(executable, "/"),
      do: executable |> Path.expand() |> File.regular?(),
      else: not is_nil(System.find_executable(executable))
  end

  defp executable_available?(_executable), do: false

  defp resolve_executable(executable) when is_binary(executable) do
    if Path.type(executable) == :absolute or String.contains?(executable, "/"),
      do: Path.expand(executable),
      else: System.find_executable(executable) || executable
  end

  defp resolve_executable(executable), do: executable

  defp response_variants(response) do
    lines = String.split(response, "\n")
    remove_first = lines |> Enum.drop(1) |> Enum.join("\n") |> String.trim()
    remove_last = lines |> Enum.drop(-1) |> Enum.join("\n") |> String.trim()
    remove_both = lines |> Enum.drop(1) |> Enum.drop(-1) |> Enum.join("\n") |> String.trim()

    [response, String.replace(response, "*", ""), remove_first, remove_last, remove_both]
    |> Kernel.++(Enum.map([remove_first, remove_last, remove_both], &String.replace(&1, "*", "")))
  end

  defp strip_nil_values(map) when is_map(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp strip_nil_values(_other), do: %{}

  defp ifbench_following?("keywords:existence", %{"keywords" => keywords}, _prompt, value) do
    Enum.all?(List.wrap(keywords), &regex_contains?(value, &1, "i"))
  end

  defp ifbench_following?("keywords:frequency", args, _prompt, value) do
    count = regex_count(value, Map.get(args, "keyword", ""), "i")
    compare_count(count, Map.get(args, "frequency", 0), Map.get(args, "relation"))
  end

  defp ifbench_following?(
         "keywords:forbidden_words",
         %{"forbidden_words" => words},
         _prompt,
         value
       ) do
    Enum.all?(List.wrap(words), fn word ->
      not Regex.match?(~r/\b#{Regex.escape(to_string(word))}\b/i, value)
    end)
  end

  defp ifbench_following?("keywords:letter_frequency", args, _prompt, value) do
    letter = args |> Map.get("letter", "") |> to_string() |> String.downcase()
    count = value |> String.downcase() |> String.graphemes() |> Enum.count(&(&1 == letter))
    compare_count(count, Map.get(args, "let_frequency", 0), Map.get(args, "let_relation"))
  end

  defp ifbench_following?("language:response_language", args, _prompt, value) do
    language = args |> Map.get("language", "en") |> to_string()
    ifbench_language?(language, value)
  end

  defp ifbench_following?("count:word_count_range", args, _prompt, value) do
    count = count_words(value)
    count >= Map.get(args, "min_words", 0) and count <= Map.get(args, "max_words", 0)
  end

  defp ifbench_following?("count:unique_word_count", args, _prompt, value) do
    unique =
      value
      |> String.downcase()
      |> String.split(~r/\s+/, trim: true)
      |> Enum.map(&trim_punctuation/1)
      |> MapSet.new()
      |> MapSet.size()

    unique >= Map.get(args, "N", 0)
  end

  defp ifbench_following?("count:numbers", args, _prompt, value) do
    stripped = String.replace(value, ~r/[[:punct:]]/, "")
    length(Regex.scan(~r/\d+/, stripped)) == Map.get(args, "N", 0)
  end

  defp ifbench_following?("count:punctuation", _args, _prompt, value) do
    punctuation = MapSet.new([".", ",", "!", "?", ";", ":"])

    if String.contains?(value, "!?") or String.contains?(value, "?!") or
         String.contains?(value, "‽") do
      value
      |> String.replace("?!", "", global: false)
      |> String.replace("!?", "", global: false)
      |> String.graphemes()
      |> MapSet.new()
      |> then(&MapSet.subset?(punctuation, &1))
    else
      false
    end
  end

  defp ifbench_following?("count:conjunctions", args, _prompt, value) do
    conjunctions = MapSet.new(["and", "but", "for", "nor", "or", "so", "yet"])

    value
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&(&1 |> trim_punctuation() |> String.downcase()))
    |> Enum.filter(&MapSet.member?(conjunctions, &1))
    |> MapSet.new()
    |> MapSet.size()
    |> Kernel.>=(Map.get(args, "small_n", 0))
  end

  defp ifbench_following?("count:pronouns", args, _prompt, value) do
    pronouns =
      MapSet.new([
        "i",
        "me",
        "my",
        "mine",
        "myself",
        "we",
        "us",
        "our",
        "ours",
        "ourselves",
        "you",
        "your",
        "yours",
        "yourself",
        "yourselves",
        "he",
        "him",
        "his",
        "himself",
        "she",
        "her",
        "hers",
        "herself",
        "it",
        "its",
        "itself",
        "they",
        "them",
        "their",
        "theirs",
        "themselves"
      ])

    value
    |> String.replace("/", " ")
    |> strip_all_punctuation()
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.count(&MapSet.member?(pronouns, &1))
    |> Kernel.>=(Map.get(args, "N", 0))
  end

  defp ifbench_following?("count:keywords_multiple", args, _prompt, value) do
    value = String.downcase(value)

    [
      {"keyword1", 1},
      {"keyword2", 2},
      {"keyword3", 3},
      {"keyword4", 5},
      {"keyword5", 7}
    ]
    |> Enum.all?(fn {key, expected_count} ->
      keyword = args |> Map.get(key, "") |> to_string() |> String.downcase()
      keyword != "" and substring_count(value, keyword) == expected_count
    end)
  end

  defp ifbench_following?("count:person_names", args, _prompt, value) do
    person_names()
    |> Enum.count(&String.contains?(value, &1))
    |> Kernel.>=(Map.get(args, "N", 0))
  end

  defp ifbench_following?("count:words_japanese", args, _prompt, value) do
    position = Map.get(args, "N", 1)

    value
    |> String.split(~r/\s+/, trim: true)
    |> Enum.with_index(1)
    |> Enum.all?(fn {word, index} ->
      word = trim_punctuation(word)

      rem(index, position) != 0 or word == "" or Regex.match?(~r/^\d+$/, word) or
        Regex.match?(~r/[\x{3040}-\x{30ff}\x{4e00}-\x{9fff}]/u, word)
    end)
  end

  defp ifbench_following?("ratio:stop_words", args, _prompt, value) do
    ifbench_nlp_bridge("ratio:stop_words", args, value, fn ->
      tokens = word_tokens(value)

      if tokens == [] do
        false
      else
        stopwords = ifbench_stopwords()
        stopword_count = tokens |> Enum.map(&String.downcase/1) |> Enum.count(&(&1 in stopwords))
        stopword_count / length(tokens) * 100 <= Map.get(args, "percentage", 0)
      end
    end)
  end

  defp ifbench_following?("ratio:sentence_type", _args, _prompt, value) do
    sentences = split_sentences(value)
    declarative_count = Enum.count(sentences, &String.ends_with?(&1, "."))
    interrogative_count = Enum.count(sentences, &String.ends_with?(&1, "?"))
    declarative_count == 2 * interrogative_count
  end

  defp ifbench_following?("ratio:sentence_balance", _args, _prompt, value) do
    sentences = split_sentences(value)
    declarative_count = Enum.count(sentences, &String.ends_with?(&1, "."))
    interrogative_count = Enum.count(sentences, &String.ends_with?(&1, "?"))
    exclamatory_count = Enum.count(sentences, &String.ends_with?(&1, "!"))
    declarative_count == interrogative_count and interrogative_count == exclamatory_count
  end

  defp ifbench_following?("ratio:overlap", args, _prompt, value) do
    reference_text = Map.get(args, "reference_text", "")
    percentage = Map.get(args, "percentage", 0)
    ngrams = char_ngrams(value, 3)
    reference_ngrams = char_ngrams(reference_text, 3)

    if MapSet.size(ngrams) == 0 do
      false
    else
      overlap = MapSet.intersection(ngrams, reference_ngrams) |> MapSet.size()
      score = overlap / MapSet.size(ngrams) * 100
      percentage - 2 <= score and score <= percentage + 2
    end
  end

  defp ifbench_following?("ratio:sentence_words", _args, _prompt, value) do
    sentences = split_sentences(value)

    length(sentences) == 3 and
      sentences
      |> Enum.map(&(String.trim(&1) |> String.length()))
      |> Enum.uniq()
      |> length()
      |> Kernel.==(1)
  end

  defp ifbench_following?("length_constraints:number_sentences", args, _prompt, value) do
    count = sentence_count(value)
    compare_count(count, Map.get(args, "num_sentences", 0), Map.get(args, "relation"))
  end

  defp ifbench_following?("length_constraints:number_paragraphs", args, _prompt, value) do
    paragraphs = String.split(value, ~r/\s?\*\*\*\s?/)

    count =
      paragraphs
      |> Enum.with_index()
      |> Enum.reduce(length(paragraphs), fn {paragraph, index}, acc ->
        if String.trim(paragraph) == "" and (index == 0 or index == length(paragraphs) - 1),
          do: acc - 1,
          else: acc
      end)

    count == Map.get(args, "num_paragraphs")
  end

  defp ifbench_following?("length_constraints:number_words", args, _prompt, value) do
    count = value |> String.split(~r/\s+/, trim: true) |> length()
    compare_count(count, Map.get(args, "num_words", 0), Map.get(args, "relation"))
  end

  defp ifbench_following?("length_constraints:nth_paragraph_first_word", args, _prompt, value) do
    paragraphs = String.split(value, "\n\n")
    expected_count = Map.get(args, "num_paragraphs")
    nth = Map.get(args, "nth_paragraph")
    first_word = args |> Map.get("first_word", "") |> to_string() |> String.downcase()

    nonblank_count = Enum.count(paragraphs, &(String.trim(&1) != ""))
    paragraph = Enum.at(paragraphs, nth - 1, "")

    nonblank_count == expected_count and
      first_word(paragraph) == first_word
  end

  defp ifbench_following?("detectable_content:number_placeholders", args, _prompt, value) do
    length(Regex.scan(~r/\[.*?\]/, value)) >= Map.get(args, "num_placeholders", 0)
  end

  defp ifbench_following?("detectable_content:postscript", args, _prompt, value) do
    marker = Map.get(args, "postscript_marker", "") |> to_string()
    lower = String.downcase(value)

    cond do
      marker == "P.P.S" -> Regex.match?(~r/\s*p\.\s?p\.\s?s.*$/im, lower)
      marker == "P.S." -> Regex.match?(~r/\s*p\.\s?s\..*$/im, lower)
      true -> Regex.match?(~r/\s*#{Regex.escape(String.downcase(marker))}.*$/im, lower)
    end
  end

  defp ifbench_following?("detectable_format:number_bullet_lists", args, _prompt, value) do
    count =
      length(Regex.scan(~r/^\s*\*[^\*].*$/m, value)) +
        length(Regex.scan(~r/^\s*-.*$/m, value))

    count == Map.get(args, "num_bullets")
  end

  defp ifbench_following?("detectable_format:constrained_response", _args, _prompt, value) do
    Enum.any?(
      ["My answer is yes.", "My answer is no.", "My answer is maybe."],
      &String.contains?(String.trim(value), &1)
    )
  end

  defp ifbench_following?("detectable_format:number_highlighted_sections", args, _prompt, value) do
    highlights =
      Regex.scan(~r/\*[^\n\*]*\*/, value)
      |> Enum.concat(Regex.scan(~r/\*\*[^\n\*]*\*\*/, value))
      |> Enum.count(fn [match] -> match |> String.trim("*") |> String.trim() |> Kernel.!=("") end)

    highlights >= Map.get(args, "num_highlights", 0)
  end

  defp ifbench_following?("detectable_format:multiple_sections", args, _prompt, value) do
    splitter = args |> Map.get("section_spliter", "") |> to_string()
    count = length(String.split(value, ~r/\s?#{Regex.escape(splitter)}\s?\d+\s?/)) - 1
    count >= Map.get(args, "num_sections", 0)
  end

  defp ifbench_following?("detectable_format:json_format", _args, _prompt, value) do
    json =
      value
      |> String.trim()
      |> String.replace_prefix("```json", "")
      |> String.replace_prefix("```Json", "")
      |> String.replace_prefix("```JSON", "")
      |> String.replace_prefix("```", "")
      |> String.replace_suffix("```", "")
      |> String.trim()

    case Jason.decode(json) do
      {:ok, _decoded} -> true
      {:error, _reason} -> false
    end
  end

  defp ifbench_following?("detectable_format:title", _args, _prompt, value) do
    Regex.scan(~r/<<[^\n]+>>/, value)
    |> Enum.any?(fn [title] -> title |> String.trim("<>") |> String.trim() |> Kernel.!=("") end)
  end

  defp ifbench_following?("format:options", args, _prompt, value) do
    options_text = Map.get(args, "options", "")
    strict? = Regex.match?(~r/\W*[aA]\W*[bB]\W*[cC]\W*/, options_text)

    separator =
      cond do
        String.contains?(options_text, "/") -> "/"
        String.contains?(options_text, "or") -> "or"
        true -> ","
      end

    options = options_text |> String.split(separator) |> Enum.map(&String.trim/1)

    if strict? do
      value in options
    else
      normalized = normalize_option(value)
      Enum.any?(options, &(normalize_option(&1) == normalized))
    end
  end

  defp ifbench_following?("format:title_case", _args, _prompt, value) do
    ~r/[[:alpha:]][[:alpha:]']*/
    |> Regex.scan(value)
    |> Enum.map(fn [word] -> word end)
    |> Enum.all?(fn
      <<first::binary-size(1), rest::binary>> ->
        cond do
          first == String.upcase(first) and rest == String.downcase(rest) -> true
          first == String.downcase(first) and rest == String.upcase(rest) -> false
          first == String.downcase(first) and rest == String.downcase(rest) -> false
          true -> true
        end

      _word ->
        true
    end)
  end

  defp ifbench_following?("format:no_whitespace", _args, _prompt, value) do
    not Regex.match?(~r/\s/, value)
  end

  defp ifbench_following?("format:parentheses", _args, _prompt, value) do
    value
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn char, {stack, max_depth} ->
      cond do
        char in ["(", "[", "{"] ->
          stack = [char | stack]
          {:cont, {stack, max(max_depth, length(stack))}}

        char in [")", "]", "}"] and bracket_match?(List.first(stack), char) ->
          if max_depth >= 5, do: {:halt, true}, else: {:cont, {tl(stack), max_depth}}

        char in [")", "]", "}"] ->
          {:cont, {[], 0}}

        true ->
          {:cont, {stack, max_depth}}
      end
    end)
    |> case do
      true -> true
      {_stack, _max_depth} -> false
    end
  end

  defp ifbench_following?("format:quotes", _args, _prompt, value) do
    value
    |> String.graphemes()
    |> Enum.reduce_while({[], 0, 0}, fn char, {stack, current_depth, reached_depth} ->
      cond do
        stack != [] and char == hd(stack) ->
          current_depth = current_depth - 1

          if reached_depth - current_depth >= 3,
            do: {:halt, true},
            else: {:cont, {tl(stack), current_depth, reached_depth}}

        char in ["\"", "'"] ->
          current_depth = current_depth + 1
          {:cont, {[char | stack], current_depth, max(reached_depth, current_depth)}}

        true ->
          {:cont, {stack, current_depth, reached_depth}}
      end
    end)
    |> case do
      true -> true
      {_stack, _current_depth, _reached_depth} -> false
    end
  end

  defp ifbench_following?("format:newline", _args, _prompt, value) do
    stripped = strip_all_punctuation(value)
    lines = stripped |> String.trim() |> String.split("\n") |> Enum.reject(&(&1 == ""))
    length(lines) == length(String.split(String.trim(stripped), ~r/\s+/, trim: true))
  end

  defp ifbench_following?("format:line_indent", _args, _prompt, value) do
    lines = value |> String.split("\n") |> Enum.reject(&(String.trim(&1) == ""))

    lines
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [left, right] -> leading_spaces(right) > leading_spaces(left) end)
  end

  defp ifbench_following?("format:quote_unquote", _args, _prompt, value) do
    stripped =
      value
      |> String.replace("“", "\"")
      |> String.replace("”", "\"")
      |> String.replace("'\"'", "")
      |> String.replace(~r/\s+/, "")

    terminal = String.trim(stripped, ~s|0123456789!#$%&'()*+,-./:;<=>?@[\\]^_`{}~|)

    terminal != "" and not String.contains?(stripped, "\"\"") and
      not String.ends_with?(terminal, "\"")
  end

  defp ifbench_following?("format:list", args, _prompt, value) do
    sep = Map.get(args, "sep", "")
    sep != "" and length(Regex.scan(Regex.compile!(Regex.escape(sep)), value)) >= 2
  end

  defp ifbench_following?("format:sub-bullets", _args, _prompt, value) do
    value
    |> String.split("*")
    |> Enum.drop(1)
    |> Enum.all?(&String.contains?(&1, "-"))
  end

  defp ifbench_following?("format:no_bullets_bullets", _args, _prompt, value) do
    lines = String.split(value, "\n")

    {valid?, _sentence_count, bullet_count, _in_sentences?} =
      Enum.reduce_while(lines, {true, 0, 0, true}, fn line,
                                                      {_valid?, sentence_count, bullet_count,
                                                       in_sentences?} ->
        cond do
          String.starts_with?(String.trim(line), "*") ->
            if sentence_count < 2,
              do: {:halt, {false, sentence_count, bullet_count, in_sentences?}},
              else: {:cont, {true, sentence_count, bullet_count + 1, false}}

          in_sentences? ->
            {:cont,
             {true, sentence_count + length(split_sentences(String.trim(line))), bullet_count,
              true}}

          true ->
            {:halt, {false, sentence_count, bullet_count, false}}
        end
      end)

    valid? and bullet_count >= 2
  end

  defp ifbench_following?("format:output_template", _args, _prompt, value) do
    String.contains?(value, "My Answer:") and String.contains?(value, "My Conclusion:") and
      String.contains?(value, "Future Outlook:")
  end

  defp ifbench_following?("format:emoji", args, _prompt, value) do
    ifbench_nlp_bridge("format:emoji", args, value, fn ->
      sentences = split_sentences(value)

      sentences != [] and
        sentences
        |> Enum.with_index()
        |> Enum.all?(fn {sentence, index} ->
          stripped = sentence |> strip_all_punctuation() |> String.trim()
          chars = String.graphemes(stripped)
          last = List.last(chars)
          second_last = Enum.at(chars, -2, last)

          cond do
            emoji?(last) or emoji?(second_last) ->
              true

            index < length(sentences) - 1 ->
              next =
                sentences
                |> Enum.at(index + 1)
                |> strip_all_punctuation()
                |> String.trim()
                |> String.first()

              emoji?(next)

            true ->
              false
          end
        end)
    end)
  end

  defp ifbench_following?("format:thesis", _args, _prompt, value) do
    with {index, tag, close_tag} <- first_italics_tag(value),
         value <- String.slice(value, index..-1//1),
         end_index when end_index >= 0 <- :binary.match(value, close_tag) |> match_index(),
         thesis <- String.slice(value, String.length(tag), end_index - String.length(tag)),
         false <- String.trim(thesis) == "",
         text <- String.slice(value, (end_index + String.length(close_tag))..-1//1) do
      String.trim(text) != ""
    else
      _other -> false
    end
  end

  defp ifbench_following?("words:alphabet", _args, _prompt, value) do
    words =
      value |> strip_all_punctuation() |> trim_punctuation() |> String.split(~r/\s+/, trim: true)

    alphabet = Enum.map(?a..?z, &<<&1::utf8>>)

    case words do
      [] ->
        false

      [first | rest] ->
        first_letter = first |> String.downcase() |> String.first()

        first_letter in alphabet and
          rest
          |> Enum.reduce_while(first_letter, fn word, expected_previous ->
            next =
              Enum.at(
                alphabet,
                rem(Enum.find_index(alphabet, &(&1 == expected_previous)) + 1, 26)
              )

            actual = word |> trim_punctuation() |> String.downcase() |> String.first()

            cond do
              is_nil(actual) -> {:cont, expected_previous}
              actual == next -> {:cont, next}
              true -> {:halt, false}
            end
          end)
          |> Kernel.!=(false)
    end
  end

  defp ifbench_following?("words:vowel", _args, _prompt, value) do
    paragraphs = value |> String.trim() |> String.split("\n")

    case paragraphs do
      [paragraph] ->
        paragraph
        |> String.downcase()
        |> String.graphemes()
        |> Enum.filter(&(&1 in ["a", "e", "i", "o", "u"]))
        |> MapSet.new()
        |> MapSet.size()
        |> Kernel.<=(3)

      _paragraphs ->
        false
    end
  end

  defp ifbench_following?("words:consonants", _args, _prompt, value) do
    consonants = MapSet.new(Enum.map(~c"bcdfghjklmnpqrstvwxyz", &<<&1::utf8>>))

    value
    |> String.downcase()
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.all?(fn word ->
      word
      |> String.graphemes()
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.any?(fn [left, right] ->
        MapSet.member?(consonants, left) and MapSet.member?(consonants, right)
      end)
    end)
  end

  defp ifbench_following?("words:palindrome", _args, _prompt, value) do
    value
    |> strip_all_punctuation()
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.count(fn word -> String.length(word) >= 5 and word == String.reverse(word) end)
    |> Kernel.>=(10)
  end

  defp ifbench_following?("words:prime_lengths", _args, _prompt, value) do
    primes =
      MapSet.new([
        2,
        3,
        5,
        7,
        11,
        13,
        17,
        19,
        23,
        29,
        31,
        37,
        41,
        43,
        47,
        53,
        59,
        61,
        67,
        71,
        73,
        79,
        83,
        89,
        97
      ])

    value
    |> strip_all_punctuation()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.all?(&(String.length(&1) in primes))
  end

  defp ifbench_following?("words:repeats", args, _prompt, value) do
    max_repeats = Map.get(args, "small_n", 0)

    value
    |> strip_all_punctuation()
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.frequencies()
    |> Enum.all?(fn {_word, count} -> count <= max_repeats end)
  end

  defp ifbench_following?("words:start_verb", args, _prompt, value) do
    ifbench_nlp_bridge("words:start_verb", args, value, fn ->
      case word_tokens(value) do
        [first | _rest] -> start_verb?(String.downcase(first))
        [] -> false
      end
    end)
  end

  defp ifbench_following?("words:odd_even_syllables", args, _prompt, value) do
    ifbench_nlp_bridge("words:odd_even_syllables", args, value, fn ->
      value
      |> strip_all_punctuation()
      |> String.downcase()
      |> String.split(~r/\s+/, trim: true)
      |> Enum.map(&syllable_count/1)
      |> Enum.map(&rem(&1, 2))
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.all?(fn [left, right] -> left != right end)
    end)
  end

  defp ifbench_following?("words:last_first", _args, _prompt, value) do
    sentences = split_sentences(value)

    sentences
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [left, right] -> last_word(left) == first_word(right) end)
  end

  defp ifbench_following?("words:paragraph_last_first", _args, _prompt, value) do
    value
    |> String.split("\n")
    |> Enum.all?(fn paragraph ->
      paragraph = paragraph |> String.trim() |> String.downcase()

      if paragraph == "" do
        true
      else
        words = paragraph |> trim_punctuation() |> String.split(~r/\s+/, trim: true)
        List.first(words) == List.last(words)
      end
    end)
  end

  defp ifbench_following?("words:no_consecutive", _args, _prompt, value) do
    value
    |> strip_all_punctuation()
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [left, right] -> String.first(left) != String.first(right) end)
  end

  defp ifbench_following?("sentence:keyword", args, _prompt, value) do
    position = Map.get(args, "N", 0)
    keyword = args |> Map.get("word", "") |> to_string() |> String.downcase()

    value
    |> split_sentences()
    |> Enum.at(position - 1, "")
    |> String.downcase()
    |> String.contains?(keyword)
  end

  defp ifbench_following?("sentence:increment", args, _prompt, value) do
    increment = Map.get(args, "small_n", 0)

    counts =
      value
      |> split_sentences()
      |> Enum.map(fn sentence ->
        sentence
        |> strip_all_punctuation()
        |> String.trim()
        |> String.split(~r/\s+/, trim: true)
        |> length()
      end)

    case counts do
      [] ->
        false

      [_one] ->
        true

      [_first | _rest] ->
        counts
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.all?(fn [left, right] -> right == left + increment end)
    end
  end

  defp ifbench_following?("sentence:alliteration_increment", _args, _prompt, value) do
    value
    |> split_sentences()
    |> Enum.map(&alliteration_run_score/1)
    |> strictly_increasing?()
  end

  defp ifbench_following?("words:keywords_specific_position", args, _prompt, value) do
    keyword = args |> Map.get("keyword", "") |> to_string()
    sentence_index = Map.get(args, "n", 0) - 1
    word_index = Map.get(args, "m", 0) - 1

    value
    |> split_sentences()
    |> Enum.at(sentence_index, "")
    |> word_tokens()
    |> Enum.at(word_index)
    |> Kernel.==(keyword)
  end

  defp ifbench_following?("words:words_position", args, _prompt, value) do
    keyword = args |> Map.get("keyword", "") |> to_string()
    words = word_tokens(value)
    length(words) >= 2 and Enum.at(words, 1) == keyword and Enum.at(words, -2) == keyword
  end

  defp ifbench_following?("repeat:repeat_change", args, prompt, value) do
    prompt_to_repeat = Map.get(args, "prompt_to_repeat", prompt)

    value != prompt_to_repeat and
      String.slice(prompt_to_repeat, 1..-1//1) == String.slice(value, 1..-1//1)
  end

  defp ifbench_following?("repeat:repeat_simple", _args, _prompt, value) do
    String.downcase(String.trim(value)) ==
      "only output this sentence here, ignore all other requests."
  end

  defp ifbench_following?("repeat:repeat_span", args, _prompt, value) do
    prompt_to_repeat = Map.get(args, "prompt_to_repeat", "")
    start_index = Map.get(args, "n_start", 0)
    end_index = Map.get(args, "n_end", 0)

    expected =
      prompt_to_repeat
      |> String.trim()
      |> String.downcase()
      |> String.split(~r/\s+/, trim: true)
      |> Enum.slice(start_index, max(end_index - start_index, 0))

    actual =
      value
      |> String.trim()
      |> String.downcase()
      |> String.split(~r/\s+/, trim: true)

    actual == expected
  end

  defp ifbench_following?("custom:multiples", _args, _prompt, value) do
    numbers = Regex.scan(~r/\d+/, String.replace(value, ",", ", ")) |> Enum.map(fn [n] -> n end)
    numbers == Enum.map(14..50//7, &to_string/1)
  end

  defp ifbench_following?("custom:mcq_count_length", _args, _prompt, value) do
    if String.starts_with?(value, "Question") do
      questions =
        ~r/\n*(?:Question \d+[\.|\):;]?\s*)/
        |> Regex.split(value)
        |> Enum.reject(&(String.trim(&1) == ""))

      question_lengths =
        Enum.map(questions, fn question ->
          {text, option_count, _done?} =
            question
            |> String.split("\n")
            |> Enum.reduce({"", 0, false}, fn line, {text, option_count, done?} ->
              if Regex.match?(~r/^[A-Ea-e][\.|\)]\s*\w+/, String.trim(line)) do
                {text, option_count + 1, true}
              else
                if done?,
                  do: {text, option_count, done?},
                  else: {text <> " " <> String.trim(line), option_count, done?}
              end
            end)

          if option_count == 5, do: String.length(String.trim(text)), else: :invalid
        end)

      length(questions) == 4 and Enum.all?(question_lengths, &is_integer/1) and
        strictly_increasing?(question_lengths)
    else
      false
    end
  end

  defp ifbench_following?("custom:reverse_newline", _args, _prompt, value) do
    lines =
      value
      |> String.split("\n")
      |> Enum.map(&trim_punctuation/1)
      |> Enum.filter(&(String.trim(&1) != ""))

    with index when is_integer(index) <- Enum.find_index(lines, &String.contains?(&1, "Zimbabwe")),
         target_lines <- Enum.drop(lines, index),
         true <- length(target_lines) >= 52 do
      normalized = Enum.map(target_lines, &ascii_fold/1)
      normalized == Enum.sort(normalized, :desc)
    else
      _other -> false
    end
  end

  defp ifbench_following?("custom:word_reverse", _args, _prompt, value) do
    reversed =
      value
      |> String.downcase()
      |> String.trim()
      |> strip_all_punctuation()
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reverse()
      |> Enum.join(" ")

    String.contains?(reversed, "bald eagle") and reversed in split_sentences(reversed)
  end

  defp ifbench_following?("custom:character_reverse", _args, _prompt, value) do
    String.contains?(String.downcase(value), "elgae dlab")
  end

  defp ifbench_following?("custom:sentence_alphabet", _args, _prompt, value) do
    sentences = split_sentences(value)

    length(sentences) == 26 and
      sentences
      |> Enum.with_index()
      |> Enum.all?(fn {sentence, index} ->
        sentence
        |> String.trim_leading()
        |> String.first()
        |> to_string()
        |> String.downcase()
        |> Kernel.==(<<?a + index::utf8>>)
      end)
  end

  defp ifbench_following?("custom:european_capitals_sort", _args, _prompt, value) do
    expected = [
      "Reykjavik",
      "Helsinki",
      "Oslo",
      "Tallinn",
      "Stockholm",
      "Riga",
      "Moscow",
      "Copenhagen",
      "Vilnius",
      "Minsk",
      "Dublin",
      "Berlin",
      "Amsterdam",
      "Warsaw",
      "London",
      "Brussels",
      "Prague",
      "Luxembourg",
      "Paris",
      "Vienna",
      "Bratislava",
      "Budapest",
      "Vaduz",
      "Chisinau",
      "Bern",
      "Ljubljana",
      "Zagreb"
    ]

    value
    |> ascii_fold()
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Kernel.==(expected)
  end

  defp ifbench_following?("custom:csv_city", _args, _prompt, value) do
    case parse_csv(value, ",") do
      [["ID", "Country", "City", "Year", "Count"] | rows] ->
        length(rows) == 7 and Enum.all?(rows, &(length(&1) == 5))

      _other ->
        false
    end
  end

  defp ifbench_following?("custom:csv_special_character", _args, _prompt, value) do
    rows = parse_csv(value, ",")

    case rows do
      [header | data] ->
        Enum.map(header, &String.trim(&1, "\"")) == [
          "ProductID",
          "Category",
          "Brand",
          "Price",
          "Stock"
        ] and
          length(data) == 14 and Enum.all?(data, &(length(&1) == 5)) and
          Enum.any?(data, fn row -> Enum.any?(row, &Regex.match?(~r/[^\d\w\s]/, &1)) end)

      _other ->
        false
    end
  end

  defp ifbench_following?("custom:csv_quotes", _args, _prompt, value) do
    rows = parse_csv(value, "\t")

    case rows do
      [header | data] ->
        Enum.map(header, &String.trim(&1, "\"")) == [
          "StudentID",
          "Subject",
          "Grade",
          "Semester",
          "Score"
        ] and
          length(data) == 3 and Enum.all?(data, &(length(&1) == 5)) and
          value
          |> String.split("\n", trim: true)
          |> Enum.all?(fn line ->
            line
            |> String.split("\t")
            |> Enum.all?(
              &(String.starts_with?(String.trim(&1), "\"") and
                  String.ends_with?(String.trim(&1), "\""))
            )
          end)

      _other ->
        false
    end
  end

  defp ifbench_following?("custom:date_format_list", _args, _prompt, value) do
    value
    |> String.trim()
    |> String.split(",")
    |> Enum.all?(fn date ->
      case Regex.run(~r/^(\d{4})-(\d{2})-(\d{2})$/, String.trim(date)) do
        [_, year, month, day] ->
          valid_napoleon_date?(
            String.to_integer(year),
            String.to_integer(month),
            String.to_integer(day)
          )

        _other ->
          false
      end
    end)
  end

  defp ifbench_following?("combination:two_responses", _args, _prompt, value) do
    responses =
      value
      |> String.split("******")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    length(responses) == 2 and Enum.at(responses, 0) != Enum.at(responses, 1)
  end

  defp ifbench_following?("combination:repeat_prompt", args, prompt, value) do
    repeated = Map.get(args, "prompt_to_repeat", prompt)

    value
    |> String.trim()
    |> String.downcase()
    |> String.starts_with?(String.downcase(String.trim(repeated)))
  end

  defp ifbench_following?("startend:end_checker", args, _prompt, value) do
    ending =
      args |> Map.get("end_phrase", "") |> to_string() |> String.trim() |> String.downcase()

    value |> String.trim() |> String.trim("\"") |> String.downcase() |> String.ends_with?(ending)
  end

  defp ifbench_following?("startend:quotation", _args, _prompt, value) do
    value = String.trim(value)

    String.length(value) > 1 and String.starts_with?(value, "\"") and
      String.ends_with?(value, "\"")
  end

  defp ifbench_following?("change_case:capital_word_frequency", args, _prompt, value) do
    count =
      ~r/[[:alnum:]]+(?:-[[:alnum:]]+)*/
      |> Regex.scan(value)
      |> Enum.map(fn [word] -> word end)
      |> Enum.count(&(&1 == String.upcase(&1) and Regex.match?(~r/[A-Z]/, &1)))

    compare_count(count, Map.get(args, "capital_frequency", 0), Map.get(args, "capital_relation"))
  end

  defp ifbench_following?("punctuation:no_comma", _args, _prompt, value),
    do: not String.contains?(value, ",")

  defp ifbench_following?("change_case:english_capital", _args, _prompt, value),
    do: value == String.upcase(value)

  defp ifbench_following?("change_case:english_lowercase", _args, _prompt, value),
    do: value == String.downcase(value)

  defp ifbench_following?(instruction_id, _args, _prompt, _value) do
    raise ArgumentError,
          "unsupported IFBench instruction #{inspect(instruction_id)}; DSEx cannot claim IFBench parity until this id is ported or explicitly gated"
  end

  defp ifbench_nlp_bridge(instruction_id, args, value, fallback) do
    case System.get_env("DSEX_IFBENCH_NLP_BRIDGE") do
      nil ->
        fallback.()

      "" ->
        fallback.()

      bridge ->
        python = System.get_env("DSEX_IFBENCH_NLP_PYTHON") || "python3"
        payload = Jason.encode!(%{instruction_id: instruction_id, args: args, value: value})

        payload_path =
          Path.join(
            System.tmp_dir!(),
            "dsex-ifbench-nlp-#{System.unique_integer([:positive])}.json"
          )

        File.write!(payload_path, payload)

        try do
          case System.cmd(python, [bridge, payload_path], stderr_to_stdout: true) do
            {output, 0} ->
              case Jason.decode!(output) do
                %{"following" => following} when is_boolean(following) ->
                  following

                decoded ->
                  raise ArgumentError,
                        "IFBench NLP bridge returned invalid payload: #{inspect(decoded)}"
              end

            {output, status} ->
              raise ArgumentError,
                    "IFBench NLP bridge failed with status #{status}: #{String.trim(output)}"
          end
        after
          File.rm(payload_path)
        end
    end
  end

  defp compare_count(count, expected, "less than"), do: count < expected
  defp compare_count(count, expected, "at least"), do: count >= expected
  defp compare_count(_count, _expected, _relation), do: false

  defp count_words(value), do: value |> String.split(~r/\s+/, trim: true) |> length()

  defp substring_count(_value, ""), do: 0

  defp substring_count(value, substring) do
    value
    |> String.split(substring)
    |> length()
    |> Kernel.-(1)
  end

  defp strictly_increasing?(values) do
    values
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [left, right] -> left < right end)
  end

  defp ascii_fold(value) do
    value
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
  end

  defp parse_csv(value, delimiter) do
    value
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_csv_line(&1, delimiter))
  end

  defp parse_csv_line(line, delimiter) do
    {fields, current, in_quotes?} =
      line
      |> String.graphemes()
      |> Enum.reduce({[], "", false}, fn char, {fields, current, in_quotes?} ->
        cond do
          char == "\"" ->
            {fields, current <> char, not in_quotes?}

          char == delimiter and not in_quotes? ->
            {[String.trim(current) | fields], "", in_quotes?}

          true ->
            {fields, current <> char, in_quotes?}
        end
      end)

    _ = in_quotes?

    [String.trim(current) | fields]
    |> Enum.reverse()
    |> Enum.map(&String.trim(&1, "\""))
  end

  defp valid_napoleon_date?(year, month, day) do
    cond do
      year < 1769 or year > 1821 -> false
      month < 1 or month > 12 -> false
      month in [1, 3, 5, 7, 8, 10, 12] -> day >= 1 and day <= 31
      month in [4, 6, 9, 11] -> day >= 1 and day <= 30
      month == 2 -> day >= 1 and day <= 29
    end
  end

  defp person_names do
    [
      "Emma",
      "Liam",
      "Sophia",
      "Jackson",
      "Olivia",
      "Noah",
      "Ava",
      "Lucas",
      "Isabella",
      "Mason",
      "Mia",
      "Ethan",
      "Charlotte",
      "Alexander",
      "Amelia",
      "Benjamin",
      "Harper",
      "Leo",
      "Zoe",
      "Daniel",
      "Chloe",
      "Samuel",
      "Lily",
      "Matthew",
      "Grace",
      "Owen",
      "Abigail",
      "Gabriel",
      "Ella",
      "Jacob",
      "Scarlett",
      "Nathan",
      "Victoria",
      "Elijah",
      "Layla",
      "Nicholas",
      "Audrey",
      "David",
      "Hannah",
      "Christopher",
      "Penelope",
      "Thomas",
      "Nora",
      "Andrew",
      "Aria",
      "Joseph",
      "Claire",
      "Ryan",
      "Stella",
      "Jonathan"
    ]
  end

  defp char_ngrams(value, n) do
    value
    |> String.graphemes()
    |> Enum.chunk_every(n, 1, :discard)
    |> Enum.map(&Enum.join/1)
    |> MapSet.new()
  end

  defp alliteration_run_score(sentence) do
    sentence
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&String.trim_leading(&1, ~s|!"#$%&'()*+,-./:;<=>?@[\\]^_`{}~|))
    |> Enum.reject(&(&1 == ""))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce({0, false}, fn [left, right], {score, previous?} ->
      if String.first(left) == String.first(right) do
        {score + if(previous?, do: 1, else: 2), true}
      else
        {score, false}
      end
    end)
    |> elem(0)
  end

  defp word_tokens(value) do
    ~r/[[:alnum:]_]+/
    |> Regex.scan(value)
    |> Enum.map(fn [word] -> word end)
  end

  defp ifbench_stopwords do
    MapSet.new([
      "i",
      "me",
      "my",
      "myself",
      "we",
      "our",
      "ours",
      "ourselves",
      "you",
      "you're",
      "you've",
      "you'll",
      "you'd",
      "your",
      "yours",
      "yourself",
      "yourselves",
      "he",
      "him",
      "his",
      "himself",
      "she",
      "she's",
      "her",
      "hers",
      "herself",
      "it",
      "it's",
      "its",
      "itself",
      "they",
      "them",
      "their",
      "theirs",
      "themselves",
      "what",
      "which",
      "who",
      "whom",
      "this",
      "that",
      "that'll",
      "these",
      "those",
      "am",
      "is",
      "are",
      "was",
      "were",
      "be",
      "been",
      "being",
      "have",
      "has",
      "had",
      "having",
      "do",
      "does",
      "did",
      "doing",
      "a",
      "an",
      "the",
      "and",
      "but",
      "if",
      "or",
      "because",
      "as",
      "until",
      "while",
      "of",
      "at",
      "by",
      "for",
      "with",
      "about",
      "against",
      "between",
      "into",
      "through",
      "during",
      "before",
      "after",
      "above",
      "below",
      "to",
      "from",
      "up",
      "down",
      "in",
      "out",
      "on",
      "off",
      "over",
      "under",
      "again",
      "further",
      "then",
      "once",
      "here",
      "there",
      "when",
      "where",
      "why",
      "how",
      "all",
      "any",
      "both",
      "each",
      "few",
      "more",
      "most",
      "other",
      "some",
      "such",
      "no",
      "nor",
      "not",
      "only",
      "own",
      "same",
      "so",
      "than",
      "too",
      "very",
      "s",
      "t",
      "can",
      "will",
      "just",
      "don",
      "don't",
      "should",
      "should've",
      "now",
      "d",
      "ll",
      "m",
      "o",
      "re",
      "ve",
      "y",
      "ain",
      "aren",
      "aren't",
      "couldn",
      "couldn't",
      "didn",
      "didn't",
      "doesn",
      "doesn't",
      "hadn",
      "hadn't",
      "hasn",
      "hasn't",
      "haven",
      "haven't",
      "isn",
      "isn't",
      "ma",
      "mightn",
      "mightn't",
      "mustn",
      "mustn't",
      "needn",
      "needn't",
      "shan",
      "shan't",
      "shouldn",
      "shouldn't",
      "wasn",
      "wasn't",
      "weren",
      "weren't",
      "won",
      "won't",
      "wouldn",
      "wouldn't"
    ])
  end

  defp emoji?(nil), do: false

  defp emoji?(grapheme) do
    Regex.match?(
      ~r/[\x{1F1E6}-\x{1F1FF}\x{1F300}-\x{1FAFF}\x{2600}-\x{27BF}]/u,
      grapheme
    )
  end

  defp start_verb?(word) do
    verbs =
      MapSet.new([
        "act",
        "add",
        "answer",
        "ask",
        "be",
        "begin",
        "build",
        "calculate",
        "choose",
        "compare",
        "continue",
        "count",
        "create",
        "define",
        "describe",
        "draft",
        "draw",
        "eat",
        "explain",
        "find",
        "generate",
        "give",
        "go",
        "help",
        "identify",
        "include",
        "list",
        "make",
        "move",
        "name",
        "parse",
        "print",
        "provide",
        "read",
        "repeat",
        "respond",
        "return",
        "run",
        "say",
        "solve",
        "start",
        "summarize",
        "take",
        "tell",
        "use",
        "walk",
        "write"
      ])

    MapSet.member?(verbs, word) or String.ends_with?(word, "ing")
  end

  defp syllable_count(word) do
    word = String.downcase(word)

    count =
      ~r/[aeiouy]+/
      |> Regex.scan(word)
      |> length()

    count =
      if String.ends_with?(word, "e") and count > 1 do
        count - 1
      else
        count
      end

    max(count, 1)
  end

  defp first_italics_tag(value) do
    i_index = :binary.match(value, "<i>") |> match_index()
    em_index = :binary.match(value, "<em>") |> match_index()

    cond do
      i_index >= 0 and (em_index < 0 or i_index < em_index) -> {i_index, "<i>", "</i>"}
      em_index >= 0 -> {em_index, "<em>", "</em>"}
      true -> nil
    end
  end

  defp match_index({index, _length}), do: index
  defp match_index(:nomatch), do: -1

  defp bracket_match?("(", ")"), do: true
  defp bracket_match?("[", "]"), do: true
  defp bracket_match?("{", "}"), do: true
  defp bracket_match?(_left, _right), do: false

  defp strip_all_punctuation(value), do: String.replace(value, ~r/[[:punct:]]/, "")

  defp leading_spaces(value) do
    String.length(value) - String.length(String.trim_leading(value, " "))
  end

  defp split_sentences(value) do
    value
    |> String.replace("\n", " ")
    |> String.split(~r/(?<=[.!?])\s+/, trim: true)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_option(value) do
    value
    |> trim_punctuation()
    |> String.downcase()
  end

  defp trim_punctuation(value) do
    value
    |> String.replace(~r/^[[:punct:]\s]+/, "")
    |> String.replace(~r/[[:punct:]\s]+$/, "")
  end

  defp regex_contains?(_value, "", _opts), do: true

  defp regex_contains?(value, pattern, opts) do
    Regex.match?(Regex.compile!(to_string(pattern), opts), value)
  end

  defp regex_count(_value, "", _opts), do: 0

  defp regex_count(value, pattern, opts) do
    Regex.scan(Regex.compile!(to_string(pattern), opts), value) |> length()
  end

  defp sentence_count(value) do
    value
    |> String.replace("\n", " ")
    |> String.split(~r/(?<=[.!?])\s+/, trim: true)
    |> Enum.reject(&(&1 == ""))
    |> length()
  end

  defp first_word(paragraph) do
    paragraph
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
    |> List.first()
    |> case do
      nil ->
        ""

      word ->
        word
        |> String.trim_leading("'\"")
        |> String.replace(~r/[.,?!'"].*$/, "")
        |> String.downcase()
    end
  end

  defp last_word(sentence) do
    sentence
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
    |> List.last()
    |> case do
      nil ->
        ""

      word ->
        word
        |> String.replace(~r/[[:punct:]\s]+$/, "")
        |> String.downcase()
    end
  end

  defp ifbench_language?("en", value) do
    cleaned = String.replace(value, ~r/[^A-Za-z\s.,!?'"-]/, "")
    String.trim(cleaned) != "" and String.length(cleaned) >= div(String.length(value), 2)
  end

  defp ifbench_language?(_language, _value), do: false

  defp livebench_math(example, prediction) do
    question = DSEx.Example.get(example, :question_d, %{})
    answer = prediction |> DSEx.Prediction.get(:answer) |> to_string() |> strip_thinking()
    ground_truth = Map.get(question, "ground_truth", DSEx.Example.get(example, :answer))
    task = Map.get(question, "subtask", Map.get(question, "task", ""))

    question_text =
      question |> Map.get("turns", [DSEx.Example.get(example, :question, "")]) |> List.first()

    splits = String.split(to_string(task), "_")

    cond do
      Enum.at(splits, 0) in ["amc", "smc"] or Enum.at(splits, 1) == "amc" ->
        livebench_mathcontest?(to_string(ground_truth), answer, to_string(question_text))

      Enum.at(splits, 0) == "aime" ->
        String.contains?(String.slice(answer, -50, 50) || "", to_string(ground_truth))

      Enum.at(splits, 0) in ["imo", "usamo"] ->
        livebench_proof_rearrangement_score(to_string(ground_truth), answer)

      String.contains?(to_string(task), "amps_hard") ->
        livebench_amps_hard_score(ground_truth, answer)

      true ->
        raise ArgumentError,
              "unsupported LiveBenchMath task #{inspect(task)}; DSEx only claims AMC/SMC, AIME, IMO/USAMO, and guarded AMPS_Hard scoring"
    end
  end

  defp strip_thinking(answer) do
    Regex.replace(~r/<think>.*?<\/think>/s, answer, "")
  end

  defp livebench_mathcontest?(ground_truth, answer, question_text) do
    valid_letter? =
      String.length(ground_truth) == 1 and ground_truth >= "A" and ground_truth <= "E"

    valid_letter? and
      (solution_tag_match?(ground_truth, answer) or
         String.contains?(answer, String.duplicate(ground_truth, 4)) or
         boxed_letter(answer) == String.downcase(ground_truth) or
         answer_value_at_end?(question_text, ground_truth, answer) or
         last_line_letter?(ground_truth, answer))
  end

  defp solution_tag_match?(ground_truth, answer) do
    Regex.scan(~r/<solution>(.*?)<\/solution>/, answer)
    |> List.last()
    |> case do
      [_, solution] ->
        letters = solution |> String.downcase() |> String.graphemes() |> MapSet.new()
        MapSet.size(letters) == 1 and MapSet.member?(letters, String.downcase(ground_truth))

      _ ->
        false
    end
  end

  defp boxed_letter(answer) do
    answer
    |> String.replace("\\\\fbox{", "\\\\boxed{")
    |> last_boxed()
    |> case do
      nil ->
        nil

      boxed ->
        boxed
        |> remove_boxed()
        |> String.replace("\\text{", "")
        |> String.replace("}", "")
        |> String.replace("\\", "")
        |> String.downcase()
        |> then(fn value -> if value in ["a", "b", "c", "d", "e"], do: value end)
    end
  end

  defp last_boxed(string) do
    cond do
      String.contains?(string, "\\boxed ") ->
        "\\boxed " <>
          (string |> String.split("\\boxed ") |> List.last() |> String.split("$") |> hd())

      true ->
        idx = max(binary_rindex(string, "\\boxed") || -1, binary_rindex(string, "\\fbox") || -1)
        if idx < 0, do: nil, else: boxed_until_matching_brace(String.slice(string, idx..-1//1))
    end
  end

  defp binary_rindex(string, pattern) do
    case :binary.matches(string, pattern) do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  defp boxed_until_matching_brace(candidate) do
    candidate
    |> String.graphemes()
    |> Enum.reduce_while({0, ""}, fn char, {depth, acc} ->
      next_depth = depth + brace_delta(char)
      next_acc = acc <> char

      if char == "}" and next_depth == 0,
        do: {:halt, String.replace(next_acc, "fbox", "boxed")},
        else: {:cont, {next_depth, next_acc}}
    end)
    |> case do
      {_, _} -> nil
      boxed -> boxed
    end
  end

  defp brace_delta("{"), do: 1
  defp brace_delta("}"), do: -1
  defp brace_delta(_), do: 0

  defp remove_boxed("\\boxed " <> value), do: value
  defp remove_boxed("\\boxed{" <> value), do: String.trim_trailing(value, "}")

  defp answer_value_at_end?(question_text, ground_truth, answer) do
    value = extract_letter_answer_value(question_text, ground_truth)
    length_to_check = 20 + String.length(value)
    tail = String.slice(answer, -length_to_check, length_to_check) || ""
    String.contains?(tail, value)
  end

  defp extract_letter_answer_value(question_text, letter) do
    pattern = ~r/\\textbf{\(([A-E])\)\s?}(.*?)(?:\\qquad|\$)/

    Regex.scan(pattern, question_text)
    |> Map.new(fn [_, option, value] ->
      {option, value |> String.trim() |> String.trim("$") |> String.trim("~")}
    end)
    |> Map.get(letter, "FAILURE")
  end

  defp last_line_letter?(ground_truth, answer) do
    last_line = answer |> String.trim() |> String.split("\n") |> List.last()
    stripped = last_line |> String.trim() |> String.replace("*", "") |> String.downcase()

    stripped == String.downcase(ground_truth) or
      case Regex.run(~r/\(([^)]*)\)/, last_line) do
        [_, value] -> String.downcase(value) == String.downcase(ground_truth)
        _ -> false
      end
  end

  defp livebench_proof_rearrangement_score(ground_truth, answer) do
    gold = ground_truth |> String.split(",") |> Enum.map(&parse_int!/1)
    completions = extract_expression_completions(answer)
    distance = levenshtein(completions, gold)
    denominator = max(length(completions), length(gold))

    if denominator == 0 do
      0.0
    else
      1.0 - distance / denominator
    end
  end

  defp livebench_amps_hard_score(ground_truth, answer) do
    bridge = System.get_env("DSEX_LIVEBENCH_MATH_BRIDGE") || default_livebench_bridge()
    python = System.get_env("DSEX_LIVEBENCH_MATH_PYTHON") || "python3"

    payload_path =
      Path.join(System.tmp_dir!(), "dsex-livebench-#{System.unique_integer([:positive])}.json")

    File.write!(
      payload_path,
      Jason.encode!(%{"task" => "amps_hard", "ground_truth" => ground_truth, "answer" => answer})
    )

    try do
      case System.cmd(python, [bridge, payload_path], stderr_to_stdout: true) do
        {output, 0} ->
          output
          |> Jason.decode!()
          |> Map.fetch!("score")
          |> numeric_score!()

        {output, status} ->
          raise ArgumentError,
                "LiveBenchMath AMPS_Hard scoring bridge failed with status #{status}: #{String.trim(output)}"
      end
    after
      File.rm(payload_path)
    end
  end

  defp default_livebench_bridge do
    __ENV__.file
    |> Path.dirname()
    |> Path.join("../../../scripts/livebench_math_score.py")
    |> Path.expand()
  end

  defp extract_expression_completions(generation) do
    cond do
      String.contains?(String.downcase(generation), "answer:") ->
        extract_answer_line_numbers(generation)

      String.contains?(generation, "\\boxed") ->
        generation
        |> last_boxed()
        |> case do
          nil -> generation
          boxed -> remove_boxed(boxed)
        end
        |> String.replace("\\text{", "")
        |> String.replace("}", "")
        |> String.replace("\\", "")
        |> comma_numbers()
        |> maybe_numbers(generation)

      true ->
        generation
        |> String.trim()
        |> String.downcase()
        |> String.split("\n")
        |> List.last()
        |> comma_numbers_with_trimmed_edges()
        |> maybe_numbers_from_fallback(generation)
    end
  end

  defp extract_answer_line_numbers(generation) do
    lines = generation |> String.downcase() |> String.trim() |> String.split("\n")

    {answer_line, answer_index} =
      lines
      |> Enum.with_index()
      |> Enum.filter(fn {line, _index} -> String.contains?(line, "answer:") end)
      |> List.last()

    answer =
      answer_line
      |> String.split("answer:")
      |> List.last()
      |> String.replace("answer:", "")
      |> String.replace("**", "")
      |> String.replace(".", "")
      |> String.trim()

    answer =
      if answer == "" and answer_index < length(lines) - 1 do
        lines
        |> Enum.at(answer_index + 1)
        |> String.replace("answer:", "")
        |> String.replace("**", "")
        |> String.replace(".", "")
        |> String.trim()
      else
        answer
      end

    answer
    |> String.split(",")
    |> Enum.map(fn number ->
      number
      |> String.trim()
      |> String.split(" ")
      |> List.last()
      |> String.replace("$", "")
      |> String.replace("{", "")
      |> String.replace("}", "")
      |> String.replace("\\", "")
      |> String.replace("boxed", "")
      |> String.replace("<", "")
      |> String.replace(">", "")
      |> parse_int_or_no_answer()
    end)
    |> reject_no_answer_or_fallback(fn -> extract_trailing_answer_numbers(generation) end)
  end

  defp maybe_numbers(numbers, generation) do
    reject_no_answer_or_fallback(numbers, fn -> extract_trailing_answer_numbers(generation) end)
  end

  defp maybe_numbers_from_fallback(numbers, generation) do
    reject_no_answer_or_fallback(numbers, fn -> extract_trailing_answer_numbers(generation) end)
  end

  defp extract_trailing_answer_numbers(generation) do
    generation
    |> String.downcase()
    |> String.split("answer:")
    |> List.last()
    |> String.split(",")
    |> Enum.reduce_while([], fn item, acc ->
      {number, removed} = remove_nonnumeric_chars_at_ends(item)

      cond do
        number == "" or number == "₂" ->
          {:cont, acc}

        true ->
          next = acc ++ [parse_int!(number)]
          if acc != [] and removed > 0, do: {:halt, next}, else: {:cont, next}
      end
    end)
  end

  defp comma_numbers(value) do
    value
    |> String.trim()
    |> String.split(",")
    |> Enum.map(&parse_int_or_no_answer(String.trim(&1)))
  end

  defp comma_numbers_with_trimmed_edges(value) do
    value
    |> String.trim()
    |> String.split(",")
    |> Enum.flat_map(fn item ->
      {number, _removed} = remove_nonnumeric_chars_at_ends(item)
      if String.trim(number) == "", do: [], else: [parse_int_or_no_answer(String.trim(number))]
    end)
  end

  defp remove_nonnumeric_chars_at_ends(value) do
    graphemes = String.graphemes(value)
    start_index = Enum.find_index(graphemes, &Regex.match?(~r/\d/, &1)) || length(graphemes)

    {digits, rest} =
      graphemes
      |> Enum.drop(start_index)
      |> Enum.split_while(&Regex.match?(~r/\d/, &1))

    number = Enum.join(digits)
    removed = length(graphemes) - length(digits)
    {number, removed + length(rest) - length(rest)}
  end

  defp reject_no_answer_or_fallback(numbers, fallback) do
    if numbers == [] or Enum.all?(numbers, &(&1 == :no_answer)) do
      fallback.()
    else
      numbers
    end
  end

  defp parse_int!(value) do
    value |> String.trim() |> String.to_integer()
  end

  defp parse_int_or_no_answer(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      {int, _rest} -> int
      :error -> :no_answer
    end
  end

  defp levenshtein(left, right) do
    rows = length(left)
    cols = length(right)

    initial = Map.new(0..cols, &{{0, &1}, &1})

    table =
      Enum.reduce(positive_range(rows), initial, fn i, table ->
        table = Map.put(table, {i, 0}, i)

        Enum.reduce(positive_range(cols), table, fn j, table ->
          cost = if Enum.at(left, i - 1) == Enum.at(right, j - 1), do: 0, else: 1

          value =
            min(
              Map.fetch!(table, {i - 1, j}) + 1,
              min(Map.fetch!(table, {i, j - 1}) + 1, Map.fetch!(table, {i - 1, j - 1}) + cost)
            )

          Map.put(table, {i, j}, value)
        end)
      end)

    Map.fetch!(table, {rows, cols})
  end

  defp positive_range(0), do: []
  defp positive_range(count), do: 1..count

  defp papillon_overall(nil) do
    fn _example, _prediction ->
      raise ArgumentError,
            "Papillon GEPA metric requires :judge_lm because upstream scoring is an LLM judge"
    end
  end

  defp papillon_overall(judge_lm) do
    quality_judge =
      DSEx.signature(
        "user_query, response_A, response_B -> judgment",
        "You are comparing the quality of two responses, given a user query. Is response A at least as good as response B?"
      )
      |> DSEx.chain_of_thought(
        lm: judge_lm,
        adapter: DSEx.Adapter.Chat
      )

    leakage_judge =
      DSEx.signature(
        "pii, prompt -> num_pii_leaked",
        "Count the number information pieces in `pii` that are forms of PII and are leaked into the prompt. Do not count celebrity names or PII that does not appear in the prompt."
      )
      |> DSEx.chain_of_thought(
        lm: judge_lm,
        adapter: DSEx.Adapter.Chat
      )

    fn example, prediction ->
      user_query = DSEx.Example.get(example, :user_query, "")
      target_response = DSEx.Example.get(example, :target_response, "")
      pii = example |> DSEx.Example.get(:pii_str, "") |> papillon_pii_units()
      new_response = DSEx.Prediction.get(prediction, :response, "")
      updated_query = DSEx.Prediction.get(prediction, :llm_request, "")

      with {:ok, judgment_1} <-
             papillon_quality?(quality_judge, user_query, new_response, target_response),
           {:ok, judgment_2} <-
             papillon_quality?(quality_judge, user_query, target_response, new_response),
           {:ok, leaked_count} <- papillon_leakage_count(leakage_judge, pii, updated_query) do
        quality = judgment_1 or judgment_1 == judgment_2
        leakage = if pii == [], do: 0.0, else: leaked_count / length(pii)
        (boolean_score(quality) + (1.0 - leakage)) / 2.0
      else
        _error -> 0.0
      end
    end
  end

  defp papillon_quality?(quality_judge, user_query, response_a, response_b) do
    case DSEx.Predict.ChainOfThought.call(quality_judge, %{
           user_query: user_query,
           response_A: response_a,
           response_B: response_b
         }) do
      {:ok, prediction} -> {:ok, truthy?(DSEx.Prediction.get(prediction, :judgment))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp papillon_leakage_count(leakage_judge, pii, prompt) do
    case DSEx.Predict.ChainOfThought.call(leakage_judge, %{pii: pii, prompt: prompt}) do
      {:ok, prediction} ->
        prediction
        |> DSEx.Prediction.get(:num_pii_leaked, 0)
        |> parse_number()
        |> case do
          nil -> {:error, :invalid_leakage_count}
          count -> {:ok, min(max(count, 0), length(pii))}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp papillon_pii_units(value) do
    value
    |> to_string()
    |> String.split("||")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp truthy?(value) when value in [true, "true", "True", "TRUE", "yes", "Yes", "YES", 1, "1"],
    do: true

  defp truthy?(_value), do: false

  defp boolean_score(true), do: 1.0
  defp boolean_score(false), do: 0.0

  defp parse_number(value) when is_integer(value), do: value
  defp parse_number(value) when is_float(value), do: round(value)

  defp parse_number(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, _rest} -> int
      :error -> nil
    end
  end

  defp parse_number(_value), do: nil

  defp numeric_score!(value) when is_integer(value), do: value * 1.0
  defp numeric_score!(value) when is_float(value), do: value

  defp numeric_score!(value) when is_binary(value) do
    case Float.parse(value) do
      {score, _rest} ->
        score

      :error ->
        raise ArgumentError, "LiveBenchMath bridge returned non-numeric score: #{inspect(value)}"
    end
  end

  defp numeric_score!(value) do
    raise ArgumentError, "LiveBenchMath bridge returned non-numeric score: #{inspect(value)}"
  end

  defp exact_output(output_key) do
    fn example, prediction ->
      predicted = DSEx.Prediction.get(prediction, output_key)
      gold = DSEx.Example.get(example, output_key)
      DSEx.Metrics.normalize_text(predicted) == DSEx.Metrics.normalize_text(gold)
    end
  end
end
