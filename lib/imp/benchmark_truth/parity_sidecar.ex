defmodule Imp.BenchmarkTruth.ParitySidecar do
  @moduledoc false

  alias Imp.ExternalCommand.Lifecycle
  alias Imp.ExternalCommand.Lifecycle.Capture

  defmodule Output do
    @moduledoc false

    @enforce_keys [:text, :truncated, :total_bytes, :captured_bytes, :limit_bytes]
    defstruct [:text, :truncated, :total_bytes, :captured_bytes, :limit_bytes]

    @type t :: %__MODULE__{
            text: binary(),
            truncated: boolean(),
            total_bytes: non_neg_integer(),
            captured_bytes: non_neg_integer(),
            limit_bytes: pos_integer()
          }
  end

  @type result :: {:ok, Output.t(), non_neg_integer()} | {:error, :timeout, Output.t()}

  @spec run(binary(), [binary()], keyword()) :: result()
  def run(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    opts =
      opts
      |> Keyword.update(:timeout, :infinity, &validate_timeout!/1)
      |> Keyword.update(:max_output_bytes, 256 * 1024, &validate_output_limit!/1)
      |> Keyword.update(:secrets, [], &validate_secrets!/1)
      |> Keyword.put_new(:kill_grace_ms, 500)

    case Lifecycle.run(executable, args, opts) do
      {:ok, %Capture{} = capture, status} ->
        {:ok, from_capture(capture), status}

      {:error, :timeout, %Capture{} = capture} ->
        {:error, :timeout, from_capture(capture)}

      {:error, {:executable_not_found, command}} ->
        raise ArgumentError, "executable not found: #{command}"

      {:error, reason} ->
        raise "sidecar lifecycle failed: #{inspect(reason)}"
    end
  end

  @doc false
  @spec diagnostic(Output.t()) :: binary()
  def diagnostic(%Output{} = output) do
    if output.truncated do
      "[sidecar output truncated: captured tail #{output.captured_bytes} of " <>
        "#{output.total_bytes} bytes; limit #{output.limit_bytes} bytes]\n#{output.text}"
    else
      output.text
    end
  end

  defp from_capture(capture) do
    %Output{
      text: capture.text,
      truncated: capture.truncated,
      total_bytes: capture.total_bytes,
      captured_bytes: capture.captured_bytes,
      limit_bytes: capture.limit_bytes
    }
  end

  defp validate_timeout!(:infinity), do: :infinity
  defp validate_timeout!(timeout) when is_integer(timeout) and timeout > 0, do: timeout

  defp validate_timeout!(timeout) do
    raise ArgumentError,
          "sidecar timeout must be a positive integer or :infinity, got: #{inspect(timeout)}"
  end

  defp validate_output_limit!(limit) when is_integer(limit) and limit > 0, do: limit

  defp validate_output_limit!(limit) do
    raise ArgumentError,
          "sidecar output limit must be a positive integer, got: #{inspect(limit)}"
  end

  defp validate_secrets!(secrets) when is_list(secrets) do
    secrets
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn
      secret when is_binary(secret) and secret != "" ->
        secret

      invalid ->
        raise ArgumentError, "sidecar secrets must be non-empty strings: #{inspect(invalid)}"
    end)
    |> Enum.uniq()
  end

  defp validate_secrets!(secrets) do
    raise ArgumentError, "sidecar secrets must be a list, got: #{inspect(secrets)}"
  end
end
