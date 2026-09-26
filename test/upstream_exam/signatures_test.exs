defmodule UpstreamExam.SignaturesTest do
  @moduledoc """
  DSPy 3.2.1's own signature tests (tests/signatures/), ported to Imp.

  Tranche 1 of the upstream exam: every test cites the upstream file and test
  function it translates. The per-test disposition map (including everything
  that was NOT portable and why) is docs/differentials/UPSTREAM_EXAM.md.

  DSPy signatures are Python classes (pydantic models built by a metaclass);
  Imp signatures are plain structs built from string specs or maps. Ports use
  the Imp construction surface that carries the same information; tests that
  exist only to exercise Python class mechanics are recorded as not applicable
  in the exam table rather than translated into look-alikes.
  """

  use ExUnit.Case, async: true

  @moduletag :upstream_exam

  alias Imp.Adapter.Types
  alias Imp.Signature.Field

  defp count_structs(term, module) do
    cond do
      is_struct(term, module) -> 1
      is_struct(term) -> term |> Map.from_struct() |> Map.values() |> count_list(module)
      is_map(term) -> term |> Map.values() |> count_list(module)
      is_list(term) -> count_list(term, module)
      true -> 0
    end
  end

  defp count_list(terms, module), do: Enum.sum(Enum.map(terms, &count_structs(&1, module)))

  defp capture_lm(response_fun) do
    test_pid = self()

    Imp.Test.FunLM.new(fn messages, opts ->
      send(test_pid, {:lm_call, messages, opts})
      response_fun.(messages)
    end)
  end

  # ---------------------------------------------------------------------------
  # tests/signatures/test_signature.py
  # ---------------------------------------------------------------------------

  describe "test_signature.py" do
    # Upstream: tests/signatures/test_signature.py::test_field_types_and_custom_attributes
    # (class declaration -> Imp map form; an output with no type defaults to str)
    test "field types and custom attributes" do
      signature =
        Imp.Signature.new(
          %{
            inputs: [
              %{name: :input1, type: :string},
              %{name: :input2, type: :integer}
            ],
            outputs: [
              %{name: :output1, type: :array, constraints: %{items: %{type: :string}}},
              %{name: :output2}
            ]
          },
          "Instructions"
        )

      assert signature.instructions == "Instructions"
      assert Enum.at(signature.inputs, 0).type == :string
      assert Enum.at(signature.inputs, 1).type == :integer
      assert Enum.at(signature.outputs, 0).type == :array
      assert Enum.at(signature.outputs, 1).type == :string
    end

    # Upstream: tests/signatures/test_signature.py::test_all_fields_have_prefix
    test "all fields have prefix" do
      signature =
        Imp.Signature.new(%{
          inputs: [%{name: :input, prefix: "Modified:"}],
          outputs: [:output]
        })

      assert hd(signature.inputs).prefix == "Modified:"
      assert hd(signature.outputs).prefix == "Output:"
    end

    # Upstream: tests/signatures/test_signature.py::test_signature_parsing
    test "signature parsing" do
      signature = Imp.signature("input1, input2 -> output")
      assert :input1 in Imp.Signature.input_names(signature)
      assert :input2 in Imp.Signature.input_names(signature)
      assert :output in Imp.Signature.output_names(signature)
    end

    # Upstream: tests/signatures/test_signature.py::test_duplicate_input_output_field_names_raise
    # (was a finding; fixed by dee-1nkd — a name on both sides of the arrow is
    # a loud ParseError, matching DSPy's "distinct names" ValueError.)
    test "duplicate input/output field names raise" do
      assert_raise Imp.Signature.ParseError, fn ->
        Imp.signature("value -> value")
      end
    end

    # Upstream: tests/signatures/test_signature.py::test_with_signature
    # (with_instructions -> plain struct update; immutability is inherent)
    test "with instructions produces a distinct signature" do
      signature1 = Imp.signature("input1, input2 -> output")
      signature2 = %{signature1 | instructions: "This is a test"}

      assert signature2.instructions == "This is a test"
      refute signature1.instructions == signature2.instructions
    end

    # Upstream: tests/signatures/test_signature.py::test_empty_signature
    test "empty signature raises" do
      assert_raise Imp.Signature.ParseError, fn -> Imp.signature("") end
    end

    # Upstream: tests/signatures/test_signature.py::test_instructions_signature
    # (upstream body is identical to test_empty_signature)
    test "instructions signature raises on empty spec" do
      assert_raise Imp.Signature.ParseError, fn -> Imp.signature("") end
    end

    # Upstream: tests/signatures/test_signature.py::test_signature_instructions
    test "signature instructions" do
      sig = Imp.signature("input1 -> output1", "This is a test")
      assert sig.instructions == "This is a test"
    end

    # Upstream: tests/signatures/test_signature.py::test_signature_instructions_none
    test "signature default instructions" do
      sig = Imp.signature("a, b -> c")
      assert sig.instructions == "Given the fields `a`, `b`, produce the fields `c`."
    end

    # Upstream: tests/signatures/test_signature.py::test_signature_from_dict
    test "signature from dict" do
      signature = Imp.Signature.new(%{inputs: [:input1, :input2], outputs: [:output]})

      for field <- signature.inputs ++ signature.outputs do
        assert field.name in [:input1, :input2, :output]
        assert field.type == :string
      end

      assert Imp.Signature.field_names(signature) == [:input1, :input2, :output]
    end

    # Upstream: tests/signatures/test_signature.py::test_signature_equality
    test "signature equality" do
      sig1 = Imp.signature("input1 -> output1")
      sig2 = Imp.signature("input1 -> output1")
      assert sig1 == sig2
    end

    # Upstream: tests/signatures/test_signature.py::test_signature_inequality
    test "signature inequality" do
      sig1 = Imp.signature("input1 -> output1")
      sig2 = Imp.signature("input2 -> output2")
      refute sig1 == sig2
    end

    # Upstream: tests/signatures/test_signature.py::test_signature_reverse
    test "signature spec round trip" do
      sig = Imp.signature("input1 -> output1")
      assert Imp.Signature.to_spec(sig) == "input1 -> output1"
    end

    # Upstream: tests/signatures/test_signature.py::test_insert_field_at_various_positions
    # (prepend input has no dedicated Imp API; a struct update is the idiom.
    # Appends use Signature.extend/3, output-prepend uses prepend_output/2.)
    test "insert field at various positions" do
      initial = Imp.signature("input1: string -> output1: integer")

      s1 = %{initial | inputs: [Field.new(:new_input_start, :input) | initial.inputs]}
      s2 = Imp.Signature.extend(initial, [:new_input_end], :input)
      assert hd(Imp.Signature.input_names(s1)) == :new_input_start
      assert List.last(Imp.Signature.input_names(s2)) == :new_input_end

      s3 = Imp.Signature.prepend_output(initial, :new_output_start)
      s4 = Imp.Signature.extend(initial, [:new_output_end], :output)
      assert hd(Imp.Signature.output_names(s3)) == :new_output_start
      assert List.last(Imp.Signature.output_names(s4)) == :new_output_end
    end

    # Upstream: tests/signatures/test_signature.py::test_order_preserved_with_mixed_annotations
    test "order preserved with mixed annotations" do
      signature = Imp.signature("text: string -> output, pass_evaluation: boolean")
      assert Imp.Signature.field_names(signature) == [:text, :output, :pass_evaluation]
    end

    # Upstream: tests/signatures/test_signature.py::test_infer_prefix
    # (was a finding; fixed by dee-1nkd — Field.new ports DSPy's infer_prefix
    # casing rules: camelCase/digit splitting, Title Case, acronyms preserved.)
    test "infer prefix" do
      assert Field.new(:someAttributeName42IsCool, :input).prefix ==
               "Some Attribute Name 42 Is Cool:"

      assert Field.new(:version2Update, :input).prefix == "Version 2 Update:"
      assert Field.new(:modelT45Enhanced, :input).prefix == "Model T 45 Enhanced:"
      assert Field.new(:someAttributeName, :input).prefix == "Some Attribute Name:"
      assert Field.new(:some_attribute_name, :input).prefix == "Some Attribute Name:"
      assert Field.new(:URLAddress, :input).prefix == "URL Address:"
      assert Field.new(:isHTTPSecure, :input).prefix == "Is HTTP Secure:"
      assert Field.new(:isHTTPSSecure123, :input).prefix == "Is HTTPS Secure 123:"
    end

    # Upstream: tests/signatures/test_signature.py::test_multiline_instructions
    test "multiline instructions" do
      lm = Imp.Test.FunLM.new(fn _messages, _opts -> {:ok, %{output: "short answer"}} end)

      signature =
        Imp.signature(" -> output", "First line\nSecond line\n    Third line")

      predictor = Imp.predict(signature, lm: lm)
      assert {:ok, prediction} = Imp.call(predictor, %{})
      assert Imp.get(prediction, :output) == "short answer"
    end

    # Upstream: tests/signatures/test_signature.py::test_typed_signatures_basic_types
    # (was a finding; fixed by dee-1nkd — the parser accepts the Python
    # spellings "str" and "dict" for the types Imp models.)
    test "typed signatures basic types" do
      sig = Imp.signature("input1: int, input2: str -> output: float")

      assert Enum.at(sig.inputs, 0).name == :input1
      assert Enum.at(sig.inputs, 0).type == :integer
      assert Enum.at(sig.inputs, 1).name == :input2
      assert Enum.at(sig.inputs, 1).type == :string
      assert hd(sig.outputs).name == :output
      assert hd(sig.outputs).type == :float
    end

    # Upstream: tests/signatures/test_signature.py::test_signature_field_with_constraints
    # — OutputField(min_length=5, max_length=10) / OutputField(ge=5, le=10)
    # produce a human-readable json_schema_extra["constraints"] string
    # (dspy/signatures/field.py PYDANTIC_CONSTRAINT_MAP). Imp's analog is
    # Imp.Adapter.FieldConstraints.description/1, rendered from the machine
    # constraints on the field. Regression for de-hzcv gap #4: pre-fix Imp had
    # no constraints description surface at all.
    test "signature field with constraints" do
      signature =
        Imp.Signature.new(%{
          inputs: [:inputs],
          outputs: [
            outputs1: [constraints: %{min_length: 5, max_length: 10}],
            outputs2: [type: :integer, constraints: %{ge: 5, le: 10}]
          ]
        })

      assert [outputs1, outputs2] = signature.outputs
      assert outputs1.name == :outputs1
      assert outputs2.name == :outputs2

      outputs1_constraints = Imp.Adapter.FieldConstraints.description(outputs1)
      assert outputs1_constraints =~ "minimum length: 5"
      assert outputs1_constraints =~ "maximum length: 10"

      outputs2_constraints = Imp.Adapter.FieldConstraints.description(outputs2)
      assert outputs2_constraints =~ "greater than or equal to: 5"
      assert outputs2_constraints =~ "less than or equal to: 10"
    end

    # Upstream: tests/signatures/test_signature.py::test_signature_cloudpickle_roundtrip
    # (cloudpickle -> Imp.Signature.dump/load, the Imp serialization surface)
    test "signature serialization roundtrip" do
      signature =
        Imp.Signature.new(
          %{
            inputs: [
              %{name: :context, type: :array, constraints: %{items: %{type: :string}}},
              %{name: :question, type: :string}
            ],
            outputs: [%{name: :answer, type: :string}]
          },
          "Answer the question."
        )

      loaded =
        signature
        |> Imp.Signature.dump()
        |> Jason.encode!()
        |> Jason.decode!()
        |> Imp.Signature.load()

      assert Imp.Signature.input_names(loaded) == [:context, :question]
      assert Imp.Signature.output_names(loaded) == [:answer]
      assert loaded.instructions == "Answer the question."
    end
  end

  # ---------------------------------------------------------------------------
  # tests/signatures/test_adapter_file.py
  # ---------------------------------------------------------------------------

  describe "test_adapter_file.py" do
    setup do
      path =
        Path.join(
          System.tmp_dir!(),
          "upstream_exam_sample_#{System.unique_integer([:positive])}.txt"
        )

      File.write!(path, "This is a test file.")
      on_exit(fn -> File.rm(path) end)
      %{sample_text_file: path}
    end

    # Upstream: tests/signatures/test_adapter_file.py::test_file_from_local_path
    test "file from local path", %{sample_text_file: path} do
      file = Types.File.from_path(path)

      %{type: "file", file: %{file_data: file_data}} =
        Types.to_openai(file)

      assert String.starts_with?(file_data, "data:text/plain;base64,")
      assert file.filename == Path.basename(path)
      assert file.path == nil
    end

    # Upstream: tests/signatures/test_adapter_file.py::test_file_from_path_method
    # (upstream body is identical to test_file_from_local_path)
    test "file from path method", %{sample_text_file: path} do
      %{type: "file", file: %{file_data: file_data}} =
        path |> Types.File.from_path() |> Types.to_openai()

      assert String.starts_with?(file_data, "data:text/plain;base64,")
    end

    # Upstream: tests/signatures/test_adapter_file.py::test_file_from_bytes
    test "file from bytes" do
      file = %Types.File{data: Base.encode64("Test file content")}
      %{type: "file", file: %{file_data: file_data}} = Types.to_openai(file)

      assert String.starts_with?(file_data, "data:application/octet-stream;base64,")
    end

    # Upstream: tests/signatures/test_adapter_file.py::test_file_from_dict_with_file_data
    test "file from data uri" do
      file = %Types.File{data: "data:text/plain;base64,dGVzdA=="}
      assert file.data == "data:text/plain;base64,dGVzdA=="

      %{file: %{file_data: file_data}} = Types.to_openai(file)
      assert file_data == "data:text/plain;base64,dGVzdA=="
    end

    # Upstream: tests/signatures/test_adapter_file.py::test_file_format_with_file_data
    test "file format with file data" do
      file = Types.File.from_bytes("test", filename: "test.txt", mime_type: "text/plain")
      formatted = Types.to_openai(file)

      assert formatted.type == "file"
      assert Map.has_key?(formatted, :file)
      assert Map.has_key?(formatted.file, :file_data)
      assert formatted.file.filename == "test.txt"
    end

    # Upstream: tests/signatures/test_adapter_file.py::test_encode_file_to_dict_from_path
    test "encode file from path", %{sample_text_file: path} do
      %{file: %{file_data: file_data}} = path |> Types.File.from_path() |> Types.to_openai()
      assert String.starts_with?(file_data, "data:text/plain;base64,")
    end

    # Upstream: tests/signatures/test_adapter_file.py::test_encode_file_to_dict_from_bytes
    test "encode file from bytes" do
      %{file: %{file_data: file_data}} =
        Types.to_openai(%Types.File{data: Base.encode64("test content")})

      assert String.starts_with?(file_data, "data:application/octet-stream;base64,")
    end

    # Upstream: tests/signatures/test_adapter_file.py::test_invalid_dict
    # (upstream rejects at construction; Imp rejects a payload-less file at
    # the provider boundary — same invariant, different seam)
    test "invalid file rejected" do
      assert_raise ArgumentError, fn -> Types.to_openai(%Types.File{}) end
    end

    # Upstream: tests/signatures/test_adapter_file.py::test_file_in_signature
    test "file in signature", %{sample_text_file: path} do
      lm = capture_lm(fn _messages -> {:ok, %{summary: "This is a summary"}} end)
      program = Imp.predict("document -> summary", lm: lm)

      assert {:ok, prediction} = Imp.call(program, %{document: Types.File.from_path(path)})
      assert Imp.get(prediction, :summary) == "This is a summary"

      assert_received {:lm_call, messages, _opts}
      assert count_structs(messages, Types.File) == 1
    end

    # Upstream: tests/signatures/test_adapter_file.py::test_file_list_in_signature
    test "file list in signature", %{sample_text_file: path} do
      lm = capture_lm(fn _messages -> {:ok, %{summary: "Multiple files"}} end)
      program = Imp.predict("documents -> summary", lm: lm)

      files = [Types.File.from_path(path), Types.File.from_file_id("file_uploaded")]

      assert {:ok, prediction} = Imp.call(program, %{documents: files})
      assert Imp.get(prediction, :summary) == "Multiple files"

      assert_received {:lm_call, messages, _opts}
      assert count_structs(messages, Types.File) == 2
    end

    # Upstream: tests/signatures/test_adapter_file.py::test_optional_file_field
    test "optional file field" do
      lm = capture_lm(fn _messages -> {:ok, %{output: "Hello"}} end)
      program = Imp.predict("document -> output", lm: lm)

      assert {:ok, prediction} = Imp.call(program, %{document: nil})
      assert Imp.get(prediction, :output) == "Hello"

      assert_received {:lm_call, messages, _opts}
      assert count_structs(messages, Types.File) == 0
    end

    # Upstream: tests/signatures/test_adapter_file.py::test_file_path_not_found
    test "file path not found" do
      assert_raise ArgumentError, ~r/file not found or not a regular file/, fn ->
        Types.File.from_path("/nonexistent/path/file.txt")
      end
    end

    # Upstream: tests/signatures/test_adapter_file.py::test_file_custom_mime_type
    test "file custom mime type", %{sample_text_file: path} do
      %{file: %{file_data: file_data}} =
        path |> Types.File.from_path(mime_type: "text/custom") |> Types.to_openai()

      assert String.starts_with?(file_data, "data:text/custom;base64,")
    end

    # Upstream: tests/signatures/test_adapter_file.py::test_file_from_bytes_custom_mime
    test "file from bytes custom mime" do
      %{file: %{file_data: file_data}} =
        Types.to_openai(%Types.File{data: Base.encode64("audio data"), mime_type: "audio/mp3"})

      assert String.starts_with?(file_data, "data:audio/mp3;base64,")
    end

    # Upstream: tests/signatures/test_adapter_file.py::test_file_data_uri_in_format
    test "file data uri in format" do
      %{file: %{file_data: file_data}} =
        Types.to_openai(%Types.File{data: Base.encode64("test"), mime_type: "text/plain"})

      assert file_data =~ "data:text/plain;base64,"
    end
  end

  # ---------------------------------------------------------------------------
  # tests/signatures/test_adapter_image.py
  # ---------------------------------------------------------------------------

  describe "test_adapter_image.py" do
    # Upstream: tests/signatures/test_adapter_image.py::test_basic_image_operations
    # (parameterized; 3 of 4 cases ported. The bbox case needs tuple output
    # types, which Imp does not model — recorded as blocked in the table.)
    test "basic image operations" do
      cases = [
        {"image, class_labels -> probabilities: object",
         %{
           image: %Types.Image{url: "https://example.com/dog.jpg"},
           class_labels: ["dog", "cat", "bird"]
         }, :probabilities, %{"dog" => 0.8, "cat" => 0.1, "bird" => 0.1}},
        {"ui_image, target_language -> generated_code",
         %{
           ui_image: %Types.Image{url: "https://example.com/button.png"},
           target_language: "HTML"
         }, :generated_code, "<button>Click me</button>"},
        {"image, languages -> captions: object",
         %{
           image: %Types.Image{url: "https://example.com/dog.jpg"},
           languages: ["en", "es", "fr"]
         }, :captions,
         %{
           "en" => "A golden retriever",
           "es" => "Un golden retriever",
           "fr" => "Un golden retriever"
         }}
      ]

      for {spec, inputs, output_key, expected} <- cases do
        lm = capture_lm(fn _messages -> {:ok, %{output_key => expected}} end)
        program = Imp.predict(spec, lm: lm)

        assert {:ok, prediction} = Imp.call(program, inputs)
        assert Imp.get(prediction, output_key) == expected

        assert_received {:lm_call, messages, _opts}
        assert count_structs(messages, Types.Image) == 1
      end
    end

    # Upstream: tests/signatures/test_adapter_image.py::test_optional_image_field
    test "optional image field" do
      lm = capture_lm(fn _messages -> {:ok, %{output: "Hello"}} end)
      program = Imp.predict("image -> output", lm: lm)

      assert {:ok, prediction} = Imp.call(program, %{image: nil})
      assert Imp.get(prediction, :output) == "Hello"

      assert_received {:lm_call, messages, _opts}
      assert count_structs(messages, Types.Image) == 0
    end
  end
end
