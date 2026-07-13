defmodule DSEx.Optimize.Anything.StdioCapture do
  @moduledoc false

  @type outcome(result) ::
          {:ok, result}
          | {:raised, :error | :exit | :throw, term(), Exception.stacktrace()}

  @doc false
  @spec capture((-> result)) :: {outcome(result), String.t()} when result: var
  def capture(fun) when is_function(fun, 0) do
    original_group_leader = Process.group_leader()
    {:ok, string_io} = StringIO.open("")

    try do
      outcome =
        try do
          Process.group_leader(self(), string_io)
          invoke(fun)
        after
          Process.group_leader(self(), original_group_leader)
        end

      {_input, output} = StringIO.contents(string_io)
      {outcome, output}
    after
      close(string_io)
    end
  end

  defp invoke(fun) do
    {:ok, fun.()}
  rescue
    exception -> {:raised, :error, exception, __STACKTRACE__}
  catch
    kind, reason -> {:raised, kind, reason, __STACKTRACE__}
  end

  defp close(string_io) do
    if Process.alive?(string_io), do: StringIO.close(string_io)
    :ok
  catch
    :exit, _reason -> :ok
  end
end
