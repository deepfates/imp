defmodule DSEx.Optimize.Anything.MultimodalTest do
  use ExUnit.Case, async: true

  alias DSEx.Adapters.Types.Image
  alias DSEx.Optimize.Anything.Multimodal

  test "extracts nested images depth-first with deterministic map ordering" do
    first = %Image{url: "https://example.test/first.png"}
    second = %Image{data: "c2Vjb25k", mime_type: "image/png"}

    {text, images} =
      Multimodal.render(%{
        z: [second],
        a: %{evidence: first, score: 0.8}
      })

    assert images == [first, second]
    assert text =~ ":a => %{"
    assert text =~ "[IMAGE-1 - see visual content]"
    assert text =~ ":z => [[IMAGE-2 - see visual content]]"
    assert Multimodal.content("prompt", images) == ["prompt", first, second]
  end

  test "keeps the provider content binary when no images are present" do
    {text, []} = Multimodal.render(%{feedback: "be concise"})
    assert text == "%{:feedback => \"be concise\"}"
    assert Multimodal.content("prompt", []) == "prompt"
  end
end
