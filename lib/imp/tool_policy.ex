defmodule Imp.ToolPolicy do
  @moduledoc """
  Internal. Validates and enforces the `:tool_policy` option accepted by
  ReAct-style programs: `:allow`, a tool name, a list of tool
  names, or an arity-2 function of tool name and args, where args are the
  string-keyed map the tool receives. `authorize/3` returns `:ok`,
  `{:tool_denied, name, :tool_policy}` for a tool the policy does not allow
  (the same tag a run's `:authorize` callback denies with), or
  `{:tool_policy_error, name, reason}` for a policy function that raised (the
  exception) or threw or exited (`{kind, value}`), so a crashing policy does
  not take down the tool loop.
  """

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

  def authorize(:allow, _name, _args), do: :ok

  def authorize(policy, name, args) when is_function(policy, 2) do
    try do
      case policy.(name, args) do
        true -> :ok
        :ok -> :ok
        false -> {:error, denied(name)}
        {:error, reason} -> {:error, reason}
        _other -> {:error, denied(name)}
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
      else: {:error, denied(name)}
  end

  def authorize(policy, name, _args) when is_atom(policy) or is_binary(policy) do
    if same_tool_name?(policy, name), do: :ok, else: {:error, denied(name)}
  end

  def authorize(_policy, name, _args), do: {:error, denied(name)}

  defp denied(name), do: {:tool_denied, name, :tool_policy}

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
