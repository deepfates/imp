defmodule ProviderToolCallTest do
  use ExUnit.Case

  defmodule ToolCallTransport do
    @behaviour Dachshund.HTTP

    @impl true
    def post(_url, _headers, _body, _opts) do
      response = %{
        choices: [
          %{
            message: %{
              content: nil,
              tool_calls: [
                %{
                  id: "call_1",
                  type: "function",
                  function: %{
                    name: "lookup",
                    arguments: Jason.encode!(%{query: "capital-france"})
                  }
                },
                %{
                  id: "call_2",
                  type: "function",
                  function: %{
                    name: "submit",
                    arguments: Jason.encode!(%{answer: "Paris"})
                  }
                }
              ]
            }
          }
        ]
      }

      {:ok, %{status: 200, headers: [], body: Jason.encode!(response)}}
    end
  end

  test "HTTP LM normalizes OpenAI tool_calls for ReActV2 execution" do
    lm =
      Dachshund.Clients.OpenAI.new("gpt-test",
        api_key: "sk-test",
        transport: ToolCallTransport,
        opts: [num_retries: 0]
      )

    lookup =
      Dachshund.Tool.new(:lookup, "Lookup by query", fn
        %{query: "capital-france"} -> "Paris"
      end)

    agent = Dachshund.react_v2("question -> answer", [lookup], lm: lm, max_iters: 2)

    assert {:ok, prediction} =
             Dachshund.Predict.ReActV2.call(agent, %{question: "What is the capital of France?"})

    assert Dachshund.Prediction.get(prediction, :answer) == "Paris"

    assert [%{tool: :lookup, result: "Paris"}, %{tool: :submit, result: %{answer: "Paris"}}] =
             Dachshund.Prediction.get(prediction, :history)
  end
end
