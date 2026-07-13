defmodule DSEx.Optimizer.Report do
  @moduledoc "Optimizer candidate history and diagnostic metadata."

  defstruct optimizer: nil,
            best_score: nil,
            candidate_count: 0,
            candidates: [],
            errors: [],
            metadata: %{}

  @doc """
  Builds an optimizer report from atom-key, string-key, or keyword attributes.

  String-key support is intentional: report data is often restored from JSON
  artifacts or provider/debug payloads before it is attached back to a program.
  Malformed attribute containers raise DSEx-context errors instead of generic
  `Map.new/1` failures.
  """
  def new(attrs \\ %{}) do
    attrs = normalize_attrs!(attrs)

    %__MODULE__{
      optimizer: fetch(attrs, :optimizer),
      best_score: fetch(attrs, :best_score),
      candidate_count: fetch(attrs, :candidate_count, 0),
      candidates: fetch(attrs, :candidates, []),
      errors: fetch(attrs, :errors, []),
      metadata: fetch(attrs, :metadata, %{})
    }
  end

  defp normalize_attrs!(attrs) when is_map(attrs) or is_list(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) or is_binary(key) ->
        {key, value}

      invalid ->
        raise ArgumentError,
              "DSEx.Optimizer.Report.new/1 expects attrs as atom or string keyed pairs; got entry: #{inspect(invalid)}"
    end)
  end

  defp normalize_attrs!(attrs) do
    raise ArgumentError,
          "DSEx.Optimizer.Report.new/1 expects a map or keyword list; got: #{inspect(attrs)}"
  end

  def dump(%__MODULE__{} = report) do
    %{
      "optimizer" => encode_atom(report.optimizer),
      "best_score" => report.best_score,
      "candidate_count" => report.candidate_count,
      "candidates" => Enum.map(report.candidates, &dump_value/1),
      "errors" => Enum.map(report.errors, &dump_value/1),
      "metadata" => dump_value(report.metadata)
    }
  end

  def load(state) when is_map(state) do
    new(%{
      optimizer: state |> fetch(:optimizer) |> decode_atom_or_value(),
      best_score: fetch(state, :best_score),
      candidate_count: fetch(state, :candidate_count, 0),
      candidates: state |> fetch(:candidates, []) |> Enum.map(&load_value/1),
      errors: state |> fetch(:errors, []) |> Enum.map(&load_value/1),
      metadata: state |> fetch(:metadata, %{}) |> load_value()
    })
  end

  def json_safe(value), do: dump_value(value)
  def restore_json_safe(value), do: load_value(value)

  def attach(program, %__MODULE__{} = report),
    do: DSEx.ProgramAccess.put_metadata(program, :optimizer_report, report)

  def fetch(program), do: DSEx.ProgramAccess.get_metadata(program, :optimizer_report)

  defp dump_value(%DSEx.Example{} = example) do
    %{
      "__dsex_type__" => "example",
      "fields" => dump_value(DSEx.Example.to_map(example)),
      "input_keys" => dump_value(example.input_keys),
      "demos" => dump_value(example.demos)
    }
  end

  defp dump_value(%__MODULE__{} = report) do
    Map.put(dump(report), "__dsex_type__", "optimizer_report")
  end

  defp dump_value(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {encode_key(key), dump_value(value)} end)

  defp dump_value(list) when is_list(list), do: Enum.map(list, &dump_value/1)

  defp dump_value(tuple) when is_tuple(tuple) do
    %{
      "__dsex_type__" => "tuple",
      "items" => tuple |> Tuple.to_list() |> Enum.map(&dump_value/1)
    }
  end

  defp dump_value(value) when is_atom(value),
    do: %{"__dsex_type__" => "atom", "value" => Atom.to_string(value)}

  defp dump_value(value), do: value

  defp load_value(%{"__dsex_type__" => "atom", "value" => value}) do
    String.to_existing_atom(value)
  end

  defp load_value(%{"__dsex_type__" => "optimizer_report"} = state) do
    state
    |> Map.delete("__dsex_type__")
    |> load()
  end

  defp load_value(%{"__dsex_type__" => "example"} = state) do
    state
    |> Map.fetch!("fields")
    |> load_value()
    |> DSEx.Example.new()
    |> maybe_with_inputs(load_value(Map.get(state, "input_keys")))
    |> maybe_with_demos(load_value(Map.get(state, "demos", [])))
  end

  defp load_value(%{"__dsex_type__" => "tuple", "items" => items}) when is_list(items) do
    items |> Enum.map(&load_value/1) |> List.to_tuple()
  end

  defp load_value(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {decode_key(key), load_value(value)} end)

  defp load_value(list) when is_list(list), do: Enum.map(list, &load_value/1)
  defp load_value(value), do: value

  defp maybe_with_inputs(example, nil), do: example
  defp maybe_with_inputs(example, input_keys), do: DSEx.Example.with_inputs(example, input_keys)

  defp maybe_with_demos(example, []), do: example
  defp maybe_with_demos(example, demos), do: DSEx.Example.with_demos(example, demos)

  defp encode_key(key) when is_atom(key), do: Atom.to_string(key)
  defp encode_key(key), do: key

  defp decode_key(key) when is_binary(key), do: existing_atom_or_string(key)
  defp decode_key(key), do: key

  defp encode_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_atom(value), do: value

  defp decode_atom_or_value(value) when is_binary(value), do: existing_atom_or_string(value)
  defp decode_atom_or_value(value), do: value

  defp fetch(map, key, default \\ nil) when is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp existing_atom_or_string(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end
end
