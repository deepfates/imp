defmodule DSPy.LM.Fake do
  @moduledoc "Deterministic LM for tests and local examples."

  @behaviour DSPy.LM

  @impl true
  def generate(messages, opts) do
    handler = Keyword.get(opts, :handler, &default_handler/2)
    {:ok, handler.(messages, opts)}
  end

  defp default_handler(messages, _opts) do
    prompt = messages |> Enum.map(&Map.get(&1, :content, "")) |> Enum.join("\n")

    cond do
      prompt =~ "reasoning" ->
        %{reasoning: "Because the prompt asks for reasoning.", answer: "ok"}

      prompt =~ "answer" ->
        %{answer: "ok"}

      true ->
        %{output: "ok"}
    end
  end
end
