defmodule SchemaConstraintsTest do
  use ExUnit.Case, async: true

  alias Imp.Signature.Field

  test "validates enum numeric string array object optional and nested constraints" do
    fields = [
      Field.new(%{name: :status, type: :string, constraints: %{enum: ["ok", "warn"]}}, :output),
      Field.new(%{name: :score, type: :number, constraints: %{min: 0, max: 1}}, :output),
      Field.new(
        %{
          name: :code,
          type: :string,
          constraints: %{min_length: 2, max_length: 4, pattern: "^[A-Z]+$"}
        },
        :output
      ),
      Field.new(%{name: :verdict, type: :string, constraints: %{answer_shape: :yes_no}}, :output),
      Field.new(
        %{name: :amount, type: :string, constraints: %{answer_shape: :numeric_span}},
        :output
      ),
      Field.new(
        %{name: :span, type: :string, constraints: %{answer_shape: :short_span}},
        :output
      ),
      Field.new(
        %{name: :tags, type: :array, constraints: %{items: %{type: :string, enum: ["a", "b"]}}},
        :output
      ),
      Field.new(
        %{
          name: :meta,
          type: :object,
          constraints: %{properties: %{count: %{type: :integer, min: 1}}}
        },
        :output
      ),
      Field.new(%{name: :note, type: :string, metadata: %{optional: true}}, :output)
    ]

    valid = %{
      status: "ok",
      score: 0.5,
      code: "AB",
      verdict: "Yes",
      amount: "$1,200.50",
      span: "Henry J. Kaiser",
      tags: ["a", "b"],
      meta: %{count: 2}
    }

    assert :ok = Imp.Schema.validate_fields(fields, valid)

    invalid = %{
      status: "bad",
      score: 2,
      code: "abcde",
      verdict: "Paris",
      amount: "about 12",
      span: "Paris is the capital; it is in France",
      tags: ["c"],
      meta: %{count: 0}
    }

    assert {:error, errors} = Imp.Schema.validate_fields(fields, invalid)

    assert Enum.map(errors, & &1.rule) == [
             :enum,
             :max,
             :max_length,
             :pattern,
             :answer_shape,
             :answer_shape,
             :answer_shape,
             :enum,
             :min
           ]
  end

  test "exports stable JSON schema from signature outputs" do
    signature =
      Imp.Signature.new(%{
        inputs: [:question],
        outputs: [
          %{name: :answer, type: :string, constraints: %{enum: ["yes", "no"]}},
          %{name: :span, type: :string, constraints: %{answerShape: "short_span"}},
          %{name: :confidence, type: :number, constraints: %{min: 0, max: 1}},
          %{name: :items, type: :array, constraints: %{items: %{type: :integer}}},
          %{
            name: :meta,
            type: :object,
            constraints: %{properties: %{source: %{type: :string}}},
            metadata: %{optional: true}
          }
        ]
      })

    assert Imp.Signature.json_schema(signature) == %{
             "type" => "object",
             "additionalProperties" => false,
             "required" => ["answer", "span", "confidence", "items"],
             "properties" => %{
               "answer" => %{"type" => "string", "enum" => ["yes", "no"]},
               "span" => %{"type" => "string", "x-imp-answerShape" => "short_span"},
               "confidence" => %{"type" => "number", "minimum" => 0, "maximum" => 1},
               "items" => %{"type" => "array", "items" => %{"type" => "integer"}},
               "meta" => %{
                 "type" => "object",
                 "additionalProperties" => false,
                 "properties" => %{"source" => %{"type" => "string"}},
                 "required" => ["source"]
               }
             }
           }
  end

  test "exports recursive provider schema with nested required and optional fields" do
    signature =
      Imp.Signature.new(%{
        inputs: [:question],
        outputs: [
          %{
            name: :candidates,
            type: :array,
            constraints: %{
              items: %{
                type: :object,
                properties: %{
                  name: %{type: :string, min_length: 2, pattern: "^[A-Z]"},
                  score: %{type: :number, min: 0, max: 1},
                  tags: %{
                    type: :array,
                    items: %{type: :string, enum: ["clear", "novel"]}
                  },
                  rationale: %{type: :string, optional: true, max_length: 120}
                }
              }
            }
          }
        ]
      })

    item_schema =
      signature
      |> Imp.Signature.json_schema()
      |> get_in(["properties", "candidates", "items"])

    assert item_schema["type"] == "object"
    assert item_schema["additionalProperties"] == false
    assert item_schema["required"] == ["name", "score", "tags"]

    assert get_in(item_schema, ["properties", "name"]) == %{
             "type" => "string",
             "minLength" => 2,
             "pattern" => "^[A-Z]"
           }

    assert get_in(item_schema, ["properties", "score"]) == %{
             "type" => "number",
             "minimum" => 0,
             "maximum" => 1
           }

    assert get_in(item_schema, ["properties", "tags", "items"]) == %{
             "type" => "string",
             "enum" => ["clear", "novel"]
           }

    assert get_in(item_schema, ["properties", "rationale", "maxLength"]) == 120
  end

  test "Static prediction receives and enforces the recursive native schema" do
    signature =
      Imp.Signature.new(%{
        inputs: [:question],
        outputs: [
          %{
            name: :items,
            type: :array,
            constraints: %{
              items: %{
                type: :object,
                properties: %{label: %{type: :string}, confidence: %{type: :number}}
              }
            }
          }
        ]
      })

    handler = fn _messages, opts ->
      schema = get_in(opts, [:response_format, :json_schema, :schema])
      send(self(), {:static_schema, schema})
      %{"items" => [%{"label" => "BEAM", "confidence" => 0.9}]}
    end

    program =
      Imp.predict(signature,
        adapter: Imp.Adapter.JSON,
        lm: %{module: Imp.LM.Static, opts: [handler: handler]},
        config: [native_json_schema: true]
      )

    assert {:ok, prediction} = Imp.Predict.Predict.call(program, %{question: "runtime?"})
    assert [%{"label" => "BEAM", "confidence" => 0.9}] = Imp.get(prediction, :items)
    assert_receive {:static_schema, schema}

    assert get_in(schema, ["properties", "items", "items", "required"]) == [
             "confidence",
             "label"
           ]
  end

  test "loaded JSON metadata preserves string-key constraints" do
    original =
      Imp.Signature.new(%{
        inputs: [:question],
        outputs: [
          %{name: :score, type: :number, constraints: %{min: 0, max: 1}},
          %{
            name: :meta,
            type: :object,
            constraints: %{properties: %{count: %{type: :integer, min: 1}}}
          }
        ]
      })

    loaded =
      original
      |> Imp.Signature.dump()
      |> Jason.encode!()
      |> Jason.decode!()
      |> Imp.Signature.load()

    assert {:error, errors} =
             Imp.Schema.validate_fields(loaded.outputs, %{score: 2, meta: %{count: 0}})

    assert Enum.map(errors, & &1.rule) == [:max, :min]
    assert Imp.Signature.json_schema(loaded)["properties"]["score"]["maximum"] == 1

    assert get_in(Imp.Signature.json_schema(loaded), ["properties", "meta", "required"]) == [
             "count"
           ]

    assert {:error, [%{field: "meta.count", rule: :type}]} =
             Imp.Schema.validate_fields(loaded.outputs, %{score: 0.5, meta: %{count: "one"}})
  end

  test "invalid regex constraints become validation errors instead of crashes" do
    fields = [
      Field.new(%{name: :code, type: :string, constraints: %{pattern: "["}}, :output)
    ]

    assert {:error, [%{field: :code, rule: :pattern, message: message}]} =
             Imp.Schema.validate_fields(fields, %{code: "ABC"})

    assert message =~ "invalid regex pattern"
  end

  test "JSON adapter returns retry feedback for constraint failures" do
    signature =
      Imp.Signature.new(%{
        inputs: [:question],
        outputs: [
          %{name: :answer, type: :string, constraints: %{enum: ["Paris"]}},
          %{name: :confidence, type: :number, constraints: %{min: 0.8, max: 1.0}}
        ]
      })

    assert {:error, %Imp.AdapterParseError{} = error} =
             Imp.Adapter.JSON.parse(signature, ~s({"answer":"Lyon","confidence":0.2}), [])

    assert error.message =~ "Validation failed"
    assert error.message =~ "answer"
    assert error.message =~ "confidence"
    assert error.message =~ "Retry with corrected output"
  end

  test "boolean false is valid and missing boolean is still required" do
    fields = [
      Field.new(%{name: :flag, type: :boolean}, :output),
      Field.new(
        %{name: :meta, type: :object, constraints: %{properties: %{enabled: %{type: :boolean}}}},
        :output
      )
    ]

    assert :ok = Imp.Schema.validate_fields(fields, %{flag: false, meta: %{enabled: false}})

    assert {:error, errors} = Imp.Schema.validate_fields(fields, %{meta: %{enabled: false}})
    assert [%{field: :flag, rule: :required}] = errors
  end
end
