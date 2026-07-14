defmodule Imp.Optimizer.GEPA.ComBee.Options do
  @moduledoc "Configuration for GEPA ComBee aggregation."

  alias Imp.Optimizer.GEPA.ComBee.BatchController

  defstruct duplication_factor: 2,
            max_concurrency: :auto,
            timeout: :infinity,
            batch_controller: nil

  @type t :: %__MODULE__{
          duplication_factor: pos_integer(),
          max_concurrency: :auto | pos_integer(),
          timeout: timeout(),
          batch_controller: BatchController.Options.t() | nil
        }

  @doc false
  def validate(false), do: {:ok, false}
  def validate(nil), do: {:ok, false}
  def validate(true), do: {:ok, %__MODULE__{}}

  def validate(value) do
    {:ok, new!(value)}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  @doc "Builds strict ComBee options from a keyword list."
  @spec new!(keyword() | t()) :: t()
  def new!(%__MODULE__{} = options), do: validate_options!(options)

  def new!(options) when is_list(options) do
    allowed = [:duplication_factor, :max_concurrency, :timeout, :batch_controller]

    case Keyword.keys(options) -- allowed do
      [] ->
        %__MODULE__{
          duplication_factor: Keyword.get(options, :duplication_factor, 2),
          max_concurrency: Keyword.get(options, :max_concurrency, :auto),
          timeout: Keyword.get(options, :timeout, :infinity),
          batch_controller: batch_controller_options(Keyword.get(options, :batch_controller))
        }
        |> validate_options!()

      unknown ->
        raise ArgumentError, "unknown ComBee options: #{inspect(Enum.sort(unknown))}"
    end
  end

  def new!(value) do
    raise ArgumentError, "ComBee options must be true or a keyword list, got: #{inspect(value)}"
  end

  defp validate_options!(%__MODULE__{} = options) do
    unless is_integer(options.duplication_factor) and options.duplication_factor > 0 do
      raise ArgumentError, "ComBee :duplication_factor must be a positive integer"
    end

    unless options.max_concurrency == :auto or
             (is_integer(options.max_concurrency) and options.max_concurrency > 0) do
      raise ArgumentError, "ComBee :max_concurrency must be :auto or a positive integer"
    end

    unless options.timeout == :infinity or
             (is_integer(options.timeout) and options.timeout > 0) do
      raise ArgumentError, "ComBee :timeout must be :infinity or a positive integer"
    end

    %{options | batch_controller: batch_controller_options(options.batch_controller)}
  end

  defp batch_controller_options(value) when value in [nil, false], do: nil

  defp batch_controller_options(true), do: BatchController.options!([])

  defp batch_controller_options(value), do: BatchController.options!(value)
end
