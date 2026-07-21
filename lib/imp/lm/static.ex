defmodule Imp.LM.Static do
  @moduledoc """
  Deterministic local LM for examples, tests, and offline workflows.

  `Imp.LM.Static` implements the `Imp.LM` behaviour by calling a supplied
  handler function. It is useful when you want to teach, test, or debug Imp
  program structure without reaching a provider.
  """

  @behaviour Imp.LM

  defstruct opts: []

  @doc """
  Builds a configured static LM struct.

      lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "ok"} end)
      Imp.configure(lm: lm)
  """
  def new(opts \\ []) do
    %__MODULE__{opts: validate_opts!(opts, "#{inspect(__MODULE__)}.new/1")}
  end

  @doc "Generates through a configured `Imp.LM.Static` struct."
  def generate(%__MODULE__{opts: configured}, messages, opts) do
    generate(messages, Keyword.merge(configured, opts))
  end

  @impl true
  def generate(messages, opts) do
    opts = validate_opts!(opts, "#{inspect(__MODULE__)}.generate/2")
    handler = Keyword.get(opts, :handler, &default_handler/2)

    unless is_function(handler, 2) do
      raise ArgumentError,
            "#{inspect(__MODULE__)}.generate/2 expects :handler to be a two-argument function, got: #{inspect(handler)}"
    end

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

  defp validate_opts!(opts, context) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
    else
      raise ArgumentError, "#{context} expects keyword options, got: #{inspect(opts)}"
    end
  end

  defp validate_opts!(opts, context) do
    raise ArgumentError, "#{context} expects keyword options, got: #{inspect(opts)}"
  end
end
