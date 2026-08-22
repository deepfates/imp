defmodule Imp.Predict.RLM.StandaloneRuntimeTest do
  use ExUnit.Case, async: true

  alias Imp.Predict.RLM
  alias Imp.Predict.RLM.Budget
  alias Imp.Predict.RLM.Interpreter
  alias Imp.Predict.RLM.Session

  test "persistent sessions retain computed variables and version later contexts" do
    {:ok, actions} =
      Agent.start_link(fn ->
        [
          %{code: ~S|scratch = context <> "-derived"
submit(%{answer: scratch})|},
          %{code: ~S|submit(%{answer: context_0 <> ":" <> context_1 <> ":" <> scratch})|}
        ]
      end)

    rlm =
      RLM.new("context -> answer",
        lm: scripted_lm(actions),
        persistent: true,
        max_iterations: 1
      )

    on_exit(fn -> RLM.close(rlm) end)

    assert {:ok, first} = RLM.call(rlm, %{context: "first"})
    assert Imp.Prediction.get(first, :answer) == "first-derived"

    assert {:ok, second} = RLM.call(rlm, %{context: "second"})
    assert Imp.Prediction.get(second, :answer) == "first:second:first-derived"
  end

  test "persistent sessions do not retain ordinary assignments from a failed cell" do
    parent = self()

    {:ok, actions} =
      Agent.start_link(fn ->
        [
          %{code: ~S|scratch = context <> "-saved"
missing()|},
          %{code: ~S|submit(%{answer: "first turn complete"})|},
          %{code: ~S|submit(%{answer: "second turn complete"})|}
        ]
      end)

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          Agent.get_and_update(actions, fn [action | rest] ->
            if rest == [] do
              send(
                parent,
                {:persistent_repair_variables, controller_payload(messages)["variables"]}
              )
            end

            {action, rest}
          end)
        end
      ]
    }

    rlm =
      RLM.new("context -> answer",
        lm: lm,
        persistent: true,
        max_iterations: 2
      )

    on_exit(fn -> RLM.close(rlm) end)

    assert {:ok, _first} = RLM.call(rlm, %{context: "first"})
    assert {:ok, second} = RLM.call(rlm, %{context: "second"})
    assert Imp.Prediction.get(second, :answer) == "second turn complete"

    assert_receive {:persistent_repair_variables, variables}, 1_000
    refute Map.has_key?(variables, "scratch")
  end

  test "SHOW_VARS reports the constrained namespace without runtime internals" do
    interpreter = Interpreter.new(%{context: "source", count: 2}, %{}, nil)

    assert {:ok, value, next} = Interpreter.execute(interpreter, "print(SHOW_VARS())")
    assert value =~ "Available variables:"
    assert value =~ "context"
    assert value =~ "count"
    assert next.output == value
    refute value =~ "callbacks"
    refute value =~ "runtime"
  end

  test "non-persistent runs restore the canonical context alias between controller turns" do
    rlm =
      RLM.new("context -> answer",
        lm:
          scripted_lm(
            new_actions([
              %{code: ~S|context = "hijacked"
print(context)|},
              %{code: ~S|submit(%{answer: context})|}
            ])
          ),
        max_iterations: 2
      )

    assert {:ok, prediction} = RLM.call(rlm, %{context: "original"})
    assert Imp.Prediction.get(prediction, :answer) == "original"
  end

  test "closing a persistent session prevents accidental reuse" do
    rlm = RLM.new("context -> answer", lm: scripted_lm(new_actions([])), persistent: true)

    assert :ok = RLM.close(rlm)
    assert {:error, :rlm_persistent_session_closed} = RLM.call(rlm, %{context: "closed"})
  end

  test "a completed controller effect is rejected when the shared deadline expires" do
    parent = self()

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          send(parent, {:controller_effect_started, self()})

          receive do
            {:expire_deadline, budget} ->
              :sys.replace_state(budget, fn state ->
                %{state | deadline: System.monotonic_time(:millisecond) - 1}
              end)
          end

          %{code: ~S|submit(%{answer: "late"})|}
        end
      ]
    }

    rlm = RLM.new("context -> answer", lm: lm, max_time_ms: 60_000)
    call_task = Task.async(fn -> RLM.call(rlm, %{context: "deadline"}) end)

    on_exit(fn ->
      if Process.alive?(call_task.pid), do: Task.shutdown(call_task, :brutal_kill)
    end)

    assert_receive {:controller_effect_started, effect_pid}, 1_000
    send(effect_pid, {:expire_deadline, linked_budget(call_task.pid)})

    assert {:error, {:rlm_max_time_ms, 60_000, []}} = Task.await(call_task, 1_000)
  end

  test "turn two receives turn one's assistant action and REPL output as prior messages" do
    parent = self()

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          payload = controller_payload(messages)

          if payload["iteration"] == 1 do
            %{
              reasoning: "turn-one-assistant-marker",
              code: ~S|print("turn-one-repl-marker")|
            }
          else
            prior_messages = Enum.drop(messages, -1)
            send(parent, {:second_turn_history, messages})

            saw_assistant =
              Enum.any?(prior_messages, fn message ->
                message_role(message) == :assistant and
                  message_content(message) =~ "turn-one-assistant-marker"
              end)

            saw_repl =
              Enum.any?(prior_messages, fn message ->
                message_role(message) == :user and
                  String.starts_with?(message_content(message), "REPL output") and
                  message_content(message) =~ "turn-one-repl-marker"
              end)

            answer = if saw_assistant and saw_repl, do: "continuous", else: "missing-history"
            %{code: "submit(%{answer: #{inspect(answer)}})"}
          end
        end
      ]
    }

    rlm = RLM.new("context -> answer", lm: lm, max_iterations: 2)

    assert {:ok, prediction} = RLM.call(rlm, %{context: "trajectory"})
    assert Imp.Prediction.get(prediction, :answer) == "continuous"

    assert_receive {:second_turn_history, messages}, 1_000

    assert Enum.map(messages, &message_role/1) ==
             [:system, :user, :user, :assistant, :user, :user]

    assert message_content(Enum.at(messages, 3)) =~ "turn-one-assistant-marker"
    assert message_content(Enum.at(messages, 4)) =~ "turn-one-repl-marker"
  end

  test "max_llm_calls zero permits controller work and denies only a sub-LM call" do
    parent = self()

    controller = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          send(parent, :zero_budget_controller_called)
          %{code: ~S|submit(%{answer: "controller-only"})|}
        end
      ]
    }

    controller_only =
      RLM.new("context -> answer",
        lm: controller,
        max_iterations: 1,
        max_llm_calls: 0
      )

    assert {:ok, prediction} = RLM.call(controller_only, %{context: "root"})
    assert Imp.Prediction.get(prediction, :answer) == "controller-only"
    assert_receive :zero_budget_controller_called
    assert prediction.metadata.rlm.max_llm_calls == 0
    assert prediction.metadata.rlm.max_llm_calls_scope == :subcalls_only
    assert prediction.metadata.rlm.sub_lm_calls == 0

    sub_lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> send(parent, :unexpected_zero_budget_subcall) end]
    }

    querying_controller = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{code: ~S|llm_query("denied")|} end]
    }

    with_subcall =
      RLM.new("context -> answer",
        lm: querying_controller,
        sub_lm: sub_lm,
        max_iterations: 1,
        max_llm_calls: 0
      )

    assert {:error, {:rlm_max_llm_calls, 0, _trace}} =
             RLM.call(with_subcall, %{context: "root"})

    refute_received :unexpected_zero_budget_subcall
  end

  test "llm_query_batched keeps mixed failures as ordered Error strings" do
    controller =
      scripted_lm(
        new_actions([
          %{
            code: ~S"""
            answers = llm_query_batched(["first", "bad", "third"])
            submit(%{answer: Enum.join(answers, "|")})
            """
          }
        ])
      )

    sub_lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn [%{content: prompt}], _opts ->
          if prompt == "bad" do
            raise "intentional batched failure"
          else
            "ok:" <> prompt
          end
        end
      ]
    }

    rlm =
      RLM.new("context -> answer",
        lm: controller,
        sub_lm: sub_lm,
        max_iterations: 1,
        max_llm_calls: 3
      )

    assert {:ok, prediction} = RLM.call(rlm, %{context: "batch"})

    assert ["ok:first", error, "ok:third"] =
             prediction |> Imp.Prediction.get(:answer) |> String.split("|")

    assert String.starts_with?(error, "Error: ")
    assert error =~ "intentional batched failure"
    assert prediction.metadata.rlm.sub_lm_calls == 3
  end

  test "rlm_query_batched isolates children, preserves order, bounds fan-out, and contains failures" do
    parent = self()

    {:ok, concurrency} =
      Agent.start_link(fn ->
        %{active: 0, max_active: 0}
      end)

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, opts ->
          payload = controller_payload(messages)
          variables = payload["variables"]
          context = get_in(variables, ["context", "preview"])

          if context == "parent" do
            %{
              code: ~S"""
              secret = "parent-only"
              answers = rlm_query_batched(["slow", "bad", "fast"], "child-model")
              submit(%{answer: Enum.join(answers, "|")})
              """
            }
          else
            send(parent, {:child_environment, context, Keyword.get(opts, :model), variables})

            Agent.update(concurrency, fn state ->
              active = state.active + 1
              %{state | active: active, max_active: max(state.max_active, active)}
            end)

            try do
              Process.sleep(%{"slow" => 80, "bad" => 20, "fast" => 10}[context])

              if context == "bad" do
                raise "intentional child failure"
              else
                %{code: ~S|submit(%{answer: context})|}
              end
            after
              Agent.update(concurrency, &%{&1 | active: &1.active - 1})
            end
          end
        end
      ]
    }

    rlm =
      RLM.new("context -> answer",
        lm: lm,
        max_iterations: 1,
        max_recursion_depth: 2,
        max_concurrent_subcalls: 2
      )

    assert {:ok, prediction} = RLM.call(rlm, %{context: "parent"})
    answer = Imp.Prediction.get(prediction, :answer)

    assert answer =~ "slow|Error: RLM query failed -"
    assert answer =~ "intentional child failure"
    assert String.ends_with?(answer, "|fast")
    assert Agent.get(concurrency, & &1.max_active) == 2

    child_environments =
      for _index <- 1..3 do
        assert_receive {:child_environment, context, "child-model", variables}, 1_000
        refute Map.has_key?(variables, "secret")
        assert Map.keys(variables) == ["context"]
        context
      end

    assert Enum.sort(child_environments) == ["bad", "fast", "slow"]

    assert prediction.metadata.rlm.max_observed_depth == 1

    assert Enum.map(prediction.metadata.rlm_child_traces, & &1.action) ==
             [:rlm_query, :rlm_query]
  end

  test "recursive batch workers inherit dynamic Imp LM settings" do
    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          payload = controller_payload(messages)
          context = get_in(payload, ["variables", "context", "preview"])

          if context == "parent" do
            %{code: ~S|answers = rlm_query_batched(["left", "right"])
submit(%{answer: Enum.join(answers, ",")})|}
          else
            %{code: ~S|submit(%{answer: context})|}
          end
        end
      ]
    }

    rlm = RLM.new("context -> answer", max_iterations: 1, max_recursion_depth: 2)

    assert {:ok, prediction} =
             Imp.context([lm: lm], fn -> RLM.call(rlm, %{context: "parent"}) end)

    assert Imp.Prediction.get(prediction, :answer) == "left,right"
  end

  test "rlm_query falls back to one-shot generation at the official depth boundary" do
    parent = self()

    controller =
      scripted_lm(
        new_actions([
          %{code: ~S|answer = rlm_query("fallback prompt", "fallback-model")
submit(%{answer: answer})|}
        ])
      )

    sub_lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, opts ->
          send(parent, {:fallback_call, messages, Keyword.get(opts, :model)})
          "fallback answer"
        end
      ]
    }

    rlm =
      RLM.new("context -> answer",
        lm: controller,
        sub_lm: sub_lm,
        max_iterations: 1,
        max_recursion_depth: 1
      )

    assert {:ok, prediction} = RLM.call(rlm, %{context: "root"})
    assert Imp.Prediction.get(prediction, :answer) == "fallback answer"

    assert_receive {:fallback_call, [%{role: :user, content: "fallback prompt"}],
                    "fallback-model"}

    assert prediction.metadata.rlm.sub_lm_calls == 1
    assert prediction.metadata.rlm.max_observed_depth == 0
    assert prediction.metadata.rlm_child_traces == []
  end

  test "recursive children share one global sub-LM call budget" do
    {:ok, sub_lm_calls} = Agent.start_link(fn -> 0 end)

    controller = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          case Jason.decode(message_content(List.last(messages))) do
            {:ok, %{"variables" => variables}} ->
              context = get_in(variables, ["context", "preview"])

              if context == "parent" do
                %{
                  code: ~S"""
                  answers = rlm_query_batched(["a", "b", "c"])
                  submit(%{answer: Enum.join(answers, "|")})
                  """
                }
              else
                %{code: ~S|answer = llm_query(context)
submit(%{answer: answer})|}
              end

            _not_controller_payload ->
              "not a valid extracted prediction"
          end
        end
      ]
    }

    sub_lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn [%{content: prompt}], _opts ->
          Agent.update(sub_lm_calls, &(&1 + 1))
          Process.sleep(10)
          "sub:#{prompt}"
        end
      ]
    }

    rlm =
      RLM.new("context -> answer",
        lm: controller,
        sub_lm: sub_lm,
        max_iterations: 1,
        max_recursion_depth: 2,
        max_concurrent_subcalls: 3,
        max_llm_calls: 2
      )

    assert {:ok, prediction} = RLM.call(rlm, %{context: "parent"})

    parts = prediction |> Imp.Prediction.get(:answer) |> String.split("|")
    assert Enum.count(parts, &String.starts_with?(&1, "sub:")) == 2
    assert Enum.count(parts, &String.starts_with?(&1, "Error: RLM query failed -")) == 1
    assert Agent.get(sub_lm_calls, & &1) == 2
    assert prediction.metadata.rlm.sub_lm_calls == 2
  end

  test "recursive batch timeout cannot be downgraded to a partial item failure" do
    parent = self()

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          payload = controller_payload(messages)
          context = get_in(payload, ["variables", "context", "preview"])

          if context == "parent" do
            %{code: ~S|answers = rlm_query_batched(["slow"])
submit(%{answer: Enum.join(answers, ",")})|}
          else
            send(parent, :slow_child_started)
            Process.sleep(1_000)
            %{code: ~S|submit(%{answer: context})|}
          end
        end
      ]
    }

    rlm =
      RLM.new("context -> answer",
        lm: lm,
        max_iterations: 1,
        max_recursion_depth: 2,
        # Leave enough wall-clock room for the recursive child to be scheduled
        # even when the complete suite is running under load. The child itself
        # remains well beyond the budget, which is the behavior under test.
        max_time_ms: 250
      )

    assert {:error, reason} = RLM.call(rlm, %{context: "parent"})
    assert_receive :slow_child_started, 1_000
    assert inspect(reason) =~ "rlm_time_budget_exceeded"
  end

  test "persistent history is versioned and its first-call alias survives overwrite" do
    actions =
      new_actions([
        %{code: ~S|submit(%{answer: "first"})|},
        %{code: ~S|history = ["corrupt"]
missing()|},
        %{
          code: ~S|submit(%{answer: if(history == history_0, do: "stable", else: "corrupt")})|
        },
        %{
          code:
            ~S|submit(%{answer: if(history == history_0 and history_0 != history_1, do: "versioned", else: "bad")})|
        }
      ])

    rlm =
      RLM.new("context -> answer",
        lm: scripted_lm(actions),
        persistent: true,
        max_iterations: 2
      )

    on_exit(fn -> RLM.close(rlm) end)

    assert {:ok, first} = RLM.call(rlm, %{context: "first context"})
    assert Imp.Prediction.get(first, :answer) == "first"

    assert {:ok, second} = RLM.call(rlm, %{context: "second context"})
    assert Imp.Prediction.get(second, :answer) == "stable"

    assert {:ok, third} = RLM.call(rlm, %{context: "third context"})
    assert Imp.Prediction.get(third, :answer) == "versioned"
  end

  test "session histories have immutable value semantics" do
    {:ok, session} = Session.start_link()
    on_exit(fn -> Session.close(session) end)

    source = [%{"role" => "user", "content" => %{"value" => "original"}}]

    assert :stored =
             Session.transaction(session, fn snapshot ->
               next = Session.add_history(snapshot, source, [], false)
               {:stored, next}
             end)

    changed = put_in(source, [Access.at(0), "content", "value"], "changed")
    assert get_in(changed, [Access.at(0), "content", "value"]) == "changed"

    assert {"original", true} =
             Session.transaction(session, fn snapshot ->
               stored = snapshot.vars["history_0"]

               {get_in(stored, [Access.at(0), "content", "value"]),
                snapshot.vars[:history] == stored}
             end)
  end

  test "compaction shortens root prompts while preserving the full trajectory in history" do
    parent = self()

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          last_content = messages |> List.last() |> message_content()

          if String.starts_with?(last_content, "Summarize your progress so far") do
            send(parent, {:summary_messages, messages})
            "summary-without-raw-marker"
          else
            payload = Jason.decode!(last_content)

            if payload["iteration"] == 1 do
              %{code: ~S|print("recover-me")|}
            else
              send(parent, {:post_compaction_messages, messages})

              %{
                code: ~S"""
                shape = if(Enum.count(history[0]) == 2, do: "two", else: "duplicated")
                answer = shape <> "|" <> history[0][0]["role"] <> "|" <> history[0][1]["role"] <> "|" <> history[0][1]["content"]
                submit(%{answer: answer})
                """
              }
            end
          end
        end
      ]
    }

    rlm =
      RLM.new("context -> answer",
        lm: lm,
        max_iterations: 2,
        compaction: true,
        compaction_threshold_pct: 0.01,
        compaction_context_tokens: 100
      )

    assert {:ok, prediction} = RLM.call(rlm, %{context: "compact"})

    assert Imp.Prediction.get(prediction, :answer) =~
             "two|assistant|user|REPL output (run):\nrecover-me"

    assert prediction.metadata.rlm.compactions == 1
    assert prediction.metadata.rlm.compaction_token_estimator == :approximate_chars_per_4

    assert_receive {:summary_messages, summary_messages}, 1_000
    assert Enum.any?(summary_messages, &(message_content(&1) =~ "recover-me"))

    assert_receive {:post_compaction_messages, compacted_messages}, 1_000
    refute Enum.any?(compacted_messages, &(message_content(&1) =~ "recover-me"))
    assert Enum.any?(compacted_messages, &(message_content(&1) =~ "summary-without-raw-marker"))
    assert Enum.take(compacted_messages, 2) == Enum.take(summary_messages, 2)
  end

  test "session close waits for an in-flight transaction and later calls fail cleanly" do
    {:ok, session} = Session.start_link()
    parent = self()

    transaction =
      Task.async(fn ->
        Session.transaction(session, fn snapshot ->
          send(parent, :transaction_entered)

          receive do
            :release_transaction -> :ok
          end

          {:committed, put_in(snapshot, [:vars, :value], 1)}
        end)
      end)

    assert_receive :transaction_entered, 1_000
    closer = Task.async(fn -> Session.close(session) end)
    assert Task.yield(closer, 50) == nil

    send(transaction.pid, :release_transaction)
    assert Task.await(transaction, 1_000) == :committed
    assert Task.await(closer, 1_000) == :ok

    assert Session.transaction(session, fn snapshot -> snapshot end) ==
             {:error, :rlm_persistent_session_closed}
  end

  test "session transactions serialize concurrent read-modify-write updates" do
    {:ok, session} = Session.start_link()
    on_exit(fn -> Session.close(session) end)

    values =
      1..20
      |> Enum.map(fn index ->
        Task.async(fn ->
          Session.transaction(session, fn snapshot ->
            Process.sleep(rem(index, 3))
            next = %{snapshot | vars: Map.update(snapshot.vars, :counter, 1, &(&1 + 1))}
            {next.vars.counter, next}
          end)
        end)
      end)
      # This assertion is about serialized value semantics, not a scheduler
      # throughput promise. Leave enough wall-clock room for the full parallel
      # suite while the transactions themselves still overlap and contend.
      |> Task.await_many(10_000)

    assert Enum.sort(values) == Enum.to_list(1..20)
    assert Session.transaction(session, &Map.fetch!(&1.vars, :counter)) == 20
  end

  defp scripted_lm(actions) do
    %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          Agent.get_and_update(actions, fn [action | rest] -> {action, rest} end)
        end
      ]
    }
  end

  defp new_actions(actions) do
    {:ok, actions} = Agent.start_link(fn -> actions end)
    actions
  end

  defp controller_payload(messages) do
    messages
    |> List.last()
    |> message_content()
    |> Jason.decode!()
  end

  defp message_content(message),
    do: Map.get(message, :content, Map.get(message, "content", ""))

  defp message_role(message) do
    message
    |> Map.get(:role, Map.get(message, "role", :unknown))
    |> to_string()
    |> String.to_existing_atom()
  end

  defp linked_budget(call_pid) do
    {:links, links} = Process.info(call_pid, :links)

    Enum.find(links, fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} ->
          Keyword.get(dictionary, :"$initial_call") == {Budget, :init, 1}

        nil ->
          false
      end
    end) || flunk("RLM call did not start a linked budget")
  end
end
