defmodule AvatarTest do
  use ExUnit.Case, async: true

  alias DSEx.Predict.Avatar.ActionOutput

  test "executes typed actions, finishes, and returns task outputs with history" do
    lm =
      actor_lm(fn prompt ->
        cond do
          finalizer?(prompt) -> %{answer: "Paris"}
          prompt =~ "tool_output: \"Paris\"" -> finish_action()
          true -> %{action: %{tool_name: "lookup", tool_input_query: %{country: "France"}}}
        end
      end)

    lookup =
      DSEx.tool(:lookup, "Look up a country capital", fn %{country: "France"} -> "Paris" end)

    avatar = DSEx.avatar("question -> answer", [lookup], lm: lm, max_iters: 3)

    assert {:ok, prediction} = DSEx.call(avatar, %{question: "Capital of France?"})
    assert DSEx.get(prediction, :answer) == "Paris"
    assert DSEx.get(prediction, :termination_reason) == :finish

    assert [
             %ActionOutput{
               tool_name: :lookup,
               tool_input_query: %{country: "France"},
               tool_output: "Paris",
               error?: false
             }
           ] = DSEx.get(prediction, :actions)
  end

  test "iteration exhaustion still produces a typed final prediction" do
    lm =
      actor_lm(fn prompt ->
        if finalizer?(prompt),
          do: %{answer: "best available"},
          else: %{action: %{tool_name: "lookup", tool_input_query: %{query: "x"}}}
      end)

    lookup = DSEx.tool(:lookup, "lookup", fn _ -> "observed" end)
    avatar = DSEx.avatar("question -> answer", [lookup], lm: lm, max_iters: 1)

    assert {:ok, prediction} = DSEx.call(avatar, %{question: "q"})
    assert DSEx.get(prediction, :answer) == "best available"
    assert DSEx.get(prediction, :termination_reason) == :max_iters
    assert [%ActionOutput{tool_output: "observed"}] = DSEx.get(prediction, :actions)
  end

  test "unknown, denied, and crashed tools become recoverable action observations" do
    parent = self()

    lm =
      actor_lm(fn prompt ->
        cond do
          finalizer?(prompt) ->
            %{answer: "recovered"}

          prompt =~ "unknown_tool" or prompt =~ "tool_denied" or prompt =~ "tool_error" ->
            finish_action()

          prompt =~ "unknown case" ->
            %{action: %{tool_name: "missing", tool_input_query: %{query: "x"}}}

          prompt =~ "denied case" ->
            %{action: %{tool_name: "lookup", tool_input_query: %{query: "secret"}}}

          true ->
            %{action: %{tool_name: "crash", tool_input_query: %{query: "x"}}}
        end
      end)

    lookup = DSEx.tool(:lookup, "lookup", fn _ -> send(parent, :lookup_called) end)
    crash = DSEx.tool(:crash, "crash", fn _ -> raise "boom" end)

    avatar =
      DSEx.avatar("question -> answer", [lookup, crash],
        lm: lm,
        max_iters: 2,
        tool_policy: [:crash]
      )

    assert {:ok, unknown} = DSEx.call(avatar, %{question: "unknown case"})

    assert [%ActionOutput{tool_output: {:error, {:unknown_tool, "missing"}}, error?: true}] =
             DSEx.get(unknown, :actions)

    assert {:ok, denied} = DSEx.call(avatar, %{question: "denied case"})

    assert [%ActionOutput{tool_output: {:error, {:tool_denied, :lookup}}, error?: true}] =
             DSEx.get(denied, :actions)

    assert {:ok, crashed} = DSEx.call(avatar, %{question: "crash case"})

    assert [%ActionOutput{tool_output: {:error, {:tool_error, :crash, "boom"}}, error?: true}] =
             DSEx.get(crashed, :actions)

    refute_received :lookup_called
  end

  test "returned errors and crashing policies become recoverable action observations" do
    lm =
      actor_lm(fn prompt ->
        cond do
          finalizer?(prompt) ->
            %{answer: "recovered"}

          prompt =~ "tool_policy_error" or prompt =~ "not_found" ->
            finish_action()

          prompt =~ "policy case" ->
            %{action: %{tool_name: "lookup", tool_input_query: %{mode: "policy"}}}

          true ->
            %{action: %{tool_name: "lookup", tool_input_query: %{mode: "returned_error"}}}
        end
      end)

    lookup = DSEx.tool(:lookup, "lookup", fn _ -> {:error, :not_found} end)
    exploding_policy = fn _name, _arguments -> raise "policy exploded" end

    returned_error = DSEx.avatar("question -> answer", [lookup], lm: lm, max_iters: 2)

    assert {:ok, prediction} = DSEx.call(returned_error, %{question: "returned error case"})

    assert [%ActionOutput{tool_output: {:error, :not_found}, error?: true}] =
             DSEx.get(prediction, :actions)

    policy_error =
      DSEx.avatar("question -> answer", [lookup],
        lm: lm,
        max_iters: 2,
        tool_policy: exploding_policy
      )

    assert {:ok, prediction} = DSEx.call(policy_error, %{question: "policy case"})

    assert [
             %ActionOutput{
               tool_output: {:error, {:tool_policy_error, :lookup, "policy exploded"}},
               error?: true
             }
           ] = DSEx.get(prediction, :actions)
  end

  test "validates reserved fields and malformed actions" do
    assert_raise ArgumentError, ~r/reserved fields.*avatar_history/, fn ->
      DSEx.avatar("avatar_history -> answer", [])
    end

    lm = actor_lm(fn _prompt -> %{action: %{tool_name: nil, tool_input_query: %{}}} end)
    avatar = DSEx.avatar("question -> answer", [], lm: lm)

    assert {:error, {:invalid_avatar_inputs, "expected inputs as {key, value} pairs"}} =
             DSEx.call(avatar, [:not_a_pair])

    assert {:error, %{reason: {:error, %DSEx.AdapterParseError{message: message}}}} =
             DSEx.call(avatar, %{question: "q"})

    assert message =~ "action.tool_name is required"
  end

  defp actor_lm(handler) do
    %{
      module: DSEx.LM.Static,
      opts: [handler: fn messages, _opts -> handler.(prompt(messages)) end]
    }
  end

  defp prompt(messages), do: Enum.map_join(messages, "\n", & &1.content)
  defp finalizer?(prompt), do: prompt =~ "Do not request another tool."
  defp finish_action, do: %{action: %{tool_name: "Finish", tool_input_query: %{}}}
end
