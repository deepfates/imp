defmodule UpstreamExam.AdaptersTest do
  @moduledoc """
  DSPy 3.2.1's own adapter tests (tests/adapters/), ported to Imp.

  Tranche 1 of the upstream exam: every test here cites the upstream file and
  test function it translates. The complete per-test disposition map (including
  the tests that were NOT portable and why) is docs/internal/UPSTREAM_EXAM.md.

  Rules of this file:
    * assertions check the SAME behavior as upstream, not a look-alike;
    * exact prompt strings are used exactly (Imp claims byte-compatible
      rendered prompts for chat/json/xml/two_step);
    * a failing port is a FINDING: it gets tagged @tag :upstream_fail and
      skipped with the failure output preserved in a comment until the
      divergence is fixed in lib (never by weakening the assertion). The
      original 14 findings from PR #68 were all fixed (dee-coia, dee-16qm,
      dee-jbav, dee-xyhv, dee-4fuy, dee-pkvp, dee-1nkd); every test here now
      runs unskipped.
  """

  use ExUnit.Case, async: true

  @moduletag :upstream_exam

  alias Imp.Adapters.Types

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Upstream `parse_value(value, annotation)` (dspy/adapters/utils.py) has no
  # 1:1 public Imp equivalent; Imp applies the same conversion inside
  # Chat.parse/3 field coercion. This helper parses a single-output signature
  # whose output field carries the type under test, mirroring the conversion
  # surface parse_value feeds in DSPy.
  defp parse_one(field_spec, raw_value) do
    signature = Imp.Signature.new(%{inputs: [:input], outputs: [field_spec]})

    case Imp.Adapter.Chat.parse(signature, %{value: raw_value}, []) do
      {:ok, prediction} -> {:ok, Imp.get(prediction, :value)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp capture_lm(response_fun) do
    test_pid = self()

    fn messages, opts ->
      send(test_pid, {:lm_call, messages, opts})
      response_fun.(messages)
    end
  end

  # ---------------------------------------------------------------------------
  # tests/adapters/test_adapter_utils.py
  # ---------------------------------------------------------------------------

  describe "test_adapter_utils.py" do
    # Upstream: tests/adapters/test_adapter_utils.py::test_parse_value_str_annotation
    # (was a finding; fixed by dee-jbav — str-annotated fields render through
    # Python str(): True -> "True", None -> "None", [1, 2, 3] -> "[1, 2, 3]".)
    test "parse_value str annotation" do
      assert parse_one(%{name: :value, type: :string}, 123) == {:ok, "123"}
      assert parse_one(%{name: :value, type: :string}, true) == {:ok, "True"}
      assert parse_one(%{name: :value, type: :string}, "hello") == {:ok, "hello"}
      assert parse_one(%{name: :value, type: :string}, nil) == {:ok, "None"}
      assert parse_one(%{name: :value, type: :string}, [1, 2, 3]) == {:ok, "[1, 2, 3]"}
    end

    # Upstream: tests/adapters/test_adapter_utils.py::test_parse_value_basic_types
    test "parse_value basic types" do
      assert parse_one(%{name: :value, type: :integer}, "42") == {:ok, 42}
      assert parse_one(%{name: :value, type: :integer}, 42) == {:ok, 42}

      assert parse_one(%{name: :value, type: :float}, "3.14") == {:ok, 3.14}
      assert parse_one(%{name: :value, type: :float}, 3.14) == {:ok, 3.14}

      assert parse_one(%{name: :value, type: :boolean}, "true") == {:ok, true}
      assert parse_one(%{name: :value, type: :boolean}, true) == {:ok, true}
      assert parse_one(%{name: :value, type: :boolean}, "false") == {:ok, false}

      list_field = %{name: :value, type: :array, constraints: %{items: %{type: :integer}}}
      assert parse_one(list_field, "[1, 2, 3]") == {:ok, [1, 2, 3]}
      assert parse_one(list_field, [1, 2, 3]) == {:ok, [1, 2, 3]}
    end

    # Upstream: tests/adapters/test_adapter_utils.py::test_parse_value_literal
    # (was a finding; fixed by dee-jbav — quote and `Literal[...]`/`str[...]`
    # wrappers are stripped before enum matching, exactly as parse_value does.)
    test "parse_value literal" do
      literal_field = %{name: :value, type: :string, constraints: %{enum: ["option1", "option2"]}}

      assert parse_one(literal_field, "option1") == {:ok, "option1"}
      assert parse_one(literal_field, "option2") == {:ok, "option2"}

      assert parse_one(literal_field, "'option1'") == {:ok, "option1"}
      assert parse_one(literal_field, ~s("option1")) == {:ok, "option1"}
      assert parse_one(literal_field, "Literal[option1]") == {:ok, "option1"}
      assert parse_one(literal_field, "str[option1]") == {:ok, "option1"}

      assert {:error, _reason} = parse_one(literal_field, "invalid")
    end

    # Upstream: tests/adapters/test_adapter_utils.py::test_parse_value_json_repair
    # (was a finding; fixed by dee-16qm — Imp.Adapter.JSONRepair ports the
    # json_repair/ast.literal_eval ladder for Python-dict spellings.)
    test "parse_value json repair" do
      dict_field = %{name: :value, type: :object}

      assert parse_one(dict_field, ~s({"key": "value"})) == {:ok, %{"key" => "value"}}
      assert parse_one(dict_field, "{'key': 'value'}") == {:ok, %{"key" => "value"}}
      assert {:error, _reason} = parse_one(dict_field, "not json or literal")
    end
  end

  # ---------------------------------------------------------------------------
  # tests/adapters/test_audio.py
  # ---------------------------------------------------------------------------

  describe "test_audio.py" do
    # Upstream: tests/adapters/test_audio.py::test_normalize_audio_format
    # (parameterized; ported over Imp's audio-format surface: the provider
    # block's `format` is derived from the mime type in Types.to_openai/1.
    # Was a finding; fixed by dee-pkvp — one leading "x-" is stripped.)
    test "normalize audio format strips x- prefixes" do
      audio_format = fn format ->
        %{input_audio: %{format: normalized}} =
          Types.to_openai(%Types.Audio{data: "UklGRg==", mime_type: "audio/" <> format})

        normalized
      end

      assert audio_format.("wav") == "wav"
      assert audio_format.("mp3") == "mp3"
      assert audio_format.("x-wav") == "wav"
      assert audio_format.("x-mp3") == "mp3"
      assert audio_format.("x-flac") == "flac"
      assert audio_format.("my-x-format") == "my-x-format"
      assert audio_format.("x-my-format") == "my-format"
    end
  end

  # ---------------------------------------------------------------------------
  # tests/adapters/test_chat_adapter.py
  # ---------------------------------------------------------------------------

  describe "test_chat_adapter.py" do
    # Upstream: tests/adapters/test_chat_adapter.py::test_chat_adapter_quotes_literals_as_expected
    # (scenarios 1-4: string-valued Literals with quote mixes)
    test "chat adapter quotes literals as expected (string literals)" do
      scenarios = [
        {["one", "two", ~s(three")], ["four", "five", ~s(six")],
         ~s(Literal['one', 'two', 'three"']), ~s(Literal['four', 'five', 'six"'])},
        {["she's here", "okay", "test"], ["done", "maybe'soon", "later"],
         ~s(Literal["she's here", 'okay', 'test']), ~s(Literal['done', "maybe'soon", 'later'])},
        {[~s(both"and'), "another"], [~s(yet"another'), "plain"],
         ~s(Literal['both"and\\'', 'another']), ~s(Literal['yet"another\\'', 'plain'])},
        {["foo", "bar"], ["baz", "qux"], ~s(Literal['foo', 'bar']), ~s(Literal['baz', 'qux'])}
      ]

      for {input_values, output_values, expected_input, expected_output} <- scenarios do
        signature =
          Imp.Signature.new(%{
            inputs: [%{name: :input_text, type: :string, constraints: %{enum: input_values}}],
            outputs: [%{name: :output_text, type: :string, constraints: %{enum: output_values}}]
          })

        [%{role: :system, content: content} | _rest] =
          Imp.Adapter.Chat.format(signature, %{input_text: hd(input_values)}, [])

        assert content =~ expected_input
        assert content =~ expected_output
      end
    end

    # Upstream: tests/adapters/test_chat_adapter.py::test_chat_adapter_quotes_literals_as_expected
    # (scenario 5: mixed-type Literal[1, 'bar'] / Literal[True, 3, 'foo'].
    # Was a finding; fixed by dee-xyhv — non-string Literal members render
    # bare via Python str(), only string members are quoted.)
    test "chat adapter quotes literals as expected (mixed-type literal)" do
      signature =
        Imp.Signature.new(%{
          inputs: [%{name: :input_text, type: :string, constraints: %{enum: [1, "bar"]}}],
          outputs: [%{name: :output_text, type: :string, constraints: %{enum: [true, 3, "foo"]}}]
        })

      [%{role: :system, content: content} | _rest] =
        Imp.Adapter.Chat.format(signature, %{input_text: "bar"}, [])

      assert content =~ "Literal[1, 'bar']"
      assert content =~ "Literal[True, 3, 'foo']"
    end

    # Upstream: tests/adapters/test_chat_adapter.py::test_chat_adapter_sync_call
    # (DummyLM returning {"answer": "Paris"} == the chat-rendered completion)
    test "chat adapter sync call" do
      lm = fn _messages, _opts -> {:ok, "[[ ## answer ## ]]\nParis\n\n[[ ## completed ## ]]"} end
      program = Imp.predict("question -> answer", adapter: Imp.Adapter.Chat, lm: lm)

      assert {:ok, prediction} = Imp.call(program, %{question: "What is the capital of France?"})
      assert Imp.get(prediction, :answer) == "Paris"
    end

    # Upstream: tests/adapters/test_chat_adapter.py::test_chat_adapter_signature_information
    test "chat adapter signature information" do
      signature =
        Imp.Signature.new(%{
          inputs: [
            %{name: :input1, type: :string, desc: "String Input"},
            %{name: :input2, type: :integer, desc: "Integer Input"}
          ],
          outputs: [%{name: :output, type: :string, desc: "String Output"}]
        })

      messages = Imp.Adapter.Chat.format(signature, %{input1: "Test", input2: 11}, [])

      assert length(messages) == 2
      assert [%{role: :system, content: system}, %{role: :user, content: user}] = messages

      assert system =~ "1. `input1` (str)"
      assert system =~ "2. `input2` (int)"
      assert system =~ "1. `output` (str)"
      assert system =~ "[[ ## input1 ## ]]\n{input1}"
      assert system =~ "[[ ## input2 ## ]]\n{input2}"
      assert system =~ "[[ ## output ## ]]\n{output}"
      assert system =~ "[[ ## completed ## ]]"

      assert user =~ "[[ ## input1 ## ]]"
      assert user =~ "[[ ## input2 ## ]]"
      assert user =~ "[[ ## output ## ]]"
      assert user =~ "[[ ## completed ## ]]"
    end

    # Upstream: tests/adapters/test_chat_adapter.py::test_chat_adapter_exception_raised_on_failure
    # (was a finding; fixed by dee-coia — a completion with no
    # [[ ## field ## ]] sections is a loud parse error, exactly as DSPy's
    # ChatAdapter.parse raises AdapterParseError.)
    test "chat adapter exception raised on failure" do
      signature = Imp.signature("question -> answer")

      assert {:error, _reason} =
               Imp.Adapter.Chat.parse(signature, "{'output':'mismatched value'}", [])
    end

    # Upstream: tests/adapters/test_chat_adapter.py::test_chat_adapter_formats_image
    # (Imp keeps typed structs in adapter output; provider encoding is
    # Types.to_openai/1 — the same three-chunk text/image/text split.)
    test "chat adapter formats image" do
      image = %Types.Image{url: "https://example.com/image.jpg"}
      signature = Imp.signature("image -> text")

      messages = Imp.Adapter.Chat.format(signature, %{image: image}, [])

      assert length(messages) == 2
      [_system, %{role: :user, content: content}] = messages
      refute is_nil(content)

      assert [first, %Types.Image{} = image_part, last] = content
      assert is_binary(first)
      assert is_binary(last)

      assert Types.to_openai(image_part) == %{
               type: "image_url",
               image_url: %{url: "https://example.com/image.jpg"}
             }
    end

    # Upstream: tests/adapters/test_chat_adapter.py::test_chat_adapter_formats_image_with_few_shot_examples
    test "chat adapter formats image with few shot examples" do
      signature = Imp.signature("image -> text")

      demos = [
        %{
          image: %Types.Image{url: "https://example.com/image1.jpg"},
          text: "This is a test image"
        },
        %{
          image: %Types.Image{url: "https://example.com/image2.jpg"},
          text: "This is another test image"
        }
      ]

      messages =
        Imp.Adapter.Chat.format(
          signature,
          %{image: %Types.Image{url: "https://example.com/image3.jpg"}},
          demos: demos
        )

      # 1 system message, 2 few shot examples (user + assistant each), 1 user message
      assert length(messages) == 6

      assert Enum.at(messages, 2).content =~ "[[ ## completed ## ]]\n"
      assert Enum.at(messages, 4).content =~ "[[ ## completed ## ]]\n"

      assert Enum.any?(
               Enum.at(messages, 1).content,
               &match?(%Types.Image{url: "https://example.com/image1.jpg"}, &1)
             )

      assert Enum.any?(
               Enum.at(messages, 3).content,
               &match?(%Types.Image{url: "https://example.com/image2.jpg"}, &1)
             )

      assert Enum.any?(
               Enum.at(messages, 5).content,
               &match?(%Types.Image{url: "https://example.com/image3.jpg"}, &1)
             )
    end

    # Upstream: tests/adapters/test_chat_adapter.py::test_chat_adapter_formats_conversation_history
    test "chat adapter formats conversation history" do
      signature = Imp.signature("question, history -> answer")

      history =
        Imp.history([
          %{question: "What is the capital of France?", answer: "Paris"},
          %{question: "What is the capital of Germany?", answer: "Berlin"}
        ])

      messages =
        Imp.Adapter.Chat.format(
          signature,
          %{question: "What is the capital of France?", history: history},
          []
        )

      assert length(messages) == 6

      assert Enum.at(messages, 1).content ==
               "[[ ## question ## ]]\nWhat is the capital of France?"

      assert Enum.at(messages, 2).content ==
               "[[ ## answer ## ]]\nParis\n\n[[ ## completed ## ]]\n"

      assert Enum.at(messages, 3).content ==
               "[[ ## question ## ]]\nWhat is the capital of Germany?"

      assert Enum.at(messages, 4).content ==
               "[[ ## answer ## ]]\nBerlin\n\n[[ ## completed ## ]]\n"
    end

    # Upstream: tests/adapters/test_chat_adapter.py::test_chat_adapter_fallback_to_json_adapter_on_exception
    # (was a finding; fixed by dee-coia + dee-16qm — strict chat parse fails on
    # the marker-less completion, Imp.Predict's JSON fallback fires a second LM
    # call, and JSONRepair decodes the single-quoted object.)
    test "chat adapter fallback to json adapter on exception" do
      lm = capture_lm(fn _messages -> {:ok, "{'answer': 'Paris'}"} end)
      program = Imp.predict("question -> answer", adapter: Imp.Adapter.Chat, lm: lm)

      assert {:ok, prediction} = Imp.call(program, %{question: "What is the capital of France?"})
      assert Imp.get(prediction, :answer) == "Paris"

      # DSPy calls the LM twice: once for chat, once for the JSON fallback.
      assert_received {:lm_call, _messages, _opts}
      assert_received {:lm_call, _messages, _opts}
    end

    # Upstream: tests/adapters/test_chat_adapter.py::test_chat_adapter_respects_use_json_adapter_fallback_flag
    # (Imp spells use_json_adapter_fallback=False as config: [json_fallback: false].
    # Was a finding; fixed by dee-coia — with the fallback disabled, "nonsense"
    # is a loud parse error after exactly one LM call.)
    test "chat adapter respects use_json_adapter_fallback flag" do
      lm = capture_lm(fn _messages -> {:ok, "nonsense"} end)

      program =
        Imp.predict("question -> answer",
          adapter: Imp.Adapter.Chat,
          lm: lm,
          config: [json_fallback: false]
        )

      assert {:error, _reason} = Imp.call(program, %{question: "What is the capital of France?"})

      # The JSON fallback must not fire: exactly one LM call.
      assert_received {:lm_call, _messages, _opts}
      refute_received {:lm_call, _messages, _opts}
    end

    # Upstream: tests/adapters/test_chat_adapter.py::test_format_system_message
    test "format system message" do
      signature =
        Imp.signature(
          "question -> answers: array[string], scores: array[float]",
          "Answer the question with multiple answers and scores"
        )

      [%{role: :system, content: system} | _rest] = Imp.Adapter.Chat.format(signature, %{}, [])

      expected =
        Enum.join(
          [
            "Your input fields are:",
            "1. `question` (str):",
            "Your output fields are:",
            "1. `answers` (list[str]): ",
            "2. `scores` (list[float]):",
            "All interactions will be structured in the following way, with the appropriate values filled in.",
            "",
            "[[ ## question ## ]]",
            "{question}",
            "",
            "[[ ## answers ## ]]",
            "{answers}        # note: the value you produce must adhere to the JSON schema: {\"type\": \"array\", \"items\": {\"type\": \"string\"}}",
            "",
            "[[ ## scores ## ]]",
            "{scores}        # note: the value you produce must adhere to the JSON schema: {\"type\": \"array\", \"items\": {\"type\": \"number\"}}",
            "",
            "[[ ## completed ## ]]",
            "In adhering to this structure, your objective is: ",
            "        Answer the question with multiple answers and scores"
          ],
          "\n"
        )

      assert system == expected
    end

    # Upstream: tests/adapters/test_chat_adapter.py::test_null_content_raises_adapter_parse_error
    # (Imp's LM boundary rejects a nil generation before the adapter parses;
    # either way the null-content case is a loud error, never silent nil fields.)
    test "null content is a loud error" do
      lm = fn _messages, _opts -> {:ok, nil} end
      cot = Imp.chain_of_thought("question -> answer", lm: lm)

      assert {:error, _reason} = Imp.call(cot, %{question: "test"})
    end

    # Upstream: tests/adapters/test_chat_adapter.py::test_empty_string_content_raises_adapter_parse_error
    test "empty string content is a loud error" do
      lm = fn _messages, _opts -> {:ok, ""} end
      cot = Imp.chain_of_thought("question -> answer", lm: lm)

      assert {:error, _reason} = Imp.call(cot, %{question: "test"})
    end
  end

  # ---------------------------------------------------------------------------
  # tests/adapters/test_json_adapter.py
  # ---------------------------------------------------------------------------

  describe "test_json_adapter.py" do
    # Upstream: tests/adapters/test_json_adapter.py::test_json_adapter_not_using_structured_outputs_when_not_supported_by_model
    # (Imp resolves the capability tier up front; a model with no declared
    # response_format capability gets NO response_format option — same contract.)
    test "json adapter not using structured outputs when not supported by model" do
      signature =
        Imp.Signature.new(%{
          inputs: [:input1],
          outputs: [%{name: :output1, type: :string}, %{name: :output2, type: :boolean}]
        })

      assert Imp.Adapter.JSON.lm_opts(signature, [], Imp.LM.Capability.none()) == []
    end

    # Upstream: tests/adapters/test_json_adapter.py::test_json_adapter_sync_call
    test "json adapter sync call" do
      lm = fn _messages, _opts -> {:ok, ~s({"answer": "Paris"})} end
      program = Imp.predict("question -> answer", adapter: Imp.Adapter.JSON, lm: lm)

      assert {:ok, prediction} = Imp.call(program, %{question: "What is the capital of France?"})
      assert Imp.get(prediction, :answer) == "Paris"
    end

    # Upstream: tests/adapters/test_json_adapter.py::test_json_adapter_parse_raise_error_on_mismatch_fields
    # Passes at the strength ported: the parse is a loud error. NOTE: the error
    # detail differs — DSPy repairs the single-quoted JSON, then reports
    # "Expected to find output fields in the LM response: [answer]"; Imp fails
    # earlier with a JSON decode error (no json-repair), so upstream's
    # adapter_name/parsed_result/message assertions have no Imp counterpart.
    # Recorded in the exam table.
    test "json adapter parse raises error on mismatched fields" do
      signature = Imp.signature("question -> answer")

      assert {:error, _reason} =
               Imp.Adapter.JSON.parse(signature, "{'answer1': 'Paris'}", [])
    end

    # Upstream: tests/adapters/test_json_adapter.py::test_json_adapter_formats_image
    test "json adapter formats image" do
      image = %Types.Image{url: "https://example.com/image.jpg"}
      signature = Imp.signature("image -> text")

      messages = Imp.Adapter.JSON.format(signature, %{image: image}, [])

      assert length(messages) == 2
      [_system, %{role: :user, content: content}] = messages
      refute is_nil(content)

      assert [first, %Types.Image{} = image_part, last] = content
      assert is_binary(first)
      assert is_binary(last)

      assert Types.to_openai(image_part) == %{
               type: "image_url",
               image_url: %{url: "https://example.com/image.jpg"}
             }
    end

    # Upstream: tests/adapters/test_json_adapter.py::test_json_adapter_formats_image_with_few_shot_examples
    test "json adapter formats image with few shot examples" do
      signature = Imp.signature("image -> text")

      demos = [
        %{
          image: %Types.Image{url: "https://example.com/image1.jpg"},
          text: "This is a test image"
        },
        %{
          image: %Types.Image{url: "https://example.com/image2.jpg"},
          text: "This is another test image"
        }
      ]

      messages =
        Imp.Adapter.JSON.format(
          signature,
          %{image: %Types.Image{url: "https://example.com/image3.jpg"}},
          demos: demos
        )

      assert length(messages) == 6

      assert Enum.any?(
               Enum.at(messages, 1).content,
               &match?(%Types.Image{url: "https://example.com/image1.jpg"}, &1)
             )

      assert Enum.any?(
               Enum.at(messages, 3).content,
               &match?(%Types.Image{url: "https://example.com/image2.jpg"}, &1)
             )

      assert Enum.any?(
               Enum.at(messages, 5).content,
               &match?(%Types.Image{url: "https://example.com/image3.jpg"}, &1)
             )
    end

    # Upstream: tests/adapters/test_json_adapter.py::test_json_adapter_formats_conversation_history
    test "json adapter formats conversation history" do
      signature = Imp.signature("question, history -> answer")

      history =
        Imp.history([
          %{question: "What is the capital of France?", answer: "Paris"},
          %{question: "What is the capital of Germany?", answer: "Berlin"}
        ])

      messages =
        Imp.Adapter.JSON.format(
          signature,
          %{question: "What is the capital of France?", history: history},
          []
        )

      assert length(messages) == 6

      assert Enum.at(messages, 1).content ==
               "[[ ## question ## ]]\nWhat is the capital of France?"

      assert Enum.at(messages, 2).content == "{\n  \"answer\": \"Paris\"\n}"

      assert Enum.at(messages, 3).content ==
               "[[ ## question ## ]]\nWhat is the capital of Germany?"

      assert Enum.at(messages, 4).content == "{\n  \"answer\": \"Berlin\"\n}"
    end

    # Upstream: tests/adapters/test_json_adapter.py::test_json_adapter_json_mode_no_structured_outputs
    # (a model that accepts response_format but not schemas -> json_object)
    test "json adapter json mode when no structured outputs" do
      signature = Imp.signature("question -> answer")

      assert Imp.Adapter.JSON.lm_opts(signature, [], Imp.LM.Capability.response_format_only()) ==
               [response_format: %{type: "json_object"}]

      # And the full call path parses a strict-JSON response.
      lm = capture_lm(fn _messages -> {:ok, ~s({"answer": "Test output"})} end)
      program = Imp.predict("question -> answer", adapter: Imp.Adapter.JSON, lm: lm)

      assert {:ok, prediction} = Imp.call(program, %{question: "Dummy question!"})
      assert Imp.get(prediction, :answer) == "Test output"
    end

    # Upstream: tests/adapters/test_json_adapter.py::test_error_message_on_json_adapter_failure
    # (provider errors must propagate unchanged, not be swallowed)
    test "error message on json adapter failure" do
      lm = fn _messages, _opts -> {:error, %RuntimeError{message: "RuntimeError!"}} end
      program = Imp.predict("question -> answer", adapter: Imp.Adapter.JSON, lm: lm)

      assert {:error, %RuntimeError{message: "RuntimeError!"}} =
               Imp.call(program, %{question: "Dummy question!"})

      lm2 = fn _messages, _opts -> {:error, %ArgumentError{message: "ValueError!"}} end
      program2 = Imp.predict("question -> answer", adapter: Imp.Adapter.JSON, lm: lm2)

      assert {:error, %ArgumentError{message: "ValueError!"}} =
               Imp.call(program2, %{question: "Dummy question!"})
    end

    # Upstream: tests/adapters/test_json_adapter.py::test_format_system_message
    test "json format system message" do
      signature =
        Imp.signature(
          "question -> answers: array[string], scores: array[float]",
          "Answer the question with multiple answers and scores"
        )

      [%{role: :system, content: system} | _rest] = Imp.Adapter.JSON.format(signature, %{}, [])

      expected =
        Enum.join(
          [
            "Your input fields are:",
            "1. `question` (str):",
            "Your output fields are:",
            "1. `answers` (list[str]): ",
            "2. `scores` (list[float]):",
            "All interactions will be structured in the following way, with the appropriate values filled in.",
            "",
            "Inputs will have the following structure:",
            "",
            "[[ ## question ## ]]",
            "{question}",
            "",
            "Outputs will be a JSON object with the following fields.",
            "",
            "{",
            "  \"answers\": \"{answers}        # note: the value you produce must adhere to the JSON schema: {\\\"type\\\": \\\"array\\\", \\\"items\\\": {\\\"type\\\": \\\"string\\\"}}\",",
            "  \"scores\": \"{scores}        # note: the value you produce must adhere to the JSON schema: {\\\"type\\\": \\\"array\\\", \\\"items\\\": {\\\"type\\\": \\\"number\\\"}}\"",
            "}",
            "In adhering to this structure, your objective is: ",
            "        Answer the question with multiple answers and scores"
          ],
          "\n"
        )

      assert system == expected
    end
  end

  # ---------------------------------------------------------------------------
  # tests/adapters/test_xml_adapter.py
  # ---------------------------------------------------------------------------

  describe "test_xml_adapter.py" do
    # Upstream: tests/adapters/test_xml_adapter.py::test_xml_adapter_format_and_parse_basic
    # (format_field_with_value is internal in Imp; the same rendering is
    # exercised through the demo assistant turn, which DSPy builds with it.)
    test "xml adapter format and parse basic" do
      signature = Imp.signature("question -> answer")

      [_system, _demo_user, %{role: :assistant, content: xml} | _rest] =
        Imp.Adapter.XML.format(
          signature,
          %{question: "What is the capital of France?"},
          demos: [%{question: "Capital of France?", answer: "Paris"}]
        )

      assert String.trim(xml) == "<answer>\nParis\n</answer>"

      assert {:ok, prediction} = Imp.Adapter.XML.parse(signature, "<answer>Paris</answer>", [])
      assert Imp.to_map(prediction) == %{answer: "Paris"}
    end

    # Upstream: tests/adapters/test_xml_adapter.py::test_xml_adapter_parse_multiple_fields
    test "xml adapter parse multiple fields" do
      signature = Imp.signature("question -> answer, explanation")

      completion = """

      <answer>Paris</answer>
      <explanation>The capital of France is Paris.</explanation>
      """

      assert {:ok, prediction} = Imp.Adapter.XML.parse(signature, completion, [])

      assert Imp.to_map(prediction) == %{
               answer: "Paris",
               explanation: "The capital of France is Paris."
             }
    end

    # Upstream: tests/adapters/test_xml_adapter.py::test_xml_adapter_parse_raises_on_missing_field
    test "xml adapter parse errors on missing field" do
      signature = Imp.signature("question -> answer, explanation")

      assert {:error, {:missing_output_fields, [:explanation]}} =
               Imp.Adapter.XML.parse(signature, "<answer>Paris</answer>", [])
    end

    # Upstream: tests/adapters/test_xml_adapter.py::test_xml_adapter_parse_casts_types
    test "xml adapter parse casts types" do
      signature = Imp.signature(" -> number: integer, flag: boolean")

      completion = """

      <number>42</number>
      <flag>true</flag>
      """

      assert {:ok, prediction} = Imp.Adapter.XML.parse(signature, completion, [])
      assert Imp.to_map(prediction) == %{number: 42, flag: true}
    end

    # Upstream: tests/adapters/test_xml_adapter.py::test_xml_adapter_parse_raises_on_type_error
    test "xml adapter parse errors on type error" do
      signature = Imp.signature(" -> number: integer")

      assert {:error, %Imp.AdapterParseError{}} =
               Imp.Adapter.XML.parse(signature, "<number>not_a_number</number>", [])
    end

    # Upstream: tests/adapters/test_xml_adapter.py::test_format_system_message
    test "xml format system message" do
      signature =
        Imp.signature(
          "question -> answers: array[string], scores: array[float]",
          "Answer the question with multiple answers and scores"
        )

      [%{role: :system, content: system} | _rest] = Imp.Adapter.XML.format(signature, %{}, [])

      expected =
        Enum.join(
          [
            "Your input fields are:",
            "1. `question` (str):",
            "Your output fields are:",
            "1. `answers` (list[str]): ",
            "2. `scores` (list[float]):",
            "All interactions will be structured in the following way, with the appropriate values filled in.",
            "",
            "<question>",
            "{question}",
            "</question>",
            "",
            "<answers>",
            "{answers}        # note: the value you produce must adhere to the JSON schema: {\"type\": \"array\", \"items\": {\"type\": \"string\"}}",
            "</answers>",
            "",
            "<scores>",
            "{scores}        # note: the value you produce must adhere to the JSON schema: {\"type\": \"array\", \"items\": {\"type\": \"number\"}}",
            "</scores>",
            "In adhering to this structure, your objective is: ",
            "        Answer the question with multiple answers and scores"
          ],
          "\n"
        )

      assert system == expected
    end
  end

  # ---------------------------------------------------------------------------
  # tests/adapters/test_two_step_adapter.py
  # ---------------------------------------------------------------------------

  describe "test_two_step_adapter.py" do
    # Upstream: tests/adapters/test_two_step_adapter.py::test_two_step_adapter_call
    test "two step adapter call" do
      test_pid = self()

      main_lm = fn messages, _opts ->
        send(test_pid, {:main_lm, messages})
        {:ok, "text from main LM"}
      end

      extraction_lm = fn messages, _opts ->
        send(test_pid, {:extraction_lm, messages})

        {:ok,
         """

         [[ ## solution ## ]] result
         [[ ## answer ## ]] 12
         [[ ## completed ## ]]
         """}
      end

      signature =
        Imp.Signature.new(%{
          inputs: [%{name: :question, type: :string, desc: "The math question to solve"}],
          outputs: [
            %{name: :solution, type: :string, desc: "Step by step solution"},
            %{name: :answer, type: :float, desc: "The final numerical answer"}
          ]
        })

      program = Imp.predict(signature, adapter: Imp.Adapter.TwoStep, lm: main_lm)

      {:ok, prediction} =
        Imp.context([two_step_extraction_lm: extraction_lm], fn ->
          Imp.call(program, %{question: "What is 5 + 7?"})
        end)

      assert Imp.get(prediction, :answer) == 12

      # main LM call
      assert_received {:main_lm, main_messages}
      assert length(main_messages) == 2

      assert %{role: :system, content: main_system} = Enum.at(main_messages, 0)
      assert main_system =~ "1. `question` (str)"
      assert main_system =~ "1. `solution` (str)"
      assert main_system =~ "2. `answer` (float)"

      assert %{role: :user, content: main_user} = Enum.at(main_messages, 1)
      assert String.downcase(main_user) =~ "question:"
      assert main_user =~ "What is 5 + 7?"

      # extraction LM call
      assert_received {:extraction_lm, extraction_messages}
      assert length(extraction_messages) == 2

      assert %{role: :system, content: extraction_system} = Enum.at(extraction_messages, 0)
      assert extraction_system =~ "`text` (str)"
      assert extraction_system =~ "`solution` (str)"
      assert extraction_system =~ "`answer` (float)"

      assert %{role: :user, content: extraction_user} = Enum.at(extraction_messages, 1)
      assert extraction_user =~ "text from main LM"
    end

    # Upstream: tests/adapters/test_two_step_adapter.py::test_two_step_adapter_parse
    test "two step adapter parse" do
      extraction_lm = fn _messages, _opts ->
        {:ok,
         """

             {
                 "tags": ["AI", "deep learning", "neural networks"],
                 "confidence": 0.87
             }
         """}
      end

      signature =
        Imp.Signature.new(%{
          inputs: [:input_text],
          outputs: [
            %{
              name: :tags,
              type: :array,
              desc: "List of relevant tags",
              constraints: %{items: %{type: :string}}
            },
            %{name: :confidence, type: :float, desc: "Confidence score"}
          ]
        })

      assert {:ok, prediction} =
               Imp.Adapter.TwoStep.parse(signature, "main LM response",
                 extraction_lm: extraction_lm
               )

      assert Imp.get(prediction, :tags) == ["AI", "deep learning", "neural networks"]
      assert Imp.get(prediction, :confidence) == 0.87
    end

    # Upstream: tests/adapters/test_two_step_adapter.py::test_two_step_adapter_parse_errors
    # (was a finding; fixed by dee-coia — strict chat parse rejects the
    # unusable extraction text, the JSON retry also fails, and the loud
    # two_step_extraction_failed error surfaces, matching DSPy's ValueError.)
    test "two step adapter parse errors" do
      extraction_lm = fn _messages, _opts -> {:ok, "invalid response"} end
      signature = Imp.signature("question -> answer")

      assert {:error, {:two_step_extraction_failed, _reason, _completion}} =
               Imp.Adapter.TwoStep.parse(signature, "main LM response",
                 extraction_lm: extraction_lm
               )
    end
  end

  # ---------------------------------------------------------------------------
  # tests/adapters/test_tool.py
  # ---------------------------------------------------------------------------

  describe "test_tool.py" do
    # Upstream: tests/adapters/test_tool.py::test_basic_initialization
    test "tool basic initialization" do
      tool =
        Imp.Tool.new("test_tool", "A test tool", fn x -> x end,
          schema: %{"param1" => %{"type" => "string"}}
        )

      assert to_string(tool.name) == "test_tool"
      assert tool.description == "A test tool"
      assert tool.schema == %{"param1" => %{"type" => "string"}}
      assert is_function(tool.run)
    end

    # Upstream: tests/adapters/test_tool.py::test_tool_callable
    test "tool callable" do
      tool =
        Imp.Tool.new(:dummy_function, "A dummy function for testing", fn args ->
          "#{Map.get(args, :y, "hello")} #{args.x}"
        end)

      assert Imp.Tool.call(tool, %{x: 42, y: "hello"}) == "hello 42"
    end

    # Upstream: tests/adapters/test_tool.py::test_tool_calls_format_basic (parameterized)
    # (was a finding; fixed by dee-4fuy — ToolCalls.format emits the OpenAI
    # wire shape {"type": "function", "function": {"name", "arguments"}}.)
    test "tool calls format basic" do
      cases = [
        {[], %{tool_calls: []}},
        {[%{"name" => "search", "args" => %{"query" => "hello"}}],
         %{
           tool_calls: [
             %{type: "function", function: %{name: "search", arguments: %{"query" => "hello"}}}
           ]
         }},
        {[
           %{"name" => "search", "args" => %{"query" => "hello"}},
           %{"name" => "translate", "args" => %{"text" => "world", "lang" => "fr"}}
         ],
         %{
           tool_calls: [
             %{type: "function", function: %{name: "search", arguments: %{"query" => "hello"}}},
             %{
               type: "function",
               function: %{
                 name: "translate",
                 arguments: %{"text" => "world", "lang" => "fr"}
               }
             }
           ]
         }},
        {[%{"name" => "get_time", "args" => %{}}],
         %{tool_calls: [%{type: "function", function: %{name: "get_time", arguments: %{}}}]}}
      ]

      for {tool_calls_data, expected} <- cases do
        result = tool_calls_data |> Types.ToolCalls.new() |> Types.ToolCalls.format()
        assert result == expected
      end
    end

    # Upstream: tests/adapters/test_tool.py::test_tool_calls_format_from_dict_list
    # (was a finding; fixed by dee-4fuy — same wire shape via from_dict_list.)
    test "tool calls format from dict list" do
      tool_calls =
        Types.ToolCalls.from_dict_list([
          %{"name" => "search", "args" => %{"query" => "hello"}},
          %{"name" => "translate", "args" => %{"text" => "world", "lang" => "fr"}}
        ])

      result = Types.ToolCalls.format(tool_calls)

      assert length(result.tool_calls) == 2
      assert get_in(Enum.at(result.tool_calls, 0), [:function, :name]) == "search"
      assert get_in(Enum.at(result.tool_calls, 1), [:function, :name]) == "translate"
    end

    # Upstream: tests/adapters/test_tool.py::test_toolcalls_vague_match
    # (partial port: Imp has ToolCall.from_map for the single-dict shape and
    # ToolCalls.new for the list shape; there is no single validator accepting
    # a bare {"tool_calls": [...]} dict — that shape lives in the chat
    # adapter's history normalizer, not on the type.)
    test "toolcalls vague match" do
      call = Types.ToolCall.from_map(%{"name" => "search", "args" => %{"query" => "hello"}})
      assert to_string(call.name) == "search"
      assert call.arguments == %{"query" => "hello"}

      tool_calls =
        Types.ToolCalls.new([
          %{"name" => "search", "args" => %{"query" => "hello"}},
          %{"name" => "translate", "args" => %{"text" => "world", "lang" => "fr"}}
        ])

      assert length(tool_calls.tool_calls) == 2
      assert to_string(Enum.at(tool_calls.tool_calls, 0).name) == "search"
      assert to_string(Enum.at(tool_calls.tool_calls, 1).name) == "translate"

      # Invalid input raises (upstream: pydantic ValueError).
      assert_raise ArgumentError, fn -> Types.ToolCall.from_map(%{"foo" => "bar"}) end
      assert_raise ArgumentError, fn -> Types.ToolCalls.new([%{"foo" => "bar"}]) end
    end
  end

  # ---------------------------------------------------------------------------
  # tests/adapters/test_code.py
  # ---------------------------------------------------------------------------

  describe "test_code.py" do
    # Upstream: tests/adapters/test_code.py::test_code_validate_input
    # (partial port: Imp validates the code payload at the provider boundary
    # (Types.to_openai/1) rather than at struct construction.)
    test "code validate input" do
      code = %Types.Code{code: "print('Hello, world!')"}
      assert code.code == "print('Hello, world!')"

      assert_raise ArgumentError, fn ->
        Types.to_openai(%Types.Code{code: 123})
      end
    end

    # Upstream: tests/adapters/test_code.py::test_code_with_language
    # (partial port: the language rides the struct; Imp has no
    # Code.description() prompt-description surface — recorded as blocked in
    # the exam table.)
    test "code with language" do
      java_code = %Types.Code{code: "System.out.println('Hello, world!');", language: "java"}
      assert java_code.code == "System.out.println('Hello, world!');"
      assert java_code.language == "java"

      cpp_code = %Types.Code{code: "std::cout << 'Hello, world!' << std::endl;", language: "cpp"}
      assert cpp_code.code == "std::cout << 'Hello, world!' << std::endl;"
      assert cpp_code.language == "cpp"
    end
  end

  # ---------------------------------------------------------------------------
  # tests/adapters/test_document.py
  # ---------------------------------------------------------------------------

  describe "test_document.py" do
    # Upstream: tests/adapters/test_document.py::test_document_validate_input
    # (partial port: Imp validates at the provider boundary, not construction.)
    test "document validate input" do
      doc = %Types.Document{text: "The Earth orbits the Sun."}
      assert doc.text == "The Earth orbits the Sun."

      assert_raise ArgumentError, fn ->
        Types.to_openai(%Types.Document{text: 123})
      end
    end
  end

  # ---------------------------------------------------------------------------
  # tests/adapters/test_reasoning.py
  # ---------------------------------------------------------------------------

  describe "test_reasoning.py" do
    # Upstream: tests/adapters/test_reasoning.py::test_reasoning_with_chain_of_thought
    # (the behavior: result.reasoning is an ordinary string value usable with
    # the language's string operations)
    test "reasoning with chain of thought" do
      lm = fn _messages, _opts ->
        {:ok, %{reasoning: "Let me think step by step", answer: "42"}}
      end

      cot = Imp.chain_of_thought("question -> answer", lm: lm)
      assert {:ok, prediction} = Imp.call(cot, %{question: "What is the answer?"})

      reasoning = Imp.get(prediction, :reasoning)
      assert is_binary(reasoning)
      assert String.trim(reasoning) == "Let me think step by step"
      assert String.downcase(reasoning) == "let me think step by step"
      assert reasoning =~ "step by step"
      assert String.length(reasoning) == 25
    end
  end
end
