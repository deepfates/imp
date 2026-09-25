defmodule Imp.TelemetryLineageContractTest do
  use ExUnit.Case, async: false

  defmodule ToolProgram do
    defstruct [:tool]

    def call(%__MODULE__{tool: tool}, %{value: value}) do
      with {:ok, doubled} <- Imp.Tool.call(tool, %{value: value}) do
        {:ok, Imp.Prediction.new(result: doubled)}
      end
    end
  end

  defmodule ProviderFixture do
    def generate_text(model, messages, _opts) do
      {:ok,
       %ReqLLM.Response{
         id: "lineage-fixture",
         model: to_string(model),
         context: ReqLLM.Context.new(messages),
         message: ReqLLM.Context.assistant(~s({"answer":"4"})),
         object: %{"answer" => "4"},
         finish_reason: :stop
       }}
    end
  end

  setup do
    Imp.Settings.reset()
    handler_id = "telemetry-lineage-#{System.unique_integer([:positive])}"
    owner = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:imp, :module, :start],
          [:imp, :module, :stop],
          [:imp, :evaluate, :start],
          [:imp, :evaluate, :stop],
          [:imp, :lm, :start],
          [:imp, :lm, :stop],
          [:imp, :tool, :start],
          [:imp, :tool, :stop],
          [:imp, :lineage, :child]
        ],
        fn event, measurements, metadata, _config ->
          send(owner, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      Imp.Settings.reset()
    end)

    :ok
  end

  test "LM spans are distinct children of the program call" do
    lm = Imp.req_llm("openai:gpt-fixture", req_module: ProviderFixture, cache: false)
    program = Imp.Predict.Predict.new("question -> answer", lm: lm)

    assert {:ok, prediction} = Imp.call(program, %{question: "2+2?"})
    assert Imp.get(prediction, :answer) == "4"

    module_start = event!([:imp, :module, :start])
    lm_start = event!([:imp, :lm, :start])
    lm_stop = event!([:imp, :lm, :stop])
    module_stop = event!([:imp, :module, :stop])

    assert lm_start.call_id != module_start.call_id
    assert lm_start.parent_call_id == module_start.call_id
    assert lm_stop.call_id == lm_start.call_id
    assert module_stop.call_id == module_start.call_id
  end

  test "evaluation is the causal parent of each evaluated program call" do
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "4"} end)
    program = Imp.Predict.Predict.new("question -> answer", lm: lm)

    example =
      Imp.Example.new(question: "2+2?", answer: "4") |> Imp.Example.with_inputs([:question])

    assert %Imp.Evaluate.Result{score: 1.0} =
             Imp.evaluate(program, [example], Imp.exact_match(:answer))

    evaluate_start = event!([:imp, :evaluate, :start])
    module_start = event!([:imp, :module, :start])
    module_stop = event!([:imp, :module, :stop])
    evaluate_stop = event!([:imp, :evaluate, :stop])

    assert module_start.parent_call_id == evaluate_start.call_id
    assert module_stop.call_id == module_start.call_id
    assert evaluate_stop.call_id == evaluate_start.call_id
  end

  test "nested module and tool spans carry matching call and parent IDs" do
    tool =
      Imp.Tool.new(:double, "Double an integer", fn %{value: value} -> {:ok, value * 2} end,
        schema: %{
          "type" => "object",
          "required" => ["value"],
          "properties" => %{"value" => %{"type" => "integer"}}
        }
      )

    assert {:ok, prediction} = Imp.call(%ToolProgram{tool: tool}, %{value: 3})
    assert Imp.get(prediction, :result) == 6

    module_start = event!([:imp, :module, :start])
    tool_start = event!([:imp, :tool, :start])
    tool_stop = event!([:imp, :tool, :stop])
    module_stop = event!([:imp, :module, :stop])

    assert byte_size(module_start.call_id) == 32
    assert module_start.parent_call_id == nil
    assert tool_start.parent_call_id == module_start.call_id
    assert tool_stop.call_id == tool_start.call_id
    assert tool_stop.parent_call_id == module_start.call_id
    assert module_stop.call_id == module_start.call_id
  end

  test "Imp task children inherit the active span lineage" do
    parent_call_id =
      Imp.Telemetry.span([:imp, :test_parent], %{}, fn ->
        [%{call_id: parent_call_id} | _] = Imp.Telemetry.context()

        task =
          Imp.Tasks.async(fn ->
            Imp.Telemetry.execute([:imp, :lineage, :child], %{count: 1}, %{})
          end)

        assert :ok = Task.await(task)
        parent_call_id
      end)

    child = event!([:imp, :lineage, :child])
    assert child.call_id == parent_call_id
  end

  test "failed spans restore context instead of leaking lineage into later work" do
    assert_raise RuntimeError, "boom", fn ->
      Imp.Telemetry.span([:imp, :test_failure], %{}, fn -> raise "boom" end)
    end

    assert Imp.Telemetry.context() == []
    assert :ok = Imp.Telemetry.execute([:imp, :lineage, :child], %{count: 1}, %{})
    refute Map.has_key?(event!([:imp, :lineage, :child]), :call_id)
  end

  test "the old callbacks setting fails loudly instead of pretending to observe work" do
    assert_raise ArgumentError, ~r/:callbacks is not a setting.*:telemetry\.attach\/4/s, fn ->
      Imp.configure(callbacks: [fn -> send(self(), :should_not_run) end])
    end

    assert_raise ArgumentError, ~r/:callbacks is not a setting/, fn ->
      Imp.configure(%{"callbacks" => []})
    end

    refute_received :should_not_run
  end

  defp event!(wanted) do
    receive do
      {:telemetry_event, ^wanted, _measurements, metadata} -> metadata
      {:telemetry_event, _other, _measurements, _metadata} -> event!(wanted)
    after
      500 -> flunk("missing telemetry event #{inspect(wanted)}")
    end
  end
end
