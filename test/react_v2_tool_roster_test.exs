defmodule ReActV2ToolRosterTest do
  use ExUnit.Case, async: true

  # The roster a step sends, and what decides the step's prompt, must not
  # depend on anything but the program and its LM: not on the order the
  # process created the tool names' atoms in, and not on an LM wrapper.

  defp runner(_args), do: %{"ok" => true}

  defp tools, do: [Imp.tool(:zeta_probe, "Z", &runner/1), Imp.tool(:alpha_probe, "A", &runner/1)]

  defp recording_lm(owner, reply) do
    Imp.LM.Static.new(
      handler: fn messages, opts ->
        send(owner, {:request, messages, opts})
        reply
      end
    )
  end

  defp roster(opts), do: Enum.map(opts[:tools], & &1.function.name)

  test "the roster is sent in declared order, then submit" do
    submit = %{tool_calls: [%{name: "submit", arguments: %{answer: "ok", confidence: 1.0}}]}

    program =
      Imp.react("intent -> answer, confidence: float", tools(), lm: recording_lm(self(), submit))

    assert {:ok, _} = Imp.call(program, %{intent: "hi"})
    assert_received {:request, _messages, opts}
    assert roster(opts) == ["zeta_probe", "alpha_probe", "submit"]

    program = Imp.react("intent -> answer", Enum.reverse(tools()), lm: recording_lm(self(), "ok"))
    assert {:ok, _} = Imp.call(program, %{intent: "hi"})
    assert_received {:request, _messages, opts}
    assert roster(opts) == ["alpha_probe", "zeta_probe"]
  end

  test "a saved agent keeps its declared order" do
    registry = Imp.Saving.Registry.new(roster_runner: &runner/1)
    program = Imp.react("intent -> answer", tools())

    restored =
      program
      |> Imp.dump(registry: registry)
      |> Jason.encode!()
      |> Jason.decode!()
      |> Imp.load!(registry: registry)

    lm = recording_lm(self(), "ok")
    assert {:ok, _} = Imp.context([lm: lm], fn -> Imp.call(restored, %{intent: "hi"}) end)
    assert_received {:request, _messages, opts}
    assert roster(opts) == ["zeta_probe", "alpha_probe"]

    # A 0.5.0 file lists its tools by name, and loads in that order.
    state = program |> Imp.dump(registry: registry) |> Jason.encode!() |> Jason.decode!()
    state = Map.update!(state, "tools", &Enum.sort_by(&1, fn tool -> tool["name"] end))
    restored = Imp.load!(state, registry: registry)
    assert {:ok, _} = Imp.context([lm: lm], fn -> Imp.call(restored, %{intent: "hi"}) end)
    assert_received {:request, _messages, opts}
    assert roster(opts) == ["alpha_probe", "zeta_probe"]
  end

  defmodule CountingLM do
    @behaviour Imp.LM
    defstruct [:owner, :native, :counter]

    @impl true
    def generate(%__MODULE__{owner: owner, counter: counter}, messages, opts) do
      :counters.add(counter, 1, 1)
      send(owner, {:request, messages, opts})

      if :counters.get(counter, 1) < 3,
        do:
          {:ok,
           %{
             tool_calls: [
               %{id: "c#{:counters.get(counter, 1)}", name: "alpha_probe", arguments: %{}}
             ]
           }},
        else: {:ok, "done"}
    end

    def tool_calling_capability(%__MODULE__{owner: owner, native: native}) do
      send(owner, :capability_asked)
      native
    end

    # Values other than an undeclared LM's defaults, so forwarding shows.
    def reasoning_capability(%__MODULE__{}), do: true
    def response_format_capability(%__MODULE__{}), do: Imp.LM.Capability.json_schema()
  end

  test "the LM is asked whether it calls tools once per call, not once per step" do
    lm = %CountingLM{owner: self(), native: true, counter: :counters.new(1, [])}
    program = Imp.react("intent -> answer", tools(), lm: lm)

    assert {:ok, prediction} = Imp.call(program, %{intent: "hi"})
    assert Imp.get(prediction, :answer) == "done"

    for _step <- 1..3, do: assert_received({:request, _messages, _opts})
    assert_received :capability_asked
    refute_received :capability_asked
  end

  test "a wrapped LM answers for the LM it wraps" do
    text_only = %CountingLM{owner: self(), native: false, counter: :counters.new(1, [])}

    {:ok, budget} =
      Imp.start_optimizer_budget(
        limits: %{requests: 10, input_tokens: 100_000, output_tokens: 1_000, usd: 1.0},
        pricing: %{"input_per_million" => 1.0, "output_per_million" => 2.0},
        default_max_output_tokens: 100
      )

    budgeted = Imp.budgeted_lm(text_only, budget, max_output_tokens: 100)
    rollout = %Imp.Optimizer.BootstrapFewShot.RolloutLM{lm: text_only, round: 1}

    for wrapper <- [budgeted, rollout] do
      refute Imp.LM.tool_calling_capability(wrapper)
      assert Imp.LM.reasoning_capability(wrapper)
      assert Imp.LM.response_format_capability(wrapper) == Imp.LM.Capability.json_schema()
    end

    program = Imp.react("intent -> answer", tools(), lm: budgeted)
    assert {:ok, _} = Imp.call(program, %{intent: "hi"})
    assert_received {:request, [system | _], opts}
    assert system.content =~ "[[ ## tool_calls ## ]]"
    assert opts[:tools] in [nil, []]
  end
end
