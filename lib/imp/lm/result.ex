defmodule Imp.LM.Result do
  @moduledoc """
  Canonical boundary between LM output and provider metadata.

  Most language models return their output value directly. Provider-backed
  clients may retain transport metadata in a reserved envelope. This module is
  the only place where that envelope is interpreted.
  """

  @atom_output :__imp_lm_output__
  @atom_metadata :__imp_lm_metadata__
  @string_output "__imp_lm_output__"
  @string_metadata "__imp_lm_metadata__"
  @reserved_keys [@atom_output, @atom_metadata, @string_output, @string_metadata]

  @type output :: binary() | map() | Imp.Prediction.t()
  @type metadata :: map()

  @spec split(output()) :: {:ok, output(), metadata()} | {:error, term()}
  def split(value) when is_binary(value) or is_struct(value, Imp.Prediction),
    do: {:ok, value, %{}}

  def split(%{@atom_output => output, @atom_metadata => metadata} = envelope)
      when map_size(envelope) == 2 and is_map(metadata) do
    validate_output(output, metadata)
  end

  def split(%{@string_output => output, @string_metadata => metadata} = envelope)
      when map_size(envelope) == 2 and is_map(metadata) do
    validate_output(output, metadata)
  end

  def split(value) when is_map(value) do
    if Enum.any?(@reserved_keys, &Map.has_key?(value, &1)) do
      {:error, {:invalid_lm_result_envelope, value}}
    else
      {:ok, value, %{}}
    end
  end

  def split(value), do: {:error, {:invalid_lm_result, value}}

  @spec unwrap({:ok, output()} | {:error, term()}) :: {:ok, output()} | {:error, term()}
  def unwrap({:ok, value}) do
    with {:ok, output, _metadata} <- split(value), do: {:ok, output}
  end

  def unwrap({:error, _reason} = error), do: error
  def unwrap(value), do: {:error, {:invalid_lm_result, value}}

  @spec output(output()) :: {:ok, output()} | {:error, term()}
  def output(value) do
    with {:ok, output, _metadata} <- split(value), do: {:ok, output}
  end

  @spec metadata(output()) :: {:ok, metadata()} | {:error, term()}
  def metadata(value) do
    with {:ok, _output, metadata} <- split(value), do: {:ok, metadata}
  end

  defp validate_output(output, metadata) do
    if is_map(output) and Enum.any?(@reserved_keys, &Map.has_key?(output, &1)) do
      {:error, {:nested_lm_result_envelope, output}}
    else
      case split(output) do
        {:ok, _output, _metadata} -> {:ok, output, metadata}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
