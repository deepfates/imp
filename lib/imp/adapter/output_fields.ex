defmodule Imp.Adapter.OutputFields do
  @moduledoc "Internal output fallback/completeness logic shared by adapters."

  # A text reply that answers none of the requested outputs is missing every
  # output, even when each one is optional or has a default. DSPy 3.3.1's
  # Chat, JSON and XML adapters apply `apply_output_field_defaults` before
  # their completeness check, so there a signature whose outputs are all
  # optional or defaulted accepts any reply (prose, another adapter's format,
  # a JSON object with other keys) as a prediction built only from defaults.
  # Imp reports it instead: the model did not answer in the requested format,
  # and `Imp.Predict`'s JSON fallback or a caller's retry is the remedy, not a
  # prediction that a program then takes for an answer.
  #
  # A signature that names a text field (`text_field/1`) is exempt: its shape
  # is total by declaration, so a reply outside the format is that field and a
  # blank one is a step that said nothing.
  def require_any(signature, present) when is_map(present) do
    cond do
      signature.outputs == [] -> :ok
      text_field(signature) -> :ok
      Enum.any?(signature.outputs, &Imp.FieldMap.has_key?(present, &1.name)) -> :ok
      true -> {:error, none_present(signature)}
    end
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
  # takes a reply written outside the adapter's format.
  def text_field(signature) do
    case Map.get(signature.metadata, :text_field, Map.get(signature.metadata, "text_field")) do
      nil -> nil
      name -> Enum.find(signature.outputs, &(to_string(&1.name) == to_string(name)))
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
