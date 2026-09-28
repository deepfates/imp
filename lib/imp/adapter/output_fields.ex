defmodule Imp.Adapter.OutputFields do
  @moduledoc "Internal output fallback/completeness logic shared by adapters."

  # A reply that answers none of the requested outputs is missing every
  # output, even when each one is optional or has a default. DSPy 3.3.1's
  # Chat, JSON and XML adapters apply `apply_output_field_defaults` before
  # their completeness check, so there a signature whose outputs are all
  # optional or defaulted accepts any reply (prose, another adapter's format,
  # a JSON object with other keys) as a prediction built only from defaults.
  # Imp reports it instead: the model did not answer in the requested format,
  # and `Imp.Predict`'s JSON fallback or a caller's retry is the remedy, not a
  # prediction that a program then takes for an answer.
  def require_any(signature, present) when is_map(present) do
    cond do
      signature.outputs == [] -> :ok
      Enum.any?(signature.outputs, &Imp.FieldMap.has_key?(present, &1.name)) -> :ok
      true -> {:error, none_present(signature)}
    end
  end

  # The same rule for a text completion, where a signature that names a text
  # field (`text_field/1`) takes a blank completion as a step that said
  # nothing: its shape is total by declaration. Prose it reads as that field
  # before this check (`text_answer/2`).
  def require_any(signature, present, text) when is_map(present) and is_binary(text) do
    if text_field(signature) && String.trim(text) == "",
      do: :ok,
      else: require_any(signature, present)
  end

  defp none_present(signature) do
    names = Enum.map(signature.outputs, & &1.name)

    %Imp.AdapterParseError{
      kind: :missing_fields,
      message:
        "The response has none of the requested output fields: " <>
          Enum.map_join(names, ", ", &to_string/1) <> ".",
      reason: names
    }
  end

  # The output field `signature.metadata[:text_field]` names: the one that
  # takes a reply written as prose rather than in the adapter's format.
  def text_field(signature) do
    case Map.get(signature.metadata, :text_field, Map.get(signature.metadata, "text_field")) do
      nil -> nil
      name -> Enum.find(signature.outputs, &(to_string(&1.name) == to_string(name)))
    end
  end

  # `{:ok, name}` when a completion is prose for the signature's text field.
  # It is not prose when it is blank, or when it is written in some adapter's
  # format: a `[[ ## field ## ]]` line, an opening tag for one of the
  # signature's outputs, or a JSON object with one of their keys. Such a
  # reply tried to answer in fields; read as prose it would become the whole
  # thought, and a tool call it spelled out would never run. So it goes to
  # the adapter's own parse, where a reply in another format is an error and
  # the JSON fallback reads it.
  def text_answer(signature, text) when is_binary(text) do
    with %{} = field <- text_field(signature),
         true <- String.trim(text) != "",
         false <- formatted?(signature, text) do
      {:ok, field.name}
    else
      _not_prose -> :error
    end
  end

  defp formatted?(signature, text) do
    names = Enum.map(signature.outputs, &to_string(&1.name))

    Imp.Adapter.Chat.marker_line?(text) or
      Enum.any?(names, &Regex.match?(~r/<#{Regex.escape(&1)}[\s\/>]/, text)) or
      json_object_with?(text, names)
  end

  defp json_object_with?(text, names) do
    case Imp.Adapter.JSONRepair.decode_object(text) do
      {:ok, object} -> Enum.any?(names, &Imp.FieldMap.has_key?(object, &1))
      :error -> false
    end
  end

  # DSPy 3.3.1 `apply_output_field_defaults/2`: present values win by key
  # presence; otherwise use a declared default, then nil for a nullable field.
  def complete(signature, present) when is_map(present) do
    {completed, missing} =
      Enum.reduce(signature.outputs, {%{}, []}, fn field, {completed, missing} ->
        case Imp.FieldMap.fetch(present, field.name) do
          {:ok, value} ->
            {Map.put(completed, field.name, value), missing}

          :error ->
            case fetch_default(field) do
              {:ok, default} ->
                {Map.put(completed, field.name, default), missing}

              :error ->
                if optional?(field),
                  do: {Map.put(completed, field.name, nil), missing},
                  else: {completed, missing ++ [field.name]}
            end
        end
      end)

    if missing == [], do: {:ok, completed}, else: {:error, {:missing_output_fields, missing}}
  end

  def optional?(field),
    do: Map.get(field.metadata, :optional, Map.get(field.metadata, "optional", false)) == true

  def fetch_default(field) do
    case Map.fetch(field.metadata, :default) do
      {:ok, default} -> {:ok, default}
      :error -> Map.fetch(field.metadata, "default")
    end
  end

  def required?(field), do: not optional?(field) and fetch_default(field) == :error
end
