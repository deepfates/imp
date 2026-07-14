defmodule AvatarTest do
  use ExUnit.Case, async: true

  alias Imp.Predict.Avatar.ActionOutput

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
      Imp.tool(:lookup, "Look up a country capital", fn %{country: "France"} -> "Paris" end)

    avatar = Imp.avatar("question -> answer", [lookup], lm: lm, max_iters: 3)

    assert {:ok, prediction} = Imp.call(avatar, %{question: "Capital of France?"})
    assert Imp.get(prediction, :answer) == "Paris"
    assert Imp.get(prediction, :termination_reason) == :finish

    assert [
             %ActionOutput{
               tool_name: :lookup,
               tool_input_query: %{country: "France"},
               tool_output: "Paris",
               error?: false
             }
           ] = Imp.get(prediction, :actions)
  end

  test "iteration exhaustion still produces a typed final prediction" do
    lm =
      actor_lm(fn prompt ->
        if finalizer?(prompt),
          do: %{answer: "best available"},
          else: %{action: %{tool_name: "lookup", tool_input_query: %{query: "x"}}}
      end)

    lookup = Imp.tool(:lookup, "lookup", fn _ -> "observed" end)
    avatar = Imp.avatar("question -> answer", [lookup], lm: lm, max_iters: 1)

    assert {:ok, prediction} = Imp.call(avatar, %{question: "q"})
    assert Imp.get(prediction, :answer) == "best available"
    assert Imp.get(prediction, :termination_reason) == :max_iters
    assert [%ActionOutput{tool_output: "observed"}] = Imp.get(prediction, :actions)
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

    lookup = Imp.tool(:lookup, "lookup", fn _ -> send(parent, :lookup_called) end)
    crash = Imp.tool(:crash, "crash", fn _ -> raise "boom" end)

    avatar =
      Imp.avatar("question -> answer", [lookup, crash],
        lm: lm,
        max_iters: 2,
        tool_policy: [:crash]
      )

    assert {:ok, unknown} = Imp.call(avatar, %{question: "unknown case"})

    assert [%ActionOutput{tool_output: {:error, {:unknown_tool, "missing"}}, error?: true}] =
             Imp.get(unknown, :actions)

    assert {:ok, denied} = Imp.call(avatar, %{question: "denied case"})

    assert [%ActionOutput{tool_output: {:error, {:tool_denied, :lookup}}, error?: true}] =
             Imp.get(denied, :actions)

    assert {:ok, crashed} = Imp.call(avatar, %{question: "crash case"})

    assert [%ActionOutput{tool_output: {:error, {:tool_error, :crash, "boom"}}, error?: true}] =
             Imp.get(crashed, :actions)

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

    lookup = Imp.tool(:lookup, "lookup", fn _ -> {:error, :not_found} end)
    exploding_policy = fn _name, _arguments -> raise "policy exploded" end

    returned_error = Imp.avatar("question -> answer", [lookup], lm: lm, max_iters: 2)

    assert {:ok, prediction} = Imp.call(returned_error, %{question: "returned error case"})

    assert [%ActionOutput{tool_output: {:error, :not_found}, error?: true}] =
             Imp.get(prediction, :actions)

    policy_error =
      Imp.avatar("question -> answer", [lookup],
        lm: lm,
        max_iters: 2,
        tool_policy: exploding_policy
      )

    assert {:ok, prediction} = Imp.call(policy_error, %{question: "policy case"})

    assert [
             %ActionOutput{
               tool_output: {:error, {:tool_policy_error, :lookup, "policy exploded"}},
               error?: true
             }
           ] = Imp.get(prediction, :actions)
  end

  test "validates reserved fields and malformed actions" do
    assert_raise ArgumentError, ~r/reserved fields.*avatar_history/, fn ->
      Imp.avatar("avatar_history -> answer", [])
    end

    lm = actor_lm(fn _prompt -> %{action: %{tool_name: nil, tool_input_query: %{}}} end)
    avatar = Imp.avatar("question -> answer", [], lm: lm)

    assert {:error, {:invalid_avatar_inputs, "expected inputs as {key, value} pairs"}} =
             Imp.call(avatar, [:not_a_pair])

    assert {:error, %{reason: {:error, %Imp.AdapterParseError{message: message}}}} =
             Imp.call(avatar, %{question: "q"})

    assert message =~ "action.tool_name is required"
  end

  defp actor_lm(handler) do
    %{
      module: Imp.LM.Static,
      opts: [handler: fn messages, _opts -> handler.(prompt(messages)) end]
    }
  end

  defp prompt(messages), do: Enum.map_join(messages, "\n", & &1.content)
  defp finalizer?(prompt), do: prompt =~ "Do not request another tool."
  defp finish_action, do: %{action: %{tool_name: "Finish", tool_input_query: %{}}}
end
