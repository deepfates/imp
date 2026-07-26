defmodule ImpDeployment.ProgramServer do
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

  @doc "Atomically loads a verified program artifact for subsequent calls."
  def reload(path) when is_binary(path), do: reload(__MODULE__, path)

  def reload(server, path) when is_binary(path) do
    GenServer.call(server, {:reload, path})
  catch
    :exit, reason -> {:error, {:unavailable, reason}}
  end

  @doc "Applies a verified selected-parameter artifact to the trusted running program."
  def reload_parameters(path) when is_binary(path), do: reload_parameters(__MODULE__, path)

  def reload_parameters(server, path) when is_binary(path) do
    GenServer.call(server, {:reload_parameters, path})
  catch
    :exit, reason -> {:error, {:unavailable, reason}}
  end

  @impl true
  def init(opts) do
    program = Keyword.get_lazy(opts, :program, &load_program/0)

    {:ok,
     %{
       program: program,
       lm: Keyword.get_lazy(opts, :lm, &runtime_lm/0),
       executor: Keyword.get(opts, :executor, &execute/3),
       task_supervisor: Keyword.get(opts, :task_supervisor, ImpDeployment.TaskSupervisor)
     }}
  end

  @impl true
  def handle_call(:runtime, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:reload, path}, _from, state) do
    case read_program(path, state.program) do
      {:ok, program} -> {:reply, :ok, %{state | program: program}}
      {:error, reason} -> {:reply, {:error, {:invalid_artifact, reason}}, state}
    end
  end

  def handle_call({:reload_parameters, path}, _from, state) do
    case read_parameters(path, state.program) do
      {:ok, program} -> {:reply, :ok, %{state | program: program}}
      {:error, reason} -> {:reply, {:error, {:invalid_artifact, reason}}, state}
    end
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
    if System.get_env("IMP_WORKFLOW_BASELINE") == "1" do
      ImpDeployment.Workflow.program()
    else
      path = System.fetch_env!("IMP_ARTIFACT_PATH")
      Imp.load!(path, registry: ImpDeployment.Callbacks.registry())
    end
  end

  defp read_parameters(path, current) do
    artifact = Imp.Optimizer.Artifact.read!(path)
    program = Imp.Optimizer.Artifact.apply(artifact, current)

    if compatible_contract?(current, program),
      do: {:ok, program},
      else: {:error, "selected parameters do not match the running typed program"}
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, Exception.format_banner(kind, reason)}
  end

  defp read_program(path, current) do
    program = Imp.load!(path, registry: ImpDeployment.Callbacks.registry())

    if compatible_contract?(current, program) do
      {:ok, program}
    else
      {:error, "program type or typed predictor contract does not match the running program"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, Exception.format_banner(kind, reason)}
  end

  defp compatible_contract?(%current_type{} = current, %loaded_type{} = loaded)
       when current_type == loaded_type do
    contract_shape(current) == contract_shape(loaded)
  end

  defp compatible_contract?(_current, _loaded), do: false

  defp contract_shape(program) do
    program
    |> Imp.ProgramParameters.predictors()
    |> Enum.map(fn %{name: name, predictor: predictor} ->
      signature = Imp.Signature.dump(predictor.signature)

      fields = fn kind ->
        signature
        |> Map.fetch!(kind)
        |> Enum.map(&Map.take(&1, ["name", "kind", "type", "metadata"]))
        |> Jason.encode!()
        |> Jason.decode!()
      end

      {to_string(name), %{inputs: fields.("inputs"), outputs: fields.("outputs")}}
    end)
    |> Enum.sort()
  end

  defp execute(program, lm, inputs) do
    Imp.context([lm: lm], fn -> Imp.call(program, inputs) end)
  end

  defp runtime_lm do
    cond do
      System.get_env("IMP_STATIC_WORKFLOW") == "1" ->
        ImpDeployment.Workflow.static_lm()

      answer = System.get_env("IMP_STATIC_ANSWER") ->
        Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: answer} end)

      true ->
        Imp.req_llm(System.fetch_env!("IMP_MODEL"),
          api_key: System.fetch_env!("IMP_API_KEY"),
          temperature: 0
        )
    end
  end
end
