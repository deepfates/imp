defmodule Imp.Optimizer.GEPA.InstructionProposal do
  @moduledoc false

  # Port of GEPA v0.1.4's InstructionProposalSignature. The standalone
  # implementation gives the reflection model readable examples and asks for
  # the replacement instruction in a markdown fence. Imp also accepts the
  # typed map/JSON spellings used by its adapters so provider normalization is
  # not coupled to one transport response shape.

  @prompt_template """
  I provided an assistant with the following instructions to perform a task for me:
  ```
  <curr_param>
  ```

  The following are examples of different task inputs provided to the assistant along with the assistant's response for each of them, and some feedback on how the assistant's response could be better:
  ```
  <side_info>
  ```

  Your task is to write a new instruction for the assistant.

  Read the inputs carefully and identify the input format and infer detailed task description about the task I wish to solve with the assistant.

  Read all the assistant responses and the corresponding feedback. Identify all niche and domain specific factual information about the task and include it in the instruction, as a lot of it may not be available to the assistant in the future. The assistant may have utilized a generalizable strategy to solve the task, if so, include that in the instruction as well.

  Provide the new instructions within ``` blocks.
  """

  @instruction_keys ["instruction", :instruction, "new_instruction", :new_instruction]

  @doc false
  def messages(current_instruction, reflective_dataset, global_feedback \\ nil)
      when is_binary(current_instruction) and is_list(reflective_dataset) do
    reflective_dataset = append_global_feedback(reflective_dataset, global_feedback)

    prompt =
      @prompt_template
      |> String.replace("<curr_param>", current_instruction)
      |> String.replace("<side_info>", format_samples(reflective_dataset))

    [%{role: :user, content: prompt}]
  end

  @doc false
  def normalize(response) when is_map(response) do
    case Enum.find_value(@instruction_keys, &fetch_binary(response, &1)) do
      nil -> {:error, {:invalid_reflection_lm_response, response}}
      instruction -> {:ok, instruction}
    end
  end

  def normalize(response) when is_binary(response) do
    instruction = extract_instruction(response)

    case Imp.Adapter.JSONRepair.decode(instruction) do
      {:ok, decoded} when is_map(decoded) -> normalize(decoded)
      _plain_text -> {:ok, instruction}
    end
  end

  def normalize(response), do: {:error, {:invalid_reflection_lm_response, response}}

  @doc false
  def extract_instruction(response) when is_binary(response) do
    stripped = String.trim(response)
    fences = :binary.matches(stripped, "```")

    case fences do
      [{first, 3} | _rest] when length(fences) > 1 ->
        {last, 3} = List.last(fences)
        start = first + 3

        if start < last do
          stripped
          |> binary_part(start, last - start)
          |> strip_language_marker()
          |> String.trim()
        else
          strip_incomplete_fence(stripped)
        end

      _fewer_than_two ->
        strip_incomplete_fence(stripped)
    end
  end

  defp append_global_feedback(dataset, feedback) when is_binary(feedback) do
    case String.trim(feedback) do
      "" -> dataset
      text -> dataset ++ [%{"GlobalFeedback" => text}]
    end
  end

  defp append_global_feedback(dataset, _feedback), do: dataset

  defp format_samples(samples) do
    samples
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {sample, index} ->
      "# Example #{index}\n" <> render_sample(sample)
    end)
  end

  defp render_sample(sample) when is_map(sample) do
    Enum.map_join(sample, "", fn {key, value} ->
      "## #{key}\n" <> render_value(value, 3)
    end)
  end

  defp render_sample(sample), do: "## Value\n" <> render_value(sample, 3)

  defp render_value(value, level) when is_map(value) do
    if map_size(value) == 0 do
      "\n"
    else
      Enum.map_join(value, "", fn {key, nested} ->
        heading(level, key) <> render_value(nested, min(level + 1, 6))
      end)
    end
  end

  defp render_value(value, level) when is_list(value) do
    if value == [] do
      "\n"
    else
      value
      |> Enum.with_index(1)
      |> Enum.map_join("", fn {nested, index} ->
        heading(level, "Item #{index}") <> render_value(nested, min(level + 1, 6))
      end)
    end
  end

  defp render_value(value, _level) when is_binary(value), do: String.trim(value) <> "\n\n"
  defp render_value(value, _level), do: String.trim(inspect(value)) <> "\n\n"

  defp heading(level, label), do: String.duplicate("#", level) <> " #{label}\n"

  defp fetch_binary(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> value
      _missing_or_invalid -> nil
    end
  end

  defp strip_language_marker(content) do
    case Regex.run(~r/^\S*\n/, content, return: :index) do
      [{0, length}] -> binary_part(content, length, byte_size(content) - length)
      _no_marker -> content
    end
  end

  defp strip_incomplete_fence(stripped) do
    cond do
      String.starts_with?(stripped, "```") ->
        Regex.replace(~r/^```\S*\n?/, stripped, "") |> String.trim()

      String.ends_with?(stripped, "```") ->
        stripped |> binary_part(0, byte_size(stripped) - 3) |> String.trim()

      true ->
        stripped
    end
  end
end
