defmodule Imp.ModelResponseCostTest do
  # The money a host reads off a model call. Imp owns this boundary: `cost` is
  # what the provider reported charging and `estimated_cost` is ReqLLM's catalog
  # price, each a number or nil, never a provider library's private shape.
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
    # A ReqLLM response with the usage map a test gives it. ReqLLM's usage step
    # leaves its catalog estimate under atom keys (ReqLLM.Usage.Cost.merge/3)
    # and a provider's own fields, such as OpenRouter's "cost", under strings.
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

  test "a priced call reports the provider's charge as cost and the catalog price apart" do
    usage = %{
      "cost" => 0.0021,
      "cost_details" => %{"upstream_inference_cost" => 0.0021},
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

    assert response.metadata.cost == 0.0021
    assert is_float(response.metadata.cost)
    assert response.metadata.estimated_cost == 0.001858
    assert response.metadata.billing == @breakdown
    assert response.metadata.billing.line_items == @breakdown.line_items
  end

  test "a call ReqLLM priced but the provider did not report has no cost, only an estimate" do
    usage = %{input_tokens: 3, output_tokens: 2, total_tokens: 5, cost: @breakdown}

    {_events, response} = model_response(usage)

    assert response.metadata.cost == nil
    assert response.metadata.estimated_cost == 0.001858
    assert response.metadata.billing == @breakdown
  end

  test "a call nobody priced reports no cost, no estimate and no billing" do
    usage = %{input_tokens: 3, output_tokens: 2, total_tokens: 5}

    {_events, response} = model_response(usage)

    assert response.metadata.cost == nil
    assert response.metadata.estimated_cost == nil
    refute Map.has_key?(response.metadata, :billing)
    assert response.metadata.usage == usage
  end

  # The whole path a resident's call takes: an OpenRouter-shaped body over
  # HTTP, ReqLLM's decoding and its usage step pricing the tokens from the
  # model's catalog entry, then Imp. The entry prices 7000 input and 3000
  # output tokens at 0.0019; OpenRouter says it charged 0.0025.
  test "an OpenRouter response keeps OpenRouter's charge as cost and ReqLLM's price as the estimate" do
    base_url =
      Imp.Test.LocalHTTP.start(fn _request ->
        {200,
         %{
           "id" => "gen-cost",
           "object" => "chat.completion",
           "model" => "openai/gpt-4.1-nano",
           "choices" => [
             %{
               "index" => 0,
               "finish_reason" => "stop",
               "message" => %{"role" => "assistant", "content" => "pong"}
             }
           ],
           "usage" => %{
             "prompt_tokens" => 7000,
             "completion_tokens" => 3000,
             "total_tokens" => 10_000,
             "cost" => 0.0025,
             "is_byok" => false,
             "cost_details" => %{"upstream_inference_cost" => 0.0025}
           }
         }}
      end)

    lm =
      Imp.req_llm(
        %{
          provider: :openrouter,
          id: "openai/gpt-4.1-nano",
          model: "openai/gpt-4.1-nano",
          base_url: base_url <> "/v1",
          pricing: %{
            currency: "USD",
            components: [
              %{id: "token.input", kind: "token", unit: "token", per: 1_000_000, rate: 0.1},
              %{id: "token.output", kind: "token", unit: "token", per: 1_000_000, rate: 0.4}
            ]
          }
        },
        api_key: "local-test-key",
        cache: false
      )

    request = Imp.LM.new_request(lm, [%{role: :user, content: "ping"}], [], "cost test")
    assert {:ok, response} = Imp.Clients.ReqLLM.request(lm, request)

    assert response.cost == 0.0025
    assert_in_delta response.estimated_cost, 0.0019, 1.0e-12
    assert response.billing.total == response.estimated_cost
  end

  test "the ATIF export carries both numbers, not the breakdown map in their place" do
    usage = %{
      "cost" => 0.002,
      input_tokens: 3,
      output_tokens: 2,
      total_tokens: 5,
      cost: @breakdown
    }

    {events, _response} = model_response(usage)
    document = Imp.Trajectory.to_atif(events)

    observation =
      document["steps"]
      |> Enum.map(&get_in(&1, ["extra", "model_observation"]))
      |> Enum.find(&is_map/1)

    assert observation["cost"] == 0.002
    assert observation["estimated_cost"] == 0.001858
    assert observation["billing"]["total"] == 0.001858
  end

  test "a figure reported as a string or a Decimal reads as the same number" do
    for total <- ["0.001858", " 0.001858 ", Decimal.new("0.001858")] do
      raw = %{
        __imp_lm_output__: "pong",
        __imp_lm_metadata__: %{
          req_llm: %{usage: %{:cost => %{@breakdown | total: total}, "cost" => total}}
        }
      }

      assert {:ok, response} = Imp.Core.response(raw)
      assert response.cost == 0.001858
      assert response.estimated_cost == 0.001858
      assert response.billing.total == total
    end

    bare = %{
      __imp_lm_output__: "pong",
      __imp_lm_metadata__: %{req_llm: %{usage: %{cost: "0.5"}}}
    }

    assert {:ok, response} = Imp.Core.response(bare)
    assert response.cost == nil
    assert response.estimated_cost == 0.5
    assert response.billing == nil
  end

  test "a client other than ReqLLM reports its charge in its own metadata" do
    raw = %{__imp_lm_output__: "pong", __imp_lm_metadata__: %{cost: 0.25}}

    assert {:ok, response} = Imp.Core.response(raw)
    assert response.cost == 0.25
    assert response.estimated_cost == nil
  end

  test "a figure that cannot be read as a non-negative number is nothing, not a guess" do
    for reported <- ["free", %{total: "free"}, %{total: nil}, -0.5, %{total: -0.5}] do
      raw = %{
        __imp_lm_output__: "pong",
        __imp_lm_metadata__: %{req_llm: %{usage: %{:cost => reported, "cost" => reported}}}
      }

      assert {:ok, response} = Imp.Core.response(raw)
      assert response.cost == nil
      assert response.estimated_cost == nil
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

  # A call under an `Imp.Deadline` carries ReqLLM's `:total_timeout`, and ReqLLM
  # runs such a call in a task of its own, so its usage telemetry is emitted from
  # that task rather than from the process that made the call. The budget has to
  # count it anyway: a campaign whose calls run under a deadline (every GEPA
  # trial) otherwise spends without the ceiling seeing any of it.
  test "a budgeted call under a deadline records the usage the provider reports" do
    assert {:ok, budget} =
             Imp.start_optimizer_budget(
               limits: %{requests: 2, input_tokens: 10_000, output_tokens: 20, usd: 1.0},
               pricing: %{"input_per_million" => 1.0, "output_per_million" => 2.0},
               default_max_output_tokens: 20
             )

    base_url =
      Imp.Test.LocalHTTP.start(fn _request ->
        {200,
         %{
           "id" => "usage",
           "object" => "chat.completion",
           "model" => "usage-model",
           "choices" => [
             %{
               "index" => 0,
               "finish_reason" => "stop",
               "message" => %{"role" => "assistant", "content" => "pong"}
             }
           ],
           "usage" => %{"prompt_tokens" => 7, "completion_tokens" => 3, "total_tokens" => 10}
         }}
      end)

    inner =
      Imp.req_llm(
        %{
          provider: :openai,
          id: "usage-model",
          model: "usage-model",
          base_url: base_url <> "/v1"
        },
        api_key: "local-test-key",
        cache: false
      )

    lm = Imp.budgeted_lm(inner, budget, max_output_tokens: 20)

    assert {:ok, _response} =
             Imp.Deadline.with_deadline(5_000, fn ->
               Imp.LM.generate(lm, [%{role: :user, content: "ping"}], [])
             end)

    usage = Imp.Optimizer.Budget.snapshot(budget)["usage"]
    assert usage["input_tokens"] == 7
    assert usage["output_tokens"] == 3
  end
end
