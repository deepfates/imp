defmodule Imp.Deadline do
  @moduledoc """
  Process-scoped absolute deadlines for cooperative time budgets.

  A deadline is either `:infinity` or an absolute monotonic time in
  milliseconds. `with_deadline/2` binds one to the calling process for the
  duration of a function; a nested `with_deadline/2` can shorten the bound but
  never extend it.

  The bound is cooperative: only code that reads it is limited by it.
  `Imp.Clients.ReqLLM` caps each request's `:receive_timeout` and
  `:total_timeout` (retries included) to the time left, and `Imp.Predict.ReActV2` makes no further model request once it has
  passed. `Imp.Evaluate`'s `:deadline` option and GEPA's coordinator bind a
  deadline in the workers they start. Nothing else reads it: a running tool,
  retriever or metric is not interrupted. To stop work at a time you choose,
  run it in a process you can cancel, such as a run from `Imp.start_run/3`.

  The binding belongs to the calling process and is not inherited by a
  process it spawns, so a host that runs a program in another process, such
  as `Imp.Run`'s task, binds it again inside that process.
  """

  @key {__MODULE__, :deadline}

  @type t :: :infinity | integer()

  @doc "Returns the deadline bound to the current process, or `:infinity`."
  @spec current() :: t()
  def current, do: Process.get(@key, :infinity)

  @doc "Milliseconds until `deadline` expires (`:infinity` never does), floored at 0."
  @spec remaining(t()) :: :infinity | non_neg_integer()
  def remaining(:infinity), do: :infinity

  def remaining(absolute) when is_integer(absolute),
    do: max(absolute - System.monotonic_time(:millisecond), 0)

  @doc "Whether `deadline` has expired."
  @spec expired?(t()) :: boolean()
  def expired?(:infinity), do: false
  def expired?(deadline), do: remaining(deadline) == 0

  @doc """
  Resolves a timeout to an absolute deadline, capped by the current process
  deadline. Accepts `:infinity`, a relative timeout in milliseconds, or an
  already-absolute `{:deadline, absolute}`.
  """
  @spec resolve(:infinity | non_neg_integer() | {:deadline, integer()}) :: t()
  def resolve(timeout) do
    requested =
      case timeout do
        :infinity -> :infinity
        {:deadline, absolute} -> absolute
        milliseconds -> System.monotonic_time(:millisecond) + milliseconds
      end

    min_deadline(current(), requested)
  end

  @doc """
  Runs `fun` with the resolved deadline bound to the current process,
  restoring the previous binding afterwards.
  """
  @spec with_deadline(:infinity | non_neg_integer() | {:deadline, integer()}, (-> result)) ::
          result
        when result: var
  def with_deadline(timeout, fun) when is_function(fun, 0) do
    deadline = resolve(timeout)
    previous = Process.get(@key, :__imp_missing_deadline__)
    Process.put(@key, deadline)

    try do
      fun.()
    after
      case previous do
        :__imp_missing_deadline__ -> Process.delete(@key)
        value -> Process.put(@key, value)
      end
    end
  end

  @doc false
  # Binds an already-resolved deadline in a freshly spawned worker process.
  def bind(deadline), do: Process.put(@key, deadline)

  defp min_deadline(:infinity, deadline), do: deadline
  defp min_deadline(deadline, :infinity), do: deadline
  defp min_deadline(left, right), do: min(left, right)
end
