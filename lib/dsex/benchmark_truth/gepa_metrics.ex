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
    response = prediction |> DSEx.Prediction.get(:response) |> to_string()
    variants = response_variants(response)

    instructions = DSEx.Example.get(example, :instruction_id_list, [])
    kwargs = DSEx.Example.get(example, :kwargs, [])
    prompt = DSEx.Example.get(example, :prompt, "")

    instruction_scores =
      instructions
      |> Enum.with_index()
      |> Enum.map(fn {instruction_id, index} ->
        args = Enum.at(kwargs, index, %{}) |> strip_nil_values()

        Enum.any?(variants, fn variant ->
          String.trim(variant) != "" and ifbench_following?(instruction_id, args, prompt, variant)
        end)
      end)

    case instruction_scores do
      [] -> 0.0
      scores -> Enum.count(scores, & &1) / length(scores)
    end
  end

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

  defp compare_count(count, expected, "less than"), do: count < expected
  defp compare_count(count, expected, "at least"), do: count >= expected
  defp compare_count(_count, _expected, _relation), do: false

  defp count_words(value), do: value |> String.split(~r/\s+/, trim: true) |> length()

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
          if length(acc) > 0 and removed > 0, do: {:halt, next}, else: {:cont, next}
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
      Enum.reduce(1..rows, initial, fn i, table ->
        table = Map.put(table, {i, 0}, i)

        Enum.reduce(1..cols, table, fn j, table ->
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
