defmodule Imp.Observability.Inspection do
  @moduledoc """
  A deterministic, redacted debugging snapshot.

  Inspection entries use a common shape across provider calls, tools, RLM
  actions, optimizer reports, predictions, and telemetry. Large payloads are
  replaced by bounded fingerprints so interactive debugging cannot accidentally
  copy an unbounded model response into the shell or logs.
  """

  @enforce_keys [:kind, :status, :summary, :entries]
  defstruct [:kind, :status, :summary, :entries]

  @type entry :: %{
          required(:source) => atom(),
          required(:sequence) => pos_integer(),
          required(:payload) => term()
        }

  @type t :: %__MODULE__{
          kind: atom(),
          status: atom(),
          summary: map(),
          entries: [entry()]
        }

  @doc false
  def new(kind, status, summary, entries, opts) do
    limit = Keyword.fetch!(opts, :limit)
    max_bytes = Keyword.fetch!(opts, :max_bytes)
    redact? = Keyword.fetch!(opts, :redact)

    entries =
      entries
      |> Enum.take(-limit)
      |> Enum.with_index(1)
      |> Enum.map(fn {{source, payload}, sequence} ->
        payload = if redact?, do: Imp.Redaction.redact(payload), else: payload
        %{source: source, sequence: sequence, payload: compact(payload, max_bytes)}
      end)

    summary = if redact?, do: Imp.Redaction.redact(summary), else: summary
    %__MODULE__{kind: kind, status: status, summary: summary, entries: entries}
  end

  @doc false
  def json_safe(%__MODULE__{} = inspection), do: json_safe(Map.from_struct(inspection))

  def json_safe(value) when is_struct(value), do: value |> Map.from_struct() |> json_safe()

  def json_safe(value) when is_map(value) do
    if Enum.all?(Map.keys(value), &(is_atom(&1) or is_binary(&1))) do
      value
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Map.new(fn {key, nested} -> {to_string(key), json_safe(nested)} end)
    else
      entries =
        value
        |> Enum.sort_by(fn {key, _nested} -> :erlang.term_to_binary(key, [:deterministic]) end)
        |> Enum.map(fn {key, nested} -> [json_safe(key), json_safe(nested)] end)

      %{"__imp_type__" => "map", "entries" => entries}
    end
  end

  def json_safe([]), do: []

  def json_safe([head | tail] = value) do
    if proper_list?(value) do
      Enum.map(value, &json_safe/1)
    else
      %{"__imp_type__" => "improper_list", "head" => json_safe(head), "tail" => json_safe(tail)}
    end
  end

  def json_safe(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&json_safe/1)

  def json_safe(value) when is_atom(value), do: Atom.to_string(value)
  def json_safe(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  def json_safe(nil), do: nil
  def json_safe(value), do: Kernel.inspect(value)

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_tail), do: false

  defp compact(value, max_bytes) do
    bytes = :erlang.external_size(value)

    if bytes <= max_bytes do
      value
    else
      %{
        type: type(value),
        bytes: bytes,
        fingerprint: :erlang.phash2(value),
        truncated: true
      }
    end
  end

  defp type(value) when is_binary(value), do: :binary
  defp type(value) when is_map(value), do: :map
  defp type(value) when is_list(value), do: :list
  defp type(value) when is_tuple(value), do: :tuple
  defp type(_value), do: :term
end
