defmodule Imp.NormalizedLMRuntimeTest do
  use ExUnit.Case, async: true

  defmodule RequestAwareLM do
    @behaviour Imp.LM
    defstruct [:test_pid]

    @impl true
    def request(%__MODULE__{test_pid: test_pid}, %Imp.Core.LMRequest{} = request) do
      send(test_pid, {:normalized_request, request})
      output = %{answer: "typed"}
      {:ok, %Imp.Core.LMResponse{outputs: [output], raw: output}}
    end

    @impl true
    def generate(_lm, _messages, _opts), do: raise("normalized request callback was bypassed")
  end

  defmodule ReqStub do
    def generate_text(model, messages, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:req_transport, model, messages, opts})

      {:ok,
       %ReqLLM.Response{
         id: "normalized-response",
         model: to_string(model),
         context: ReqLLM.Context.new(messages),
         message: ReqLLM.Context.assistant("pong"),
         usage: %{input_tokens: 3, output_tokens: 2, total_tokens: 5}
       }}
    end
  end

  test "ordinary Predict calls cross the typed request callback" do
    lm = %RequestAwareLM{test_pid: self()}
    program = Imp.predict("question -> answer", lm: lm, config: [temperature: 0.2])

    assert {:ok, prediction} = Imp.call(program, %{question: "hello"})
    assert Imp.get(prediction, :answer) == "typed"

    assert_receive {:normalized_request,
                    %Imp.Core.LMRequest{
                      messages: [%Imp.Core.System{}, %Imp.Core.User{}],
                      config: %Imp.Core.LMConfig{temperature: 0.2, options: options}
                    }}

    assert options[:temperature] == 0.2
  end

  test "ReqLLM consumes a typed request and returns normalized usage metadata" do
    lm = Imp.Clients.ReqLLM.new("openai:gpt-test", req_module: ReqStub)

    request = %Imp.Core.LMRequest{
      messages: [
        %Imp.Core.System{content: "Be concise"},
        %Imp.Core.User{content: "ping", metadata: %{name: "caller"}}
      ],
      config: %Imp.Core.LMConfig{
        model: "openai:gpt-test",
        temperature: 0,
        options: [temperature: 0, test_pid: self(), cache: false]
      }
    }

    {normalized_messages, normalized_opts} = Imp.Core.request_parts(request)
    assert Enum.at(normalized_messages, 1).name == "caller"
    assert normalized_opts[:temperature] == 0

    {{:ok, response}, usage} = Imp.Usage.track(fn -> Imp.LM.request(lm, request) end)
    assert response.outputs == ["pong"]
    assert response.usage == %{input_tokens: 3, output_tokens: 2, total_tokens: 5}
    assert response.raw.__imp_lm_output__ == "pong"
    assert usage == %{"openai/openai:gpt-test" => response.usage}

    assert_receive {:req_transport, "openai:gpt-test", messages, opts}
    assert Enum.map(messages, & &1.role) == [:system, :user]
    assert opts[:temperature] == 0
  end

  test "typed requests reject values outside the public request contract" do
    assert {:error, {:invalid_lm_request, :not_a_request}} =
             Imp.LM.request(%RequestAwareLM{test_pid: self()}, :not_a_request)

    assert_raise ArgumentError, ~r/LM request messages/, fn ->
      Imp.Core.request([:not_a_message], [], %RequestAwareLM{test_pid: self()})
    end
  end

  test "multi-completion response metadata remains completion-local" do
    first = %{
      __imp_lm_output__: %{answer: "a"},
      __imp_lm_metadata__: %{req_llm: %{usage: %{total_tokens: 2}}}
    }

    second = %{
      __imp_lm_output__: %{answer: "b"},
      __imp_lm_metadata__: %{req_llm: %{usage: %{total_tokens: 3}}}
    }

    assert {:ok, response} = Imp.Core.response([first, second])
    assert response.outputs == [%{answer: "a"}, %{answer: "b"}]

    assert response.metadata.completions
           |> Enum.map(&get_in(&1, [:req_llm, :usage, :total_tokens])) == [2, 3]

    assert Imp.Core.legacy_response(response) == [first, second]
  end

  test "typed multipart values remain inert until the provider conversion edge" do
    image = %Imp.Adapter.Types.Image{data: Base.encode64("PNG"), mime_type: "image/png"}
    call = Imp.Adapter.Types.ToolCall.new("lookup", %{query: "beam"}, id: "call_1")

    request =
      Imp.Core.request(
        [%{role: :user, content: ["inspect ", image, call]}],
        [tools: [%{name: "lookup"}]],
        %RequestAwareLM{test_pid: self()}
      )

    assert %Imp.Core.LMRequest{
             messages: [%Imp.Core.User{content: ["inspect ", ^image, ^call]}],
             config: %Imp.Core.LMConfig{tools: [%{name: "lookup"}]}
           } = request

    assert {[%{role: :user, content: ["inspect ", ^image, ^call]}], options} =
             Imp.Core.request_parts(request)

    assert options[:tools] == [%{name: "lookup"}]
    assert Imp.Adapter.Types.to_openai(image).type == "image_url"
    assert Imp.Adapter.Types.to_openai(call).type == "function"
  end
end
