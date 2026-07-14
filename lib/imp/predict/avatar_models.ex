defmodule Imp.Predict.Avatar.Action do
  @moduledoc "A typed Avatar tool selection."

  @enforce_keys [:tool_name, :tool_input_query]
  defstruct [:tool_name, :tool_input_query]

  @type t :: %__MODULE__{
          tool_name: atom() | String.t(),
          tool_input_query: term()
        }

  def new(%{} = value) do
    %__MODULE__{
      tool_name: fetch(value, :tool_name),
      tool_input_query: fetch(value, :tool_input_query)
    }
  end

  def new(value), do: raise(ArgumentError, "Avatar action must be a map, got: #{inspect(value)}")

  defp fetch(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end

defmodule Imp.Predict.Avatar.ActionOutput do
  @moduledoc "A typed Avatar action and its observed result."

  @enforce_keys [:tool_name, :tool_input_query, :tool_output]
  defstruct [:tool_name, :tool_input_query, :tool_output, error?: false]

  @type t :: %__MODULE__{
          tool_name: atom() | String.t(),
          tool_input_query: term(),
          tool_output: term(),
          error?: boolean()
        }
end
