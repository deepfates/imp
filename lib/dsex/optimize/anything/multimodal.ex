defmodule DSEx.Optimize.Anything.Multimodal do
  @moduledoc false

  alias DSEx.Adapters.Types.Image

  @spec render(term()) :: {String.t(), [Image.t()]}
  def render(term) do
    {text, images, _next_index} = render(term, [], 1)
    {text, Enum.reverse(images)}
  end

  @spec content(String.t(), [Image.t()]) :: String.t() | [String.t() | Image.t()]
  def content(prompt, []), do: prompt
  def content(prompt, images), do: [prompt | images]

  defp render(%Image{} = image, images, index) do
    {"[IMAGE-#{index} - see visual content]", [image | images], index + 1}
  end

  defp render(%_{} = struct, images, index), do: {inspect(struct), images, index}

  defp render(map, images, index) when is_map(map) do
    {entries, images, index} =
      map
      |> Enum.sort_by(fn {key, _value} -> inspect(key) end)
      |> Enum.reduce({[], images, index}, fn {key, value}, {entries, images, index} ->
        {rendered, images, index} = render(value, images, index)
        {["#{inspect(key)} => #{rendered}" | entries], images, index}
      end)

    {"%{" <> (entries |> Enum.reverse() |> Enum.join(", ")) <> "}", images, index}
  end

  defp render(list, images, index) when is_list(list) do
    {items, images, index} = render_sequence(list, images, index)
    {"[" <> Enum.join(items, ", ") <> "]", images, index}
  end

  defp render(tuple, images, index) when is_tuple(tuple) do
    {items, images, index} = tuple |> Tuple.to_list() |> render_sequence(images, index)
    {"{" <> Enum.join(items, ", ") <> "}", images, index}
  end

  defp render(value, images, index), do: {inspect(value), images, index}

  defp render_sequence(values, images, index) do
    {items, images, index} =
      Enum.reduce(values, {[], images, index}, fn value, {items, images, index} ->
        {rendered, images, index} = render(value, images, index)
        {[rendered | items], images, index}
      end)

    {Enum.reverse(items), images, index}
  end
end
