defmodule Imp.ModelResponseCostTest do
  # The money a host reads off a model call. Imp owns this boundary: the cost
  # on a `:model_response` event is a number, never a provider library's
  # private breakdown shape.
  use ExUnit.Case, async: false

  @breakdown %{
    tokens: 0.001858,
    tools: 0.0,
    images: 0.0,
    storage: 0.0,
    total: 0.001858,
    input_cost: 0.0009,
    output_cost: 0.000958,
    reasoning_cost: 0.0,
    line_items: [
      %{id: "token.input", count: 3, cost: 0.0009, kind: :tokens},
      %{id: "token.output", count: 2, cost: 0.000958, kind: :tokens}
    ]
  }

  defmodule BilledStub do
    # A ReqLLM response whose usage carries a billing breakdown, the shape
    # ReqLLM.Usage.Cost.merge/3 leaves on a priced call.
    def generate_text(model, messages, opts) do
      usage = Keyword.fetch!(opts, :stub_usage)

      {:ok,
       %ReqLLM.Response{
         id: "billed-response",
         model: to_string(model),
         context: ReqLLM.Context.new(messages),
         message: ReqLLM.Context.assistant("pong"),
         usage: usage
       }}
    end
  end

  defmodule CallsLM do
    @behaviour Imp.Module
    defstruct [:lm, :usage, :signature]

    @impl true
    def call(%__MODULE__{lm: lm, usage: usage}, _inputs) do
      case Imp.LM.generate(lm, [%{role: :user, content: "ping"}],
             cache: false,
             stub_usage: usage
           ) do
        {:ok, _output} -> {:ok, Imp.Prediction.new(%{answer: "ok"})}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defmodule TelemetryLM do
    @behaviour Imp.LM
    defstruct [:measurements]

    @impl true
    def generate(_messages, _opts), do: {:error, :telemetry_lm_instance_required}

    def generate(%__MODULE__{measurements: measurements}, _messages, _opts) do
      :telemetry.execute([:req_llm, :token_usage], measurements, %{})
      {:ok, %{answer: "ok"}}
    end
  end

  defp run_events(usage) do
    lm = Imp.Clients.ReqLLM.new("openai:gpt-test", req_module: BilledStub)
    {:ok, run} = Imp.Run.start(%CallsLM{lm: lm, usage: usage}, %{question: "runtime?"})
    assert {:ok, _prediction} = Task.await(run.task)
    events = Imp.Run.events(run)
    Imp.Run.stop(run)
    events
  end

  defp model_response(usage) do
    events = run_events(usage)
    assert response = Enum.find(events, &(&1.kind == :model_response))
    {events, response}
  end

  test "a billed call reports the total as a number with the breakdown beside it" do
    usage = %{
      input_tokens: 3,
      output_tokens: 2,
      total_tokens: 5,
      cost: @breakdown,
      input_cost: 0.0009,
      output_cost: 0.000958,
      reasoning_cost: 0.0,
      total_cost: 0.001858
    }

    {_events, response} = model_response(usage)

    assert response.metadata.cost == 0.001858
    assert is_float(response.metadata.cost)
    assert response.metadata.billing == @breakdown
    assert response.metadata.billing.line_items == @breakdown.line_items
  end

  test "a call the provider did not price reports no cost and no billing" do
    usage = %{input_tokens: 3, output_tokens: 2, total_tokens: 5}

    {_events, response} = model_response(usage)

    assert response.metadata.cost == nil
    refute Map.has_key?(response.metadata, :billing)
    assert response.metadata.usage == usage
  end

  test "the ATIF export carries the number, not the breakdown map" do
    usage = %{input_tokens: 3, output_tokens: 2, total_tokens: 5, cost: @breakdown}

    {events, _response} = model_response(usage)
    document = Imp.Trajectory.to_atif(events)

    observation =
      document["steps"]
      |> Enum.map(&get_in(&1, ["extra", "model_observation"]))
      |> Enum.find(&is_map/1)

    assert observation["cost"] == 0.001858
    assert observation["billing"]["total"] == 0.001858
  end

  test "a total reported as a string or a Decimal reads as the same number" do
    for total <- ["0.001858", " 0.001858 ", Decimal.new("0.001858")] do
      raw = %{
        __imp_lm_output__: "pong",
        __imp_lm_metadata__: %{req_llm: %{usage: %{cost: %{@breakdown | total: total}}}}
      }

      assert {:ok, response} = Imp.Core.response(raw)
      assert response.cost == 0.001858
      assert response.billing.total == total
    end

    bare = %{
      __imp_lm_output__: "pong",
      __imp_lm_metadata__: %{req_llm: %{usage: %{cost: "0.5"}}}
    }

    assert {:ok, response} = Imp.Core.response(bare)
    assert response.cost == 0.5
    assert response.billing == nil
  end

  test "a cost that cannot be read as a non-negative number is nothing, not a guess" do
    for reported <- ["free", %{total: "free"}, %{total: nil}, -0.5, %{total: -0.5}] do
      raw = %{
        __imp_lm_output__: "pong",
        __imp_lm_metadata__: %{req_llm: %{usage: %{cost: reported}}}
      }

      assert {:ok, response} = Imp.Core.response(raw)
      assert response.cost == nil
    end
  end

  test "the budgeted LM still spends the number ReqLLM telemetry reports" do
    assert {:ok, budget} =
             Imp.start_optimizer_budget(
               limits: %{requests: 2, input_tokens: 10_000, output_tokens: 20, usd: 1.0},
               pricing: %{"input_per_million" => 1.0, "output_per_million" => 2.0},
               default_max_output_tokens: 20
             )

    lm =
      Imp.budgeted_lm(
        %TelemetryLM{
          measurements: %{
            tokens: %{input_tokens: 3, output_tokens: 2},
            cost: @breakdown,
            total_cost: 0.001858
          }
        },
        budget,
        max_output_tokens: 20
      )

    assert {:ok, %{answer: "ok"}} = Imp.LM.generate(lm, [%{content: "one"}], [])

    snapshot = Imp.Optimizer.Budget.snapshot(budget)
    assert snapshot["usage"] == %{"input_tokens" => 3, "output_tokens" => 2, "usd" => 0.001858}
  end
end
