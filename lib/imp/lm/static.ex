defmodule Imp.LM.Static do
  @moduledoc """
  Deterministic local LM for examples, tests, and offline workflows.

  Implements the `Imp.LM` behaviour by calling a supplied handler instead of a
  provider, so program structure can be exercised offline.

  Options, given to `new/1` or per call, and merged with the per-call options
  winning:

    * `:handler` — a two-argument function `(messages, opts)` returning the LM
      output. Defaults to a handler that keys off the prompt text. A handler
      that is not a two-argument function raises `ArgumentError`.
    * `:n` — number of completions. `1`, the default, returns one output; an
      integer above 1 calls the handler that many times and returns a list.
      Any other value raises `ArgumentError`.
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

    # Multi-completion (DSPy `n=`): the handler is invoked once per requested
    # completion, so a stateful handler can script distinct answers. `n: 1`,
    # the default, keeps the single-output shape.
    case Keyword.get(opts, :n, 1) do
      1 ->
        {:ok, handler.(messages, opts)}

      n when is_integer(n) and n > 1 ->
        {:ok, Enum.map(1..n, fn _i -> handler.(messages, opts) end)}

      other ->
        raise ArgumentError,
              "#{inspect(__MODULE__)}.generate/2 expects :n to be a positive integer, got: #{inspect(other)}"
    end
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
