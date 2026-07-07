defmodule DSEx.LM.Static do
  @moduledoc """
  Deterministic local LM for examples, tests, and offline workflows.

  `DSEx.LM.Static` implements the `DSEx.LM` behaviour by calling a supplied
  handler function. It is useful when you want to teach, test, or debug DSEx
  program structure without reaching a provider.
  """

  @behaviour DSEx.LM

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
