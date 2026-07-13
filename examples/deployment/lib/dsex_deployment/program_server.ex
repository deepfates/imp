defmodule DSExDeployment.ProgramServer do
  use GenServer

  @default_timeout 30_000

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def call(inputs, timeout \\ @default_timeout), do: call(__MODULE__, inputs, timeout)

  def call(server, inputs, timeout)
      when timeout == :infinity or (is_integer(timeout) and timeout > 0) do
    runtime = GenServer.call(server, :runtime, timeout)
    run(runtime, inputs, timeout)
  catch
    :exit, reason -> {:error, {:unavailable, reason}}
  end

  def call(_server, _inputs, timeout) do
    raise ArgumentError,
          "timeout must be :infinity or a positive integer, got: #{inspect(timeout)}"
  end

  @impl true
  def init(opts) do
    program = Keyword.get_lazy(opts, :program, &load_program/0)

    {:ok,
     %{
       program: program,
       lm: Keyword.get_lazy(opts, :lm, &runtime_lm/0),
       executor: Keyword.get(opts, :executor, &execute/3),
       task_supervisor: Keyword.get(opts, :task_supervisor, DSExDeployment.TaskSupervisor)
     }}
  end

  @impl true
  def handle_call(:runtime, _from, state) do
    {:reply, state, state}
  end

  defp run(runtime, inputs, timeout) do
    task =
      Task.Supervisor.async_nolink(runtime.task_supervisor, fn ->
        runtime.executor.(runtime.program, runtime.lm, inputs)
      end)

    await(task, timeout)
  rescue
    RuntimeError -> {:error, :overloaded}
  end

  defp await(task, timeout) do
    case Task.yield(task, timeout) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, {:worker_crash, reason}}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  end

  defp load_program do
    path = System.fetch_env!("DSEX_ARTIFACT_PATH")
    DSEx.load!(path, registry: DSExDeployment.Callbacks.registry())
  end

  defp execute(program, lm, inputs) do
    DSEx.context([lm: lm], fn -> DSEx.call(program, inputs) end)
  end

  defp runtime_lm do
    case System.get_env("DSEX_STATIC_ANSWER") do
      nil ->
        DSEx.req_llm(System.fetch_env!("DSEX_MODEL"),
          api_key: System.fetch_env!("DSEX_API_KEY"),
          temperature: 0
        )

      answer ->
        %{module: DSEx.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: answer} end]}
    end
  end
end
