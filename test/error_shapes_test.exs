defmodule Imp.ErrorShapesTest do
  # One shape per failure, with the reason as a term. Each test here fails on
  # the shape it replaced.
  use ExUnit.Case, async: false

  defmodule StatusReqLLM do
    def generate_text(_model, _messages, opts) do
      {:error,
       %ReqLLM.Error.API.Request{
         status: Keyword.fetch!(opts, :status),
         reason: "provider said no",
         response_body: Keyword.get(opts, :body)
       }}
    end
  end

  defmodule TransportReqLLM do
    def generate_text(_model, _messages, _opts),
      do: {:error, %Req.TransportError{reason: :timeout}}
  end

  defmodule RaisingReqLLM do
    def generate_text(_model, _messages, _opts), do: raise("transport exploded")
  end

  defmodule RaisingProgram do
    defstruct []
    def call(_program, _inputs), do: raise(ArgumentError, "boom")
  end

  defmodule FailingProgram do
    defstruct []
    def call(_program, _inputs), do: {:error, :nope}
  end

  defmodule FailingOptimizer do
    @behaviour Imp.Optimizer
    defstruct []

    @impl true
    def __optimizer__,
      do: %{
        kind: :program,
        datasets: %{trainset: :required, validation: :unsupported},
        result: :program
      }

    @impl true
    def run(_optimizer, _program, _opts), do: {:error, :no_improvement}
  end

  defp request(lm), do: Imp.LM.generate(lm, [%{role: :user, content: "hi"}], [])

  describe "LM errors" do
    test "a provider status is one Imp.LMError the caller can classify" do
      lm = Imp.req_llm("openai:gpt-test", req_module: StatusReqLLM, status: 429)

      assert {:error, %Imp.LMError{status: 429, retryable: true} = error} = request(lm)
      assert %ReqLLM.Error.API.Request{status: 429} = error.reason
      assert Imp.Errors.retryable?({:error, error})
      refute Imp.Errors.context_window_exceeded?(error)

      lm = Imp.req_llm("openai:gpt-test", req_module: StatusReqLLM, status: 401)
      assert {:error, %Imp.LMError{status: 401, retryable: false}} = request(lm)
    end

    test "the structured context-length refusal is marked, and nothing else is" do
      body = %{"error" => %{"code" => "context_length_exceeded"}}
      lm = Imp.req_llm("openai:gpt-test", req_module: StatusReqLLM, status: 400, body: body)

      assert {:error, %Imp.LMError{status: 400, context_window_exceeded: true} = error} =
               request(lm)

      assert Imp.Errors.context_window_exceeded?(error)
      refute Imp.Errors.retryable?(error)

      lm = Imp.req_llm("openai:gpt-test", req_module: StatusReqLLM, status: 400)
      assert {:error, %Imp.LMError{context_window_exceeded: false}} = request(lm)
    end

    test "a transport timeout and a raising provider library are LM errors too" do
      lm = Imp.req_llm("openai:gpt-test", req_module: TransportReqLLM)

      assert {:error, %Imp.LMError{status: nil, retryable: true, reason: %Req.TransportError{}}} =
               request(lm)

      lm = Imp.req_llm("openai:gpt-test", req_module: RaisingReqLLM)

      assert {:error, %Imp.LMError{retryable: false, reason: %RuntimeError{}} = error} =
               request(lm)

      assert error.message == "transport exploded"
    end

    test "a client that raises keeps its exception under :lm_failed" do
      lm = Imp.LM.Static.new(handler: fn _messages, _opts -> raise ArgumentError, "bad" end)

      assert {:error, {:lm_failed, Imp.LM.Static, %ArgumentError{message: "bad"}}} = request(lm)

      lm = Imp.LM.Static.new(handler: fn _messages, _opts -> throw(:nope) end)
      assert {:error, {:lm_failed, Imp.LM.Static, {:throw, :nope}}} = request(lm)
    end
  end

  describe "parse errors" do
    test "a completion missing an output is an AdapterParseError with its trace" do
      lm = Imp.LM.Static.new(handler: fn _messages, _opts -> "no field markers here" end)
      program = Imp.predict("question -> answer", lm: lm)

      assert {:error,
              %Imp.AdapterParseError{
                kind: :missing_fields,
                reason: [:answer],
                trace: %{raw: "no field markers here", format_progress: progress}
              }} = Imp.call(program, %{question: "q"})

      assert progress == %{expected: [:answer], present: []}
    end

    test "a completion of the wrong type is :invalid_fields" do
      lm = Imp.LM.Static.new(handler: fn _messages, _opts -> ~s({"count": "many"}) end)
      program = Imp.predict("question -> count: int", lm: lm, adapter: Imp.Adapter.JSON)

      assert {:error, %Imp.AdapterParseError{kind: :invalid_fields, reason: %{count: "many"}}} =
               Imp.call(program, %{question: "q"})
    end

    test "an LM failure on the JSON fallback is the LM's error, not a parse error" do
      counter = :counters.new(1, [])

      lm =
        Imp.LM.Static.new(
          handler: fn _messages, _opts ->
            :counters.add(counter, 1, 1)

            if :counters.get(counter, 1) == 1,
              do: "no field markers",
              else: raise(RuntimeError, "provider down")
          end
        )

      program = Imp.predict("question -> answer", lm: lm)

      assert {:error, {:lm_failed, Imp.LM.Static, %RuntimeError{message: "provider down"}}} =
               Imp.call(program, %{question: "q"})
    end

    test "a ReActV2 step that cannot be parsed ends with cause :parse_error" do
      counter = :counters.new(1, [])

      lm =
        Imp.LM.Static.new(
          handler: fn _messages, _opts ->
            :counters.add(counter, 1, 1)

            # The step and its JSON fallback both come back with tool_calls
            # that no adapter reads as calls; the last request answers.
            if :counters.get(counter, 1) <= 2,
              do: %{next_thought: "thinking", tool_calls: 42},
              else: "Answered."
          end
        )

      look = Imp.tool(:look, "Look", fn _ -> "seen" end)
      program = Imp.react_v2("intent -> answer", [look], lm: lm)

      assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
      assert Imp.get(prediction, :termination_cause) == :parse_error
    end
  end

  describe "tool and program failures" do
    test "a program that raises keeps its exception under :module_call_failed" do
      assert {:error, {:module_call_failed, RaisingProgram, %ArgumentError{message: "boom"}}} =
               Imp.call(%RaisingProgram{}, %{})
    end

    test "a tool the policy does not allow is denied with the run's tag" do
      assert {:error, {:tool_authorization_denied, :write, :tool_policy}} =
               Imp.ToolPolicy.authorize([:read], :write, %{})

      assert Imp.Adapter.Chat.tool_error_text({:tool_authorization_denied, :write, :tool_policy}) ==
               "write is not allowed."
    end

    test "a policy that raises keeps its exception" do
      policy = fn _name, _args -> raise "policy broke" end

      assert {:error, {:tool_policy_error, :write, %RuntimeError{message: "policy broke"}}} =
               Imp.ToolPolicy.authorize(policy, :write, %{})
    end

    test "a tool that raises keeps its exception" do
      broken = Imp.tool(:broken, "Broken", fn _ -> raise "tool broke" end)
      counter = :counters.new(1, [])

      lm =
        Imp.LM.Static.new(
          handler: fn _messages, _opts ->
            :counters.add(counter, 1, 1)

            if :counters.get(counter, 1) == 1,
              do: %{tool_calls: [%{name: "broken", arguments: %{}}]},
              else: "Done."
          end
        )

      program = Imp.react_v2("intent -> answer", [broken], lm: lm)
      assert {:ok, prediction} = Imp.call(program, %{intent: "go"})

      results =
        Enum.flat_map(Imp.get(prediction, :history).messages, &(&1[:tool_call_results] || []))

      assert Enum.any?(
               results,
               &match?(%{result: {:error, {:tool_error, :broken, %RuntimeError{}}}}, &1)
             )
    end

    test "an unsupported HTTP method has one tag naming who refused it" do
      assert {:error, {:http_method_not_supported, Imp.HTTP, :trace}} =
               Imp.HTTP.request(fn _, _, _, _ -> {:ok, %{}} end, :trace, "http://x", [], "")

      assert {:error, {:http_method_not_supported, :anonymous_http_transport, :get}} =
               Imp.HTTP.request(fn _, _, _, _ -> {:ok, %{}} end, :get, "http://x", [], "")
    end
  end

  describe "streams, telemetry and raising forms" do
    test "a local stream ends with the same error chunk a provider stream does" do
      assert [%Imp.Streaming.Messages.StreamResponse{chunk: {:error, :nope}, done: true}] =
               Enum.to_list(Imp.stream(%FailingProgram{}, %{}))
    end

    test "a span's exception event carries kind, reason and stacktrace" do
      ref = make_ref()
      owner = self()
      handler = "error-shapes-#{inspect(ref)}"

      :telemetry.attach(
        handler,
        [:imp, :shape_test, :exception],
        fn _event, _measurements, metadata, _ -> send(owner, {ref, metadata}) end,
        nil
      )

      try do
        assert_raise RuntimeError, fn ->
          Imp.Telemetry.span([:imp, :shape_test], %{}, fn -> raise "span broke" end)
        end

        assert_receive {^ref, %{kind: :error, reason: %RuntimeError{}, stacktrace: [_ | _]}}
      after
        :telemetry.detach(handler)
      end
    end

    test "optimize! raises Imp.Error carrying the reason optimize returns" do
      program = Imp.predict("q -> a", lm: Imp.LM.Static.new(handler: fn _, _ -> "x" end))

      error =
        assert_raise Imp.Error, fn ->
          Imp.optimize!(program, %FailingOptimizer{}, [Imp.Example.new(q: "q", a: "a")])
        end

      assert error.reason == :no_improvement
    end
  end
end
