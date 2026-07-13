defmodule DSExDeployment.ProgramServer do
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def call(inputs, timeout \\ 30_000), do: GenServer.call(__MODULE__, {:call, inputs}, timeout)

  @impl true
  def init(_opts) do
    path = System.fetch_env!("DSEX_ARTIFACT_PATH")
    program = DSEx.load!(path, registry: DSExDeployment.Callbacks.registry())
    {:ok, %{program: program, lm: runtime_lm()}}
  end

  @impl true
  def handle_call({:call, inputs}, _from, state) do
    result = DSEx.context([lm: state.lm], fn -> DSEx.call(state.program, inputs) end)
    {:reply, result, state}
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
