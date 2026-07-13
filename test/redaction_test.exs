defmodule DSEx.RedactionTest do
  use ExUnit.Case, async: true

  alias DSEx.Adapters.Types.Image

  defmodule OrdinaryStruct do
    defstruct [:value]
  end

  test "redacts nested ASI image metadata without scanning opaque image fields" do
    base64 = String.duplicate("c2VjcmV0", 12)

    image = %Image{
      url: "https://example.test/image?token=sk-url-secret-1234567890",
      data: base64,
      mime_type: "image/png",
      metadata: %{
        authorization: "Bearer abcdefghijklmnop",
        nested: [%{api_key: "short-secret", label: "keep"}]
      }
    }

    redacted =
      DSEx.Redaction.redact(%{
        side_information: %{prompt: [%{"Image" => image}]}
      })

    assert %Image{} = redacted.side_information.prompt |> hd() |> Map.fetch!("Image")
    redacted_image = redacted.side_information.prompt |> hd() |> Map.fetch!("Image")

    assert redacted_image.url == image.url
    assert redacted_image.data == base64
    assert redacted_image.mime_type == image.mime_type
    assert redacted_image.metadata.authorization == "[REDACTED]"
    assert redacted_image.metadata.nested == [%{api_key: "[REDACTED]", label: "keep"}]
  end

  test "ordinary structs and maps retain existing redaction behavior" do
    assert DSEx.Redaction.redact(%OrdinaryStruct{value: %{api_key: "secret"}}) == %{
             value: %{api_key: "[REDACTED]"}
           }

    assert DSEx.Redaction.redact(%{label: "keep", nested: %{token: "short"}}) == %{
             label: "keep",
             nested: %{token: "[REDACTED]"}
           }
  end
end
