defmodule DSEx.Optimizer.ReportMultimodalTest do
  use ExUnit.Case, async: true

  alias DSEx.Adapters.Types.Image
  alias DSEx.Optimizer.Report

  defmodule OrdinaryStruct do
    defstruct []
  end

  test "JSON-safe optimizer values round trip nested ASI images and metadata" do
    base64 = String.duplicate("iVBORw0KGgo", 10) <> "=="

    value = %{
      side_information: %{
        prompt: [
          %{
            image: %Image{
              data: base64,
              mime_type: "image/png",
              metadata: %{detail: :high, lineage: {:source, 2}}
            }
          }
        ]
      }
    }

    encoded = Report.json_safe(value)

    assert get_in(encoded, ["side_information", "prompt", Access.at(0), "image"]) == %{
             "__dsex_type__" => "image",
             "schema_version" => 1,
             "url" => nil,
             "data" => base64,
             "mime_type" => "image/png",
             "metadata" => %{
               "detail" => %{"__dsex_type__" => "atom", "value" => "high"},
               "lineage" => %{
                 "__dsex_type__" => "tuple",
                 "items" => [
                   %{"__dsex_type__" => "atom", "value" => "source"},
                   2
                 ]
               }
             }
           }

    restored = encoded |> Jason.encode!() |> Jason.decode!() |> Report.restore_json_safe()

    assert restored == value
    assert get_in(restored, [:side_information, :prompt, Access.at(0), :image]).data == base64
  end

  test "JSON-safe optimizer values reject malformed reserved image tags" do
    valid = %Image{url: "https://example.test/image.png"} |> Report.json_safe()

    malformed = [
      Map.delete(valid, "metadata"),
      Map.put(valid, "schema_version", 2),
      Map.put(valid, "url", 123),
      Map.put(valid, "metadata", []),
      Map.put(valid, "unexpected", "field")
    ]

    Enum.each(malformed, fn tag ->
      assert_raise ArgumentError, "malformed DSEx image JSON tag", fn ->
        Report.restore_json_safe(tag)
      end
    end)
  end

  test "JSON-safe optimizer values preserve ordinary structs and maps" do
    value = %{
      ordinary_struct: %OrdinaryStruct{},
      ordinary_map: %{kind: "plain", nested: %{count: 1}}
    }

    restored =
      value
      |> Report.json_safe()
      |> Jason.encode!()
      |> Jason.decode!()
      |> Report.restore_json_safe()

    assert restored == %{
             ordinary_struct: %{},
             ordinary_map: %{kind: "plain", nested: %{count: 1}}
           }
  end
end
