defmodule DSEx.Predict.SearchTest do
  use ExUnit.Case, async: false

  alias DSEx.Predict.Search
  alias DSEx.Predict.Search.Candidate

  test "requires unique explicit candidate identities" do
    candidates = [Candidate.new(:same, :a), Candidate.new(:same, :b)]

    assert_raise ArgumentError, ~r/candidate ids must be unique/, fn ->
      Search.run(candidates, fn candidate, _context -> {:ok, candidate.value, 1} end)
    end

    assert_raise ArgumentError, ~r/candidate id cannot be nil/, fn ->
      Candidate.new(nil, :value)
    end
  end

  test "projected multidimensional budgets admit only an ordered prefix" do
    parent = self()

    candidates = [
      Candidate.new(:small, :a, %{calls: 1, cost_micros: 2}),
      Candidate.new(:large, :b, %{calls: 1, cost_micros: 4}),
      Candidate.new(:later, :c, %{calls: 1, cost_micros: 1})
    ]

    result =
      Search.run(
        candidates,
        fn candidate, _context ->
          send(parent, {:evaluated, candidate.id})
          {:ok, candidate.value, 1}
        end,
        budget: %{calls: 2, cost_micros: 5}
      )

    assert result.stop_reason == {:budget_exhausted, :large}
    assert result.admitted_budget == %{calls: 1, cost_micros: 2}
    assert result.observed_budget == result.admitted_budget

    assert Enum.map(result.provenance, &{&1.candidate_id, &1.status}) ==
             [small: :ok, large: :budget_exceeded, later: :budget_exceeded]

    assert_receive {:evaluated, :small}
    refute_receive {:evaluated, _}
  end

  test "sequential search exposes prior ordered outcomes and cancels after threshold" do
    candidates = Enum.map(1..3, &Candidate.new(&1, &1, %{calls: 1}))

    result =
      Search.run(
        candidates,
        fn candidate, context ->
          expected_prior_ids =
            if candidate.id == 1, do: [], else: Enum.to_list(1..(candidate.id - 1))

          assert Enum.map(context.outcomes, & &1.candidate_id) == expected_prior_ids

          {:ok, candidate.value, candidate.value / 2}
        end,
        threshold: 1.0
      )

    assert result.best.candidate_id == 2
    assert result.stop_reason == {:threshold_reached, 2}
    assert Enum.map(result.provenance, & &1.status) == [:ok, :ok, :cancelled]
    assert result.observed_budget == %{calls: 2}
  end

  test "score ties have deterministic first and last policies" do
    candidates = [Candidate.new(:first, 1), Candidate.new(:last, 2)]
    evaluator = fn candidate, _context -> {:ok, candidate.value, 0.5} end

    assert Search.run(candidates, evaluator, tie_policy: :first).best.candidate_id == :first
    assert Search.run(candidates, evaluator, tie_policy: :last).best.candidate_id == :last
  end

  test "concurrent execution is bounded and provenance remains in candidate order" do
    {:ok, tracker} = Agent.start_link(fn -> %{active: 0, peak: 0} end)

    candidates =
      Enum.map(1..4, fn id ->
        delay = if rem(id, 2) == 0, do: 5, else: 30
        Candidate.new(id, delay)
      end)

    result =
      Search.run(
        candidates,
        fn candidate, _context ->
          Agent.update(tracker, fn state ->
            active = state.active + 1
            %{active: active, peak: max(state.peak, active)}
          end)

          Process.sleep(candidate.value)
          Agent.update(tracker, &%{&1 | active: &1.active - 1})
          {:ok, candidate.id, candidate.id}
        end,
        mode: :concurrent,
        max_concurrency: 2
      )

    assert Agent.get(tracker, & &1) == %{active: 0, peak: 2}
    assert Enum.map(result.outcomes, & &1.candidate_id) == [1, 2, 3, 4]
    assert Enum.map(result.provenance, & &1.candidate_id) == [1, 2, 3, 4]
    assert result.best.candidate_id == 4
  end

  test "candidate errors, exceptions, and timeouts are isolated" do
    parent = self()

    candidates = [
      Candidate.new(:error, :error),
      Candidate.new(:raise, :raise),
      Candidate.new(:timeout, :timeout),
      Candidate.new(:ok, :ok)
    ]

    evaluator = fn candidate, _context ->
      case candidate.value do
        :error ->
          {:error, :provider_unavailable}

        :raise ->
          raise "local failure"

        :timeout ->
          Process.sleep(80)
          send(parent, :timed_out_worker_survived)
          {:ok, :late, 10}

        :ok ->
          {:ok, :answer, 1}
      end
    end

    Enum.each([:sequential, :concurrent], fn mode ->
      result =
        Search.run(candidates, evaluator,
          mode: mode,
          max_concurrency: 2,
          timeout: 20
        )

      assert result.best.value == :answer
      assert Enum.map(result.outcomes, & &1.status) == [:error, :error, :timeout, :ok]
      assert Enum.at(result.outcomes, 0).error == :provider_unavailable
      assert Enum.at(result.outcomes, 1).error == {:exception, "local failure"}
    end)

    refute_receive :timed_out_worker_survived, 100
  end

  test "concurrent threshold stopping cancels speculative tasks" do
    parent = self()

    result =
      Search.run(
        [Candidate.new(:winner, :winner), Candidate.new(:blocked, :blocked)],
        fn
          %Candidate{value: :winner}, _context ->
            Process.sleep(10)
            {:ok, :winner, 1}

          %Candidate{value: :blocked}, _context ->
            send(parent, {:blocked_worker, self()})
            Process.sleep(:infinity)
        end,
        mode: :concurrent,
        max_concurrency: 2,
        threshold: 1
      )

    assert result.stop_reason == {:threshold_reached, :winner}
    assert Enum.map(result.provenance, & &1.status) == [:ok, :cancelled]
    assert_receive {:blocked_worker, pid}
    refute Process.alive?(pid)
  end

  test "concurrent threshold accounting includes speculation that already completed" do
    result =
      Search.run(
        [Candidate.new(:threshold, 40, %{calls: 1}), Candidate.new(:fast, 1, %{calls: 1})],
        fn candidate, _context ->
          Process.sleep(candidate.value)
          score = if candidate.id == :threshold, do: 1.0, else: 0.5
          {:ok, candidate.id, score}
        end,
        mode: :concurrent,
        max_concurrency: 2,
        threshold: 1.0
      )

    assert Enum.map(result.outcomes, & &1.candidate_id) == [:threshold, :fast]
    assert Enum.map(result.provenance, & &1.status) == [:ok, :ok]
    assert result.observed_budget == %{calls: 2}
  end

  test "emits search and candidate telemetry without optimizer state" do
    handler_id = {__MODULE__, self(), make_ref()}

    events = [
      [:dsex, :predict, :search, :start],
      [:dsex, :predict, :search, :stop],
      [:dsex, :predict, :search, :candidate, :start],
      [:dsex, :predict, :search, :candidate, :stop]
    ]

    :ok = :telemetry.attach_many(handler_id, events, &__MODULE__.handle_telemetry/4, self())

    on_exit(fn -> :telemetry.detach(handler_id) end)

    result =
      Search.run([Candidate.new("local-1", :answer)], fn candidate, _context ->
        {:ok, candidate.value, 1}
      end)

    assert result.best.value == :answer

    assert_receive {:search_telemetry, [:dsex, :predict, :search, :start], _,
                    %{mode: :sequential}}

    assert_receive {:search_telemetry, [:dsex, :predict, :search, :candidate, :start], _,
                    %{candidate_id: "local-1"}}

    assert_receive {:search_telemetry, [:dsex, :predict, :search, :candidate, :stop],
                    %{duration: duration}, %{status: :ok}}

    assert duration > 0

    assert_receive {:search_telemetry, [:dsex, :predict, :search, :stop], %{duration: _},
                    %{result: :ok}}
  end

  test "provider-free natural task records comparable sequential and concurrent measurements" do
    candidates =
      [
        {"four", "4", 0.5},
        {"four!", "4", 0.8},
        {"5", "5", 0.0},
        {"the answer is four", "4", 1.0}
      ]
      |> Enum.with_index(1)
      |> Enum.map(fn {{text, parsed, quality}, id} ->
        Candidate.new("answer-#{id}", %{text: text, parsed: parsed, quality: quality}, %{
          calls: 1,
          cost_units: 1
        })
      end)

    evaluator = fn candidate, _context ->
      Process.sleep(30)
      {:ok, candidate.value, candidate.value.quality}
    end

    {sequential_us, sequential} = :timer.tc(fn -> Search.run(candidates, evaluator) end)

    {concurrent_us, concurrent} =
      :timer.tc(fn ->
        Search.run(candidates, evaluator, mode: :concurrent, max_concurrency: 2)
      end)

    artifact = %{
      sequential: summary(sequential, sequential_us),
      bounded_concurrent: summary(concurrent, concurrent_us),
      latency_is_release_assertion: false
    }

    assert artifact.sequential.quality == artifact.bounded_concurrent.quality
    assert artifact.sequential.answer == artifact.bounded_concurrent.answer
    assert artifact.sequential.projected_cost == artifact.bounded_concurrent.projected_cost
    refute artifact.latency_is_release_assertion
    assert artifact.sequential.latency_us > 0
    assert artifact.bounded_concurrent.latency_us > 0
  end

  defp summary(result, latency_us) do
    %{
      answer: result.best.value.text,
      quality: result.best.score,
      projected_cost: result.observed_budget.cost_units,
      latency_us: latency_us
    }
  end

  @doc false
  def handle_telemetry(event, measurements, metadata, owner) do
    send(owner, {:search_telemetry, event, measurements, metadata})
  end
end
