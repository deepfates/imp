defmodule Imp.ToolPolicy do
  @moduledoc """
  The `:tool_policy` option of the tool-using programs (`Imp.Predict.ReActV2`,
  `Imp.Predict.ReAct`, `Imp.Predict.RLM`, `Imp.Predict.CodeAct`,
  `Imp.Predict.Avatar`): which of their tools the model may call.

  A policy is one of:

    * `:allow` — every tool (the default).
    * a tool name, or a list of tool names — only those tools. Names compare as
      strings, so `:lookup` and `"lookup"` are the same tool.
    * a function of the tool name and the call's arguments that returns
      `:allow` or `{:deny, reason}`, the vocabulary `Imp.Run`'s `:authorize`
      and `Imp.ACP`'s `:permission_policy` use too.

  A tool call the policy refuses is not made. The program records
  `{:error, {:tool_denied, name, reason}}` as that call's result, where
  `reason` names what denied it: `:tool_policy` for a name or list policy, or
  the reason a policy function gave. The same tag carries a run's
  `:authorize` refusal, with that callback's reason. The model reads that the
  tool was not allowed. A policy function
  that returns anything else refuses the call with the reason
  `{:invalid_decision, value}`, and one that raises or exits refuses it with
  `{:tool_policy_error, name, reason}`, so a broken policy never runs a tool.
  """

  @typedoc "A tool policy; see the moduledoc."
  @type t ::
          :allow
          | atom()
          | String.t()
          | [atom() | String.t()]
          | (atom() | String.t(), map() -> :allow | {:deny, term()})

  @doc false
  def validate(:allow), do: {:ok, :allow}
  def validate(policy) when is_function(policy, 2), do: {:ok, policy}
  def validate(policy) when is_atom(policy) or is_binary(policy), do: validate_key_policy(policy)

  def validate(policy) when is_list(policy) do
    if Enum.all?(policy, &valid_key?/1) do
      {:ok, policy}
    else
      {:error,
       "expected :allow, an atom/string tool name, a list of tool names, or an arity-2 function"}
    end
  end

  def validate(_policy) do
    {:error,
     "expected :allow, an atom/string tool name, a list of tool names, or an arity-2 function"}
  end

  @doc """
  Returns `:ok` when `policy` allows calling the tool `name` with `args`, or
  `{:error, {:tool_denied, name, reason}}` or
  `{:error, {:tool_policy_error, name, reason}}` when it does not.
  """
  @spec authorize(t(), atom() | String.t(), map()) :: :ok | {:error, term()}
  def authorize(:allow, _name, _args), do: :ok

  def authorize(policy, name, args) when is_function(policy, 2) do
    try do
      case policy.(name, args) do
        :allow -> :ok
        {:deny, reason} -> {:error, {:tool_denied, name, reason}}
        other -> {:error, {:tool_denied, name, {:invalid_decision, other}}}
      end
    rescue
      safety in Imp.OperationalSafetyError -> {:error, safety}
      exception -> {:error, {:tool_policy_error, name, exception}}
    catch
      kind, reason ->
        case Imp.OperationalSafetyError.find({kind, reason}) do
          %Imp.OperationalSafetyError{} = safety -> {:error, safety}
          nil -> {:error, {:tool_policy_error, name, {kind, reason}}}
        end
    end
  end

  def authorize(policy, name, _args) when is_list(policy) do
    if Enum.any?(policy, &same_tool_name?(&1, name)),
      do: :ok,
      else: {:error, {:tool_denied, name, :tool_policy}}
  end

  def authorize(policy, name, _args) when is_atom(policy) or is_binary(policy) do
    if same_tool_name?(policy, name),
      do: :ok,
      else: {:error, {:tool_denied, name, :tool_policy}}
  end

  def authorize(_policy, name, _args), do: {:error, {:tool_denied, name, :tool_policy}}

  defp validate_key_policy(key) do
    if valid_key?(key) do
      {:ok, key}
    else
      {:error,
       "expected :allow, an atom/string tool name, a list of tool names, or an arity-2 function"}
    end
  end

  defp valid_key?(key) when is_atom(key), do: true
  defp valid_key?(key) when is_binary(key), do: String.trim(key) != ""
  defp valid_key?(_key), do: false

  defp same_tool_name?(left, right), do: to_string(left) == to_string(right)
end
