defmodule DSPy.Teleprompt.BootstrapFewShotWithRandomSearch do
  @moduledoc "Compatibility alias for `DSPy.Teleprompt.RandomSearch`."
  defdelegate new(metric, opts \\ []), to: DSPy.Teleprompt.RandomSearch
  defdelegate compile(optimizer, program, trainset, devset), to: DSPy.Teleprompt.RandomSearch
end

defmodule DSPy.Teleprompt.BootstrapFewShotWithOptuna do
  @moduledoc "Dependency-light Optuna equivalent using random search."
  defdelegate new(metric, opts \\ []), to: DSPy.Teleprompt.RandomSearch
  defdelegate compile(optimizer, program, trainset, devset), to: DSPy.Teleprompt.RandomSearch
end

defmodule DSPy.Teleprompt.InferRules do
  @moduledoc "Infer simple textual rules from labeled examples and attach them to instructions."

  defstruct [:metric, max_rules: 5]

  def new(metric, opts \\ []),
    do: %__MODULE__{metric: metric, max_rules: Keyword.get(opts, :max_rules, 5)}

  def compile(%__MODULE__{} = infer, program, trainset) do
    rules =
      trainset
      |> Enum.take(infer.max_rules)
      |> Enum.map(fn example ->
        "When inputs resemble #{inspect(DSPy.Example.to_map(DSPy.Example.inputs(example)))}, prefer #{inspect(DSPy.Example.to_map(DSPy.Example.labels(example)))}."
      end)
      |> Enum.join("\n")

    instruction =
      (DSPy.Teleprompt.InstructionSearch.current_instruction(program) || "") <> "\n" <> rules

    DSPy.Teleprompt.InstructionSearch.put_instruction(program, instruction)
  end
end

defmodule DSPy.Teleprompt.AvatarOptimizer do
  @moduledoc "Compatibility optimizer for avatar/tool programs; delegates to GEPA-style feedback search."
  defdelegate new(metric, opts \\ []), to: DSPy.Teleprompt.GEPA
  defdelegate compile(optimizer, program, trainset, devset), to: DSPy.Teleprompt.GEPA
end
