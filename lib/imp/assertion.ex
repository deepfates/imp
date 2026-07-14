defmodule Imp.Assertion do
  @moduledoc """
  Named runtime constraint for Imp predictions.

  Assertions are ordinary Elixir predicates over a prediction, or over
  `{inputs, prediction}`. They provide the useful production core of DSPy's
  assertion/self-refinement lineage: executable constraints that can produce
  feedback for another attempt.

      iex> assertion = Imp.Assertion.new(:one_word, fn pred ->
      ...>   pred |> Imp.Prediction.get(:answer, "") |> String.split() |> length() == 1
      ...> end, message: "Answer with one word.")
      iex> assertion.name
      :one_word

  """

  @type t :: %__MODULE__{
          name: atom() | String.t(),
          predicate: function(),
          message: String.t()
        }

  defstruct [:name, :predicate, :message]

  @option_schema [
    message: [type: :string, default: "Assertion failed."]
  ]

  @doc "Builds a named assertion from a unary or binary predicate."
  def new(name, predicate, opts \\ [])

  def new(name, predicate, opts) when is_atom(name) or is_binary(name) do
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Assertion.new/3")
    validate_predicate!(predicate)
    %__MODULE__{name: name, predicate: predicate, message: opts[:message]}
  end

  def new(name, _predicate, _opts) do
    raise ArgumentError,
          "Imp.Assertion.new/3 expects an atom or string name; got: #{inspect(name)}"
  end

  @doc false
  def normalize!(%__MODULE__{} = assertion), do: assertion

  def normalize!({name, predicate}) do
    new(name, predicate)
  end

  def normalize!({name, predicate, message}) when is_binary(message) do
    new(name, predicate, message: message)
  end

  def normalize!(other) do
    raise ArgumentError,
          "expected Imp.Assertion structs or {name, predicate, message} tuples; got: #{inspect(other)}"
  end

  defp validate_predicate!(predicate)
       when is_function(predicate, 1) or is_function(predicate, 2),
       do: :ok

  defp validate_predicate!(predicate) do
    raise ArgumentError,
          "Imp.Assertion predicate must be a unary or binary function; got: #{inspect(predicate)}"
  end
end
