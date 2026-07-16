defmodule Imp.Optimizer.ReportMultimodalTest do
  use ExUnit.Case, async: true

  alias Imp.Adapters.Types.Image
  alias Imp.Optimizer.Report

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

    encoded = Report.encode_term(value)

    image_tag =
      encoded
      |> tagged_map_fetch(:side_information)
      |> tagged_map_fetch(:prompt)
      |> hd()
      |> tagged_map_fetch(:image)

    assert image_tag["__imp_type__"] == "image"
    assert image_tag["schema_version"] == 1
    assert image_tag["url"] == nil
    assert image_tag["data"] == base64
    assert image_tag["mime_type"] == "image/png"
    assert image_tag["metadata"] == Report.encode_term(%{detail: :high, lineage: {:source, 2}})

    restored = encoded |> Jason.encode!() |> Jason.decode!() |> Report.decode_term()

    assert restored == value
    assert get_in(restored, [:side_information, :prompt, Access.at(0), :image]).data == base64
  end

  test "JSON-safe optimizer values reject malformed reserved image tags" do
    valid = %Image{url: "https://example.test/image.png"} |> Report.encode_term()

    malformed = [
      Map.delete(valid, "metadata"),
      Map.put(valid, "schema_version", 2),
      Map.put(valid, "url", 123),
      Map.put(valid, "metadata", []),
      Map.put(valid, "unexpected", "field")
    ]

    Enum.each(malformed, fn tag ->
      assert_raise ArgumentError, "malformed Imp image JSON tag", fn ->
        Report.decode_term(tag)
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
      |> Report.encode_term()
      |> Jason.encode!()
      |> Jason.decode!()
      |> Report.decode_term()

    assert restored == %{
             ordinary_struct: %{},
             ordinary_map: %{kind: "plain", nested: %{count: 1}}
           }
  end

  defp tagged_map_fetch(%{"__imp_type__" => "map", "entries" => entries}, key) do
    encoded_key = Report.encode_term(key)
    [_key, value] = Enum.find(entries, fn [candidate, _value] -> candidate == encoded_key end)
    value
  end
end
