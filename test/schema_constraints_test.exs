defmodule SchemaConstraintsTest do
  use ExUnit.Case, async: true

  alias Dachshund.Signature.Field

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

    valid = %{status: "ok", score: 0.5, code: "AB", tags: ["a", "b"], meta: %{count: 2}}
    assert :ok = Dachshund.Schema.validate_fields(fields, valid)

    invalid = %{status: "bad", score: 2, code: "abcde", tags: ["c"], meta: %{count: 0}}
    assert {:error, errors} = Dachshund.Schema.validate_fields(fields, invalid)
    assert Enum.map(errors, & &1.rule) == [:enum, :max, :max_length, :pattern, :enum, :min]
  end

  test "exports stable JSON schema from signature outputs" do
    signature =
      Dachshund.Signature.new(%{
        inputs: [:question],
        outputs: [
          %{name: :answer, type: :string, constraints: %{enum: ["yes", "no"]}},
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

    assert Dachshund.Signature.json_schema(signature) == %{
             "type" => "object",
             "required" => ["answer", "confidence", "items"],
             "properties" => %{
               "answer" => %{"type" => "string", "enum" => ["yes", "no"]},
               "confidence" => %{"type" => "number", "minimum" => 0, "maximum" => 1},
               "items" => %{"type" => "array", "items" => %{"type" => "integer"}},
               "meta" => %{
                 "type" => "object",
                 "properties" => %{"source" => %{"type" => "string"}}
               }
             }
           }
  end

  test "JSON adapter returns retry feedback for constraint failures" do
    signature =
      Dachshund.Signature.new(%{
        inputs: [:question],
        outputs: [
          %{name: :answer, type: :string, constraints: %{enum: ["Paris"]}},
          %{name: :confidence, type: :number, constraints: %{min: 0.8, max: 1.0}}
        ]
      })

    assert {:error, %Dachshund.AdapterParseError{} = error} =
             Dachshund.Adapter.JSON.parse(signature, ~s({"answer":"Lyon","confidence":0.2}), [])

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

    assert :ok = Dachshund.Schema.validate_fields(fields, %{flag: false, meta: %{enabled: false}})

    assert {:error, errors} = Dachshund.Schema.validate_fields(fields, %{meta: %{enabled: false}})
    assert [%{field: :flag, rule: :required}] = errors
  end
end
