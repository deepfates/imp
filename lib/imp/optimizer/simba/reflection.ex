defmodule Imp.Optimizer.SIMBA.Reflection do
  @moduledoc false

  @instructions """
  You will be given two trajectories of an LM program's execution. Help the
  program's modules build up experience on how to maximize the reward assigned
  to the program's outputs on similar future inputs. Avoid boilerplate, make
  advice specific to each module's own subtask, and contrast the worse behavior
  with the better behavior. Return every module name exactly once in
  module_advice.
  """

  @input_names [
    :program_code,
    :modules_defn,
    :program_inputs,
    :oracle_metadata,
    :worse_program_trajectory,
    :worse_program_outputs,
    :worse_reward_value,
    :worse_reward_info,
    :better_program_trajectory,
    :better_program_outputs,
    :better_reward_value,
    :better_reward_info,
    :module_names
  ]

  @typed_input_names [:worse_reward_value, :better_reward_value, :module_names]

  def run(prompt_lm, payload) do
    worse_reward_type = reward_type(Map.get(payload, :worse_reward_value))
    better_reward_type = reward_type(Map.get(payload, :better_reward_value))
    module_names = normalize_module_names!(Map.get(payload, :module_names))

    signature =
      ("program_code: string, modules_defn: string, program_inputs: string, oracle_metadata: string, " <>
         "worse_program_trajectory: string, worse_program_outputs: string, worse_reward_value: #{worse_reward_type}, " <>
         "worse_reward_info: string, better_program_trajectory: string, better_program_outputs: string, " <>
         "better_reward_value: #{better_reward_type}, better_reward_info: string, module_names: array[string] -> " <>
         "discussion: string, module_advice: map")
      |> Imp.Signature.ensure()
      |> Map.put(:instructions, @instructions)

    program =
      Imp.Predict.new(signature,
        lm: prompt_lm,
        adapter: Imp.Adapter.JSON,
        config: [response_format: response_format(module_names)]
      )

    with {:ok, prediction} <-
           Imp.Predict.call(program, reflection_inputs(payload)),
         advice when is_map(advice) <- Imp.get(prediction, :module_advice),
         :ok <- validate_advice(advice, module_names) do
      {:ok, advice, Imp.get(prediction, :discussion)}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_reflection_output, other}}
    end
  end

  @doc false
  def response_format(module_names) when is_list(module_names) do
    properties = Map.new(module_names, &{&1, %{"type" => "string"}})

    %{
      type: "json_schema",
      json_schema: %{
        name: "SIMBAOfferFeedback",
        strict: true,
        schema: %{
          "type" => "object",
          "properties" => %{
            "discussion" => %{"type" => "string"},
            "module_advice" => %{
              "type" => "object",
              "properties" => properties,
              "required" => module_names,
              "additionalProperties" => false
            }
          },
          "required" => ["discussion", "module_advice"],
          "additionalProperties" => false
        }
      }
    }
  end

  defp normalize_module_names!(names) when is_list(names) and names != [] do
    names = Enum.map(names, &to_string/1)

    if Enum.any?(names, &(String.trim(&1) == "")) or length(names) != length(Enum.uniq(names)) do
      raise ArgumentError, "SIMBA reflection requires unique nonblank module names"
    end

    names
  end

  defp normalize_module_names!(_names) do
    raise ArgumentError, "SIMBA reflection requires a nonempty module_names list"
  end

  defp validate_advice(advice, expected_names) do
    entries = Enum.map(advice, fn {name, value} -> {to_string(name), value} end)
    actual_names = entries |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    cond do
      actual_names != Enum.sort(expected_names) ->
        {:error,
         {:invalid_module_advice_keys,
          %{expected: Enum.sort(expected_names), actual: actual_names}}}

      Enum.any?(entries, fn {_name, value} -> not is_binary(value) end) ->
        invalid_names =
          entries
          |> Enum.reject(fn {_name, value} -> is_binary(value) end)
          |> Enum.map(&elem(&1, 0))
          |> Enum.sort()

        {:error, {:invalid_module_advice_values, %{expected: :string, invalid: invalid_names}}}

      true ->
        :ok
    end
  end

  defp reflection_inputs(payload) do
    Map.new(@input_names, fn name ->
      value = Map.get(payload, name)

      normalized =
        if name in @typed_input_names,
          do: json_safe(value),
          else: if(is_binary(value), do: value, else: encode_value(value))

      {name, normalized}
    end)
  end

  defp encode_value(value) do
    value
    |> json_safe()
    |> Jason.encode!(pretty: true)
  end

  defp json_safe(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {json_key(key), json_safe(nested)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_safe()

  defp json_safe(value), do: "<non-serializable: #{value_type(value)}>"

  defp json_key(key) when is_binary(key), do: key
  defp json_key(key) when is_atom(key) or is_number(key), do: to_string(key)
  defp json_key(key), do: inspect(key)

  defp value_type(value) when is_function(value), do: "function"
  defp value_type(value) when is_pid(value), do: "pid"
  defp value_type(value) when is_port(value), do: "port"
  defp value_type(value) when is_reference(value), do: "reference"
  defp value_type(_value), do: "term"

  defp reward_type(value) when is_number(value), do: "float"
  defp reward_type(_value), do: "string"
end
