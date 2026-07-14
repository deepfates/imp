defmodule DSEx.Optimizer.GEPA.ModuleSelectorTest do
  use ExUnit.Case, async: true

  alias DSEx.Optimizer.GEPA.{Adapter, Engine, ModuleSelector, Result}

  defmodule AdapterFixture do
    @behaviour Adapter
    defstruct []

    @impl true
    def evaluate(_adapter, batch, candidate, opts) do
      score =
        Enum.reduce(candidate, 0.0, fn {_component, text}, total ->
          total + (text |> String.graphemes() |> Enum.count(&(&1 == "!")))
        end)

      trajectories =
        if Keyword.get(opts, :capture_traces, false) do
          Map.new(candidate, fn {component, _text} ->
            {component, List.duplicate(nil, length(batch))}
          end)
        else
          %{}
        end

      Result.new(
        List.duplicate(candidate, length(batch)),
        List.duplicate(score, length(batch)),
        trajectories: trajectories,
        side_information:
          Map.new(candidate, fn {component, _text} -> {component, [component]} end),
        metadata: %{metric_calls: length(batch)}
      )
    end

    @impl true
    def make_reflective_dataset(_adapter, _candidate, result, components) do
      Map.new(components, fn component ->
        {component,
         [%{trajectory: hd(Map.fetch!(result.trajectories, component)), score: hd(result.scores)}]}
      end)
    end
  end

  defmodule ContextSelector do
    @behaviour ModuleSelector

    @impl true
    def select_modules(state, trajectories, scores, candidate_idx, candidate) do
      send(
        Process.get(:module_selector_owner),
        {:selector_context, state, trajectories, scores, candidate_idx, candidate}
      )

      [:right, :left]
    end
  end

  defmodule StructSelector do
    @behaviour ModuleSelector
    defstruct [:component, :owner]

    @impl true
    def select_modules(selector, state, trajectories, scores, candidate_idx, candidate) do
      send(
        selector.owner,
        {:struct_context, selector, state, trajectories, scores, candidate_idx, candidate}
      )

      [selector.component]
    end
  end

  defmodule InvalidSelector do
    @behaviour ModuleSelector

    @impl true
    def select_modules(_state, _trajectories, _scores, _candidate_idx, _candidate),
      do: [:missing]
  end

  test ":all proposes and accepts every replacement as one atomic candidate" do
    owner = self()

    proposer = fn candidate, component, records, _iteration ->
      send(owner, {:proposal, component, records})
      Map.fetch!(candidate, component) <> "!"
    end

    state =
      Engine.run(
        %AdapterFixture{},
        %{left: "left", right: "right"},
        [:train],
        [:validation],
        proposer,
        max_iterations: 1,
        module_selector: :all
      )

    assert ModuleSelector.component_order(%{right: "right", left: "left"}) == [:left, :right]

    assert Enum.map(state.candidates, & &1.candidate) == [
             %{left: "left", right: "right"},
             %{left: "left!", right: "right!"}
           ]

    assert state.budget.reflection_calls == 2
    assert List.last(state.history).components == [:left, :right]

    for component <- [:left, :right] do
      assert_receive {:proposal, ^component, [record]}
      assert record.score == 0.0
    end
  end

  test "custom module and struct selectors receive verified source-shaped context" do
    Process.put(:module_selector_owner, self())
    seed = %{left: "left", right: "right"}

    module_state =
      Engine.run(
        %AdapterFixture{},
        seed,
        [:train],
        [:validation],
        fn candidate, component, _records, _iteration -> candidate[component] <> "!" end,
        max_iterations: 1,
        module_selector: ContextSelector
      )

    assert_receive {:selector_context, selector_state, trajectories, scores, 0, ^seed}
    assert scores == [0.0]
    assert %Engine.State{} = selector_state
    assert Map.keys(trajectories) |> MapSet.new() == Map.keys(seed) |> MapSet.new()
    assert List.last(module_state.candidates).candidate == %{left: "left!", right: "right!"}

    selector = %StructSelector{component: :left, owner: self()}

    Engine.run(
      %AdapterFixture{},
      seed,
      [:train],
      [:validation],
      fn candidate, component, _records, _iteration -> candidate[component] <> "!" end,
      max_iterations: 1,
      module_selector: selector,
      acceptance_policy: :equal_or_better
    )

    assert_receive {:struct_context, ^selector, %Engine.State{}, trajectories, scores, 0, ^seed}
    assert scores == [0.0]
    assert map_size(trajectories) == 2

    assert_raise ArgumentError, ~r/unknown component: :missing/, fn ->
      Engine.run(
        %AdapterFixture{},
        seed,
        [:train],
        [:validation],
        fn _, _, _, _ -> "unused" end,
        max_iterations: 1,
        module_selector: InvalidSelector
      )
    end
  end

  test "sequential reflection reserves every component before dispatch" do
    owner = self()

    state =
      Engine.run(
        %AdapterFixture{},
        %{left: "left", right: "right"},
        [:train],
        [:validation],
        fn candidate, component, _records, _iteration ->
          send(owner, {:proposed, component})
          candidate[component] <> "!"
        end,
        max_iterations: 1,
        module_selector: :all,
        max_reflection_calls: 1
      )

    assert state.stop_reason == {:budget_exhausted, :reflection_calls, 2, 1}
    assert state.budget.reflection_calls == 0
    assert length(state.candidates) == 1
    assert state.history == []
    refute_receive {:proposed, _component}
  end

  test "round-robin cursor and component order survive JSON checkpoint resume" do
    owner = self()
    seed = %{alpha: "alpha", beta: "beta", gamma: "gamma"}

    proposer = fn candidate, component, _records, _iteration ->
      send(owner, {:selected, component})
      candidate[component] <> "!"
    end

    assert_raise RuntimeError, "interrupt", fn ->
      Engine.run(
        %AdapterFixture{},
        seed,
        [:train],
        [:validation],
        proposer,
        max_iterations: 3,
        acceptance_policy: :equal_or_better,
        candidate_selection_strategy: :current_best,
        checkpoint_fn: fn checkpoint ->
          if checkpoint["iteration"] == 1 do
            send(owner, {:checkpoint, checkpoint})
            raise "interrupt"
          end

          :ok
        end
      )
    end

    assert_receive {:checkpoint, checkpoint}
    checkpoint = checkpoint |> Jason.encode!() |> Jason.decode!()

    resumed =
      Engine.run(
        %AdapterFixture{},
        seed,
        [:train],
        [:validation],
        proposer,
        max_iterations: 3,
        acceptance_policy: :equal_or_better,
        candidate_selection_strategy: :current_best,
        resume_state: checkpoint
      )

    selected = for _ <- 1..3, do: receive(do: ({:selected, component} -> component))
    assert selected == ModuleSelector.component_order(seed)
    assert List.last(resumed.candidates).next_component == 3
  end

  test "round-robin advances a rejected parent's persisted cursor" do
    owner = self()

    state =
      Engine.run(
        %AdapterFixture{},
        %{alpha: "alpha", beta: "beta"},
        [:train],
        [:validation],
        fn candidate, component, _records, _iteration ->
          send(owner, {:rejected_selection, component})
          candidate[component]
        end,
        max_iterations: 2,
        candidate_selection_strategy: :current_best
      )

    assert_receive {:rejected_selection, :alpha}
    assert_receive {:rejected_selection, :beta}
    assert hd(state.candidates).next_component == 2
    assert length(state.rejected) == 2

    checkpoint = state |> Engine.dump_state() |> Jason.encode!() |> Jason.decode!()

    resumed =
      Engine.run(
        %AdapterFixture{},
        %{alpha: "alpha", beta: "beta"},
        [:train],
        [:validation],
        fn candidate, component, _records, _iteration ->
          send(owner, {:resumed_selection, component})
          candidate[component]
        end,
        max_iterations: 3,
        candidate_selection_strategy: :current_best,
        resume_state: checkpoint
      )

    assert_receive {:resumed_selection, :alpha}
    assert hd(resumed.candidates).next_component == 3
  end

  test "default single-component selection uses the canonical component-list contract" do
    state =
      Engine.run(
        %AdapterFixture{},
        %{main: "main"},
        [:train],
        [:validation],
        fn %{main: "main"}, :main, [record], 1 ->
          assert record.score == 0.0
          "main!"
        end,
        max_iterations: 1
      )

    assert List.last(state.candidates).candidate == %{main: "main!"}
    assert %{components: [:main]} = List.last(state.history)
    refute Map.has_key?(List.last(state.history), :component)
    assert List.last(state.candidates).next_component == 1
  end
end
