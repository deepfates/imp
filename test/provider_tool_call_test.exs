defmodule ProviderToolCallTest do
  use ExUnit.Case

  defmodule ToolCallTransport do
    @behaviour DSEx.HTTP

    @impl true
    def post(_url, _headers, body, _opts) do
      payload = Jason.decode!(body)
      send(self(), {:tool_call_payload, payload})

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
      DSEx.Clients.OpenAI.new("gpt-test",
        api_key: "sk-test",
        transport: ToolCallTransport,
        opts: [num_retries: 0]
      )

    lookup =
      DSEx.Tool.new(
        :lookup,
        "Lookup by query",
        fn
          %{query: "capital-france"} -> "Paris"
        end,
        schema: %{
          "type" => "object",
          "properties" => %{"query" => %{"type" => "string"}},
          "required" => ["query"]
        }
      )

    agent = DSEx.react_v2("question -> answer", [lookup], lm: lm, max_iters: 2)

    assert {:ok, prediction} =
             DSEx.Predict.ReActV2.call(agent, %{question: "What is the capital of France?"})

    assert DSEx.Prediction.get(prediction, :answer) == "Paris"

    assert [%{tool: :lookup, result: "Paris"}, %{tool: :submit, result: %{answer: "Paris"}}] =
             DSEx.Prediction.get(prediction, :history)

    assert_received {:tool_call_payload, payload}
    assert payload["tool_choice"] == "auto"

    assert [
             %{
               "type" => "function",
               "function" => %{"name" => "lookup", "parameters" => %{"required" => ["query"]}}
             },
             %{
               "type" => "function",
               "function" => %{
                 "name" => "submit",
                 "parameters" => %{"required" => ["answer"]}
               }
             }
           ] = Enum.sort_by(payload["tools"], &get_in(&1, ["function", "name"]))
  end
end
