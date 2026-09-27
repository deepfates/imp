defmodule Imp.Deadline do
  @moduledoc """
  Process-scoped absolute deadlines for cooperative time budgets.

  A deadline is either `:infinity` or an absolute monotonic time in
  milliseconds. `with_deadline/2` binds one to the calling process for the
  duration of a function; a nested `with_deadline/2` can shorten the bound but
  never extend it.

  The bound is cooperative: only code that reads it is limited by it.
  `Imp.Clients.ReqLLM` caps each request's `:receive_timeout` and
  `:total_timeout` (retries included) to the time left, and
  `Imp.Predict.ReActV2` makes no further model request once it has passed.
  Apart from Imp's own evaluation and optimizer machinery, nothing is limited
  by it: a running tool or retriever is not interrupted. To stop work at a time you choose, run it in a process you can
  cancel, such as a run from `Imp.start_run/3`.

  The binding belongs to the calling process. Work Imp starts in other
  processes carries it: every `Imp.Tasks` task, and so `Imp.parallel/3`,
  evaluation rows, optimizer fan-out and `Imp.Run`, runs under the deadline of
  the process that started it. `Imp.Run.start/3` also takes `deadline:`, and
  `Imp.Evaluate`'s `:deadline` option and GEPA's coordinator bind their own in
  the workers they start, and stop those workers when it passes. Each of these is resolved with `resolve/1`, so it can
  shorten the inherited deadline but never extend it. The deadline does not
  bound the wait for a place in Imp's task pool; `Imp.Run.start/3` returns
  `{:error, :deadline_exceeded}` instead of starting a run whose deadline
  passed while it waited. A process started with plain `spawn/1` or `Task`
  carries nothing; call `with_deadline/2` inside it with
  `{:deadline, current()}` captured in the parent.
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
