defmodule DSEx.Saving do
  @moduledoc """
  JSON save/load helpers for portable program state.

  Saved programs are treated as an external trust boundary. Loading validates the
  artifact shape, allowlists adapters and provider clients, and never restores
  credentials from disk.
  """

  alias DSEx.Optimizer.Trajectory

  @predict_required_keys ["type", "signature", "demos", "config", "metadata"]
  @rag_required_keys ["type", "program", "retriever", "query_field", "context_field", "k"]
  @program_of_thought_required_keys ["type", "signature", "predict", "output_field"]
  @artifact_type "dsex_program_artifact"
  @artifact_schema_version 1
  @registry_context_key {__MODULE__, :registry}
  @sensitive_keys ~w(api_key authorization token password secret access_token client_secret private_key x_api_key)

  def save!(program, path, opts \\ []) do
    directory = Path.dirname(path)
    File.mkdir_p!(directory)

    payload = program |> dump(opts) |> json_normalize!()

    artifact = %{
      "artifact_type" => @artifact_type,
      "schema_version" => @artifact_schema_version,
      "payload_sha256" => payload_checksum(payload),
      "payload" => payload
    }

    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, Jason.encode!(artifact, pretty: true) <> "\n", [:sync])
      File.rename!(temporary, path)
      :ok
    after
      File.rm(temporary)
    end
  end

  def load!(path, opts \\ []) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> then(&with_registry(opts, fn -> load_artifact!(&1) end))
  end

  def dump(program, opts) do
    with_registry(opts, fn -> dump(program) end)
  end

  def dump(program) do
    program
    |> dump_state()
    |> redact_dump()
  end

  def load(state, opts) do
    with_registry(opts, fn -> load(state) end)
  end

  defp load_artifact!(
         %{
           "artifact_type" => @artifact_type,
           "schema_version" => @artifact_schema_version,
           "payload_sha256" => checksum,
           "payload" => payload
         } = artifact
       ) do
    require_keys!(artifact, ["artifact_type", "schema_version", "payload_sha256", "payload"])

    unless is_binary(checksum) and
             :crypto.hash_equals(checksum, payload_checksum(payload)) do
      raise ArgumentError, "saved DSEx artifact payload checksum mismatch"
    end

    load(payload)
  end

  defp load_artifact!(%{"artifact_type" => @artifact_type, "schema_version" => version}) do
    raise ArgumentError, "unsupported saved DSEx artifact schema version: #{inspect(version)}"
  end

  defp load_artifact!(state), do: load(state)

  defp dump_state(%DSEx.Predict.Predict{} = program) do
    program
    |> DSEx.Predict.Predict.dump()
    |> Map.update!("config", &dump_portable_config!(&1, "Predict config"))
    |> Map.put("type", "predict")
  end

  defp dump_state(%DSEx.Playbook.WithContext{} = wrapper) do
    %{
      "type" => "with_playbook",
      "program" => dump(wrapper.program),
      "playbook" => DSEx.Playbook.dump(wrapper.playbook)
    }
  end

  defp dump_state(%DSEx.Predict.ChainOfThought{predict: predict}) do
    predict |> dump() |> Map.put("type", "chain_of_thought")
  end

  defp dump_state(%DSEx.Predict.RAG{} = rag) do
    %{
      "type" => "rag",
      "program" => dump(rag.program),
      "retriever" => dump_retriever(rag.retriever),
      "query_field" => DSEx.Optimizer.Report.json_safe(rag.query_field),
      "context_field" => DSEx.Optimizer.Report.json_safe(rag.context_field),
      "k" => rag.k,
      "hops" => rag.hops
    }
  end

  defp dump_state(%DSEx.Predict.ProgramOfThought{} = pot) do
    %{
      "type" => "program_of_thought",
      "signature" => DSEx.Signature.dump(pot.signature),
      "predict" => dump(pot.predict),
      "output_field" => DSEx.Optimizer.Report.json_safe(pot.output_field)
    }
  end

  defp dump_state(%DSEx.Predict.MultiChainComparison{} = comparison) do
    %{
      "type" => "multi_chain_comparison",
      "predict" => dump(comparison.predict),
      "last_key" => DSEx.Optimizer.Report.json_safe(comparison.last_key),
      "m" => comparison.m
    }
  end

  defp dump_state(%DSEx.Predict.KNN{} = knn) do
    %{
      "type" => "knn",
      "examples" => DSEx.Optimizer.Report.json_safe(knn.retriever.examples),
      "k" => knn.retriever.k,
      "field" => DSEx.Optimizer.Report.json_safe(knn.field)
    }
  end

  defp dump_state(%DSEx.Predict.Avatar{} = avatar) do
    state = %{
      "type" => "avatar",
      "signature" => dump_portable_signature!(avatar.signature, "Avatar signature"),
      "actor" => dump_avatar_predict(avatar.actor, "Avatar actor"),
      "finisher" => dump_avatar_predict(avatar.finisher, "Avatar finisher"),
      "tools" => dump_avatar_tools(avatar.tools),
      "max_iters" => avatar.max_iters,
      "tool_policy" => dump_tool_policy(avatar.tool_policy, "Avatar tool policy"),
      "metadata" => dump_portable_value!(avatar.metadata, "Avatar metadata")
    }

    require_portable_json!(state, "Avatar")
  end

  defp dump_state(%DSEx.Predict.BestOfN{} = best) do
    %{
      "type" => "best_of_n",
      "program" => dump(best.program),
      "metric" => dump_callback!(best.metric, "BestOfN metric"),
      "feedback" => dump_optional_callback(best.feedback_fn, "BestOfN feedback"),
      "n" => best.n,
      "threshold" => best.threshold
    }
  end

  defp dump_state(%DSEx.Predict.Refine{} = refine) do
    %{
      "type" => "refine",
      "program" => dump(refine.program),
      "metric" => dump_callback!(refine.metric, "Refine metric"),
      "feedback" => dump_optional_callback(refine.feedback_fn, "Refine feedback"),
      "max_attempts" => refine.max_attempts,
      "threshold" => refine.threshold
    }
  end

  defp dump_state(%DSEx.Predict.Assertions{} = assertions) do
    %{
      "type" => "assertions",
      "program" => dump(assertions.program),
      "assertions" =>
        Enum.map(assertions.assertions, fn assertion ->
          %{
            "name" => DSEx.Optimizer.Report.json_safe(assertion.name),
            "predicate" => dump_callback!(assertion.predicate, "assertion predicate"),
            "message" => assertion.message
          }
        end),
      "max_attempts" => assertions.max_attempts,
      "strict" => assertions.strict
    }
  end

  defp dump_state(%DSEx.Predict.ReAct{} = react) do
    %{
      "type" => "react",
      "signature" => DSEx.Signature.dump(react.signature),
      "react" => dump(react.react),
      "tools" => dump_tools(Map.delete(react.tools, :submit), "ReAct"),
      "max_iters" => react.max_iters,
      "mode" => dump_react_mode!(react.mode),
      "tool_policy" => dump_tool_policy(react.tool_policy, "ReAct tool policy")
    }
  end

  defp dump_state(%DSEx.Predict.ReActV2{} = react) do
    %{
      "type" => "react_v2",
      "signature" => DSEx.Signature.dump(react.signature),
      "react" => dump(react.react),
      "tools" => dump_tools(Map.delete(react.tools, :submit), "ReActV2"),
      "max_iters" => react.max_iters,
      "tool_policy" => dump_tool_policy(react.tool_policy, "ReActV2 tool policy")
    }
  end

  defp dump_state(%DSEx.Predict.CodeAct{} = code_act) do
    %{
      "type" => "code_act",
      "program_of_thought" => dump(code_act.program_of_thought),
      "tools" => dump_tools(code_act.tools, "CodeAct"),
      "max_iters" => code_act.max_iters,
      "tool_policy" => dump_tool_policy(code_act.tool_policy, "CodeAct tool policy")
    }
  end

  defp dump_state(%DSEx.Predict.RLM{} = rlm) do
    %{
      "type" => "rlm",
      "signature" => DSEx.Signature.dump(rlm.signature),
      "lm" => dump_portable_lm(rlm.lm, rlm.dynamic_lm?, "RLM controller LM"),
      "sub_lm" => dump_portable_lm(rlm.sub_lm, rlm.dynamic_sub_lm?, "RLM sub-LM"),
      "adapter" => dump_adapter(rlm.adapter, rlm.dynamic_adapter?),
      "tools" => dump_tools(rlm.tools, "RLM"),
      "tool_policy" => dump_tool_policy(rlm.tool_policy, "RLM tool policy"),
      "max_iterations" => rlm.max_iterations,
      "max_llm_calls" => rlm.max_llm_calls,
      "max_recursion_depth" => rlm.max_recursion_depth,
      "max_interpreter_steps" => rlm.max_interpreter_steps,
      "max_interpreter_value_bytes" => rlm.max_interpreter_value_bytes,
      "max_interpreter_effects" => rlm.max_interpreter_effects,
      "max_time_ms" => rlm.max_time_ms,
      "max_preview_chars" => rlm.max_preview_chars,
      "max_observation_chars" => rlm.max_observation_chars,
      "dynamic_lm" => rlm.dynamic_lm?,
      "dynamic_sub_lm" => rlm.dynamic_sub_lm?,
      "dynamic_adapter" => rlm.dynamic_adapter?
    }
  end

  defp dump_state(%DSEx.Evaluate.SemanticF1{} = evaluator) do
    %{"type" => "semantic_f1", "predict" => dump(evaluator.predict)}
  end

  defp dump_state(%DSEx.Evaluate.CompleteAndGrounded{} = evaluator) do
    %{"type" => "complete_and_grounded", "predict" => dump(evaluator.predict)}
  end

  defp dump_state(%DSEx.Optimizer.KNNFewShot.Program{} = program) do
    %{
      "type" => "knn_few_shot_program",
      "student" => dump(program.student),
      "knn" => dump(program.optimizer.knn),
      "bootstrap_k" => program.optimizer.bootstrap.k
    }
  end

  defp dump_state(%DSEx.Optimizer.Ensemble.Program{} = program) do
    %{
      "type" => "ensemble_program",
      "programs" => Enum.map(program.programs, &dump/1),
      "reduce_fn" => dump_optional_callback(program.ensemble.reduce_fn, "Ensemble reducer"),
      "size" => program.ensemble.size,
      "deterministic" => program.ensemble.deterministic
    }
  end

  defp dump_state(%Trajectory{} = trajectory), do: Trajectory.dump(trajectory)

  defp dump_state(%DSEx.Agent{} = agent) do
    %{
      "type" => "agent",
      "name" => DSEx.Optimizer.Report.json_safe(agent.name),
      "handler" => dump_callback!(agent.handler, "agent #{agent.name} handler"),
      "tools" => dump_tools(agent.tools, "agent #{agent.name}"),
      "children" => agent.children |> Map.values() |> Enum.map(&dump/1),
      "input_schema" => DSEx.Optimizer.Report.json_safe(agent.input_schema),
      "output_schema" => DSEx.Optimizer.Report.json_safe(agent.output_schema),
      "tool_policy" => dump_tool_policy(agent.tool_policy, "agent #{agent.name} tool policy")
    }
  end

  defp dump_state(program) do
    raise ArgumentError,
          "unsupported DSEx program for saving: #{inspect(program_name(program))}; " <>
            "portable saving supports data-only program graphs; callback-bearing programs require named registries"
  end

  def load(%{"type" => "predict"} = state) do
    require_keys!(state, @predict_required_keys)
    signature = Map.fetch!(state, "signature")
    demos = require_list!(state, "demos")
    config = Map.fetch!(state, "config")

    metadata =
      state
      |> require_map!("metadata")
      |> DSEx.Optimizer.Report.restore_json_safe()

    opts =
      [
        demos: Enum.map(demos, &load_demo!/1),
        config: decode_config(config),
        metadata: metadata
      ]
      |> maybe_put_adapter(state)
      |> maybe_put_lm(state)

    DSEx.Predict.Predict.new(DSEx.Signature.load(signature), opts)
  end

  def load(%{"type" => "with_playbook"} = state) do
    require_keys!(state, ["type", "program", "playbook"])

    DSEx.Playbook.WithContext.new(
      load(Map.fetch!(state, "program")),
      DSEx.Playbook.load!(Map.fetch!(state, "playbook"))
    )
  end

  def load(%{"type" => "chain_of_thought"} = state) do
    predict = state |> Map.put("type", "predict") |> load()
    %DSEx.Predict.ChainOfThought{predict: predict}
  end

  def load(%{"type" => "rag"} = state) do
    require_keys!(state, @rag_required_keys)

    DSEx.Predict.RAG.new(
      load(Map.fetch!(state, "program")),
      load_retriever!(Map.fetch!(state, "retriever")),
      query_field: DSEx.Optimizer.Report.restore_json_safe(Map.fetch!(state, "query_field")),
      context_field: DSEx.Optimizer.Report.restore_json_safe(Map.fetch!(state, "context_field")),
      k: Map.fetch!(state, "k"),
      hops: Map.get(state, "hops", 1)
    )
  end

  def load(%{"type" => "program_of_thought"} = state) do
    require_keys!(state, @program_of_thought_required_keys)
    signature = DSEx.Signature.load(Map.fetch!(state, "signature"))
    predict = load(Map.fetch!(state, "predict"))
    output_field = DSEx.Optimizer.Report.restore_json_safe(Map.fetch!(state, "output_field"))

    %DSEx.Predict.ProgramOfThought{
      signature: signature,
      predict: validate_program_of_thought_predict!(signature, predict),
      output_field: validate_program_of_thought_output_field!(signature, output_field)
    }
  end

  def load(%{"type" => "multi_chain_comparison"} = state) do
    require_keys!(state, ["type", "predict", "last_key", "m"])
    predict = load(Map.fetch!(state, "predict"))
    last_key = DSEx.Optimizer.Report.restore_json_safe(Map.fetch!(state, "last_key"))
    m = Map.fetch!(state, "m")

    unless match?(%DSEx.Predict.Predict{}, predict) and is_integer(m) and m > 0 and
             last_key in DSEx.Signature.output_names(predict.signature) do
      raise ArgumentError, "invalid saved MultiChainComparison program state"
    end

    %DSEx.Predict.MultiChainComparison{predict: predict, last_key: last_key, m: m}
  end

  def load(%{"type" => "knn"} = state) do
    require_keys!(state, ["type", "examples", "k", "field"])
    examples = DSEx.Optimizer.Report.restore_json_safe(Map.fetch!(state, "examples"))
    field = DSEx.Optimizer.Report.restore_json_safe(Map.fetch!(state, "field"))
    retriever = DSEx.Retrievers.KNN.new(examples, k: Map.fetch!(state, "k"), field: field)
    %DSEx.Predict.KNN{retriever: retriever, field: field}
  end

  def load(%{"type" => "avatar"} = state) do
    state = require_portable_json!(state, "saved Avatar")

    require_keys!(state, [
      "type",
      "signature",
      "actor",
      "finisher",
      "tools",
      "max_iters",
      "tool_policy"
    ])

    signature = DSEx.Signature.load(state["signature"])
    actor = require_predict!(load(state["actor"]), "Avatar actor")
    finisher = require_predict!(load(state["finisher"]), "Avatar finisher")
    tools = load_tools!(state["tools"], "Avatar")
    max_iters = require_non_negative_integer!(state["max_iters"], "Avatar max_iters")
    tool_policy = load_tool_policy!(state["tool_policy"], "Avatar tool policy")

    metadata =
      state
      |> Map.get("metadata", %{})
      |> DSEx.Optimizer.Report.restore_json_safe()
      |> require_map_value!("Avatar metadata")

    validate_avatar_predicts!(signature, actor, finisher)

    %DSEx.Predict.Avatar{
      signature: signature,
      actor: actor,
      finisher: finisher,
      tools: tools,
      max_iters: max_iters,
      tool_policy: tool_policy,
      metadata: metadata
    }
  end

  def load(%{"type" => "best_of_n"} = state) do
    require_keys!(state, ["type", "program", "metric", "feedback", "n"])

    DSEx.Predict.BestOfN.new(
      load(Map.fetch!(state, "program")),
      load_callback!(Map.fetch!(state, "metric"), 2, "BestOfN metric"),
      n: require_non_negative_integer!(Map.fetch!(state, "n"), "BestOfN n"),
      threshold: require_threshold!(Map.get(state, "threshold", 1.0), "BestOfN threshold"),
      feedback_fn: load_optional_callback(state["feedback"], 1, "BestOfN feedback")
    )
  end

  def load(%{"type" => "refine"} = state) do
    require_keys!(state, ["type", "program", "metric", "feedback", "max_attempts"])

    DSEx.Predict.Refine.new(
      load(Map.fetch!(state, "program")),
      load_callback!(Map.fetch!(state, "metric"), 2, "Refine metric"),
      max_attempts:
        require_non_negative_integer!(Map.fetch!(state, "max_attempts"), "Refine max_attempts"),
      threshold: require_threshold!(Map.get(state, "threshold", 1.0), "Refine threshold"),
      feedback_fn: load_optional_callback(state["feedback"], 1, "Refine feedback")
    )
  end

  def load(%{"type" => "assertions"} = state) do
    require_keys!(state, ["type", "program", "assertions", "max_attempts", "strict"])

    assertions =
      state
      |> require_list!("assertions")
      |> Enum.map(fn assertion ->
        require_keys!(assertion, ["name", "predicate", "message"])

        DSEx.Assertion.new(
          DSEx.Optimizer.Report.restore_json_safe(assertion["name"]),
          load_callback!(assertion["predicate"], [1, 2], "assertion predicate"),
          message: assertion["message"]
        )
      end)

    DSEx.Predict.Assertions.new(load(state["program"]), assertions,
      max_attempts: state["max_attempts"],
      strict: state["strict"]
    )
  end

  def load(%{"type" => "react"} = state) do
    require_keys!(state, ["type", "signature", "react", "tools", "max_iters", "tool_policy"])
    tools = load_tools!(state["tools"], "ReAct")
    mode = load_react_mode!(Map.get(state, "mode", "provider_native"))
    submit = load_react_submit_tool(mode)

    %DSEx.Predict.ReAct{
      signature: DSEx.Signature.load(state["signature"]),
      react: require_predict!(load(state["react"]), "ReAct"),
      tools: Map.put(tools, :submit, submit),
      max_iters: require_non_negative_integer!(state["max_iters"], "ReAct max_iters"),
      tool_policy: load_tool_policy!(state["tool_policy"], "ReAct tool policy"),
      mode: mode
    }
  end

  def load(%{"type" => "react_v2"} = state) do
    require_keys!(state, ["type", "signature", "react", "tools", "max_iters", "tool_policy"])
    tools = load_tools!(state["tools"], "ReActV2")
    submit = DSEx.Tool.new(:submit, "Submit the final outputs for the task.", & &1)

    %DSEx.Predict.ReActV2{
      signature: DSEx.Signature.load(state["signature"]),
      react: require_predict!(load(state["react"]), "ReActV2"),
      tools: Map.put(tools, :submit, submit),
      max_iters: require_non_negative_integer!(state["max_iters"], "ReActV2 max_iters"),
      tool_policy: load_tool_policy!(state["tool_policy"], "ReActV2 tool policy")
    }
  end

  def load(%{"type" => "code_act"} = state) do
    require_keys!(state, [
      "type",
      "program_of_thought",
      "tools",
      "max_iters",
      "tool_policy"
    ])

    %DSEx.Predict.CodeAct{
      program_of_thought: require_program_of_thought!(load(state["program_of_thought"])),
      tools: load_tools!(state["tools"], "CodeAct"),
      max_iters: require_non_negative_integer!(state["max_iters"], "CodeAct max_iters"),
      tool_policy: load_tool_policy!(state["tool_policy"], "CodeAct tool policy")
    }
  end

  def load(%{"type" => "rlm"} = state) do
    require_keys!(state, [
      "type",
      "signature",
      "lm",
      "sub_lm",
      "adapter",
      "tools",
      "tool_policy",
      "max_iterations",
      "max_llm_calls",
      "max_time_ms",
      "max_preview_chars",
      "max_observation_chars",
      "dynamic_lm",
      "dynamic_sub_lm",
      "dynamic_adapter"
    ])

    %DSEx.Predict.RLM{
      signature: DSEx.Signature.load(state["signature"]),
      lm: decode_lm(state["lm"]),
      sub_lm: decode_lm(state["sub_lm"]),
      adapter: if(state["dynamic_adapter"], do: nil, else: decode_adapter(state["adapter"])),
      tools: load_tools!(state["tools"], "RLM"),
      tool_policy: load_tool_policy!(state["tool_policy"], "RLM tool policy"),
      max_iterations:
        require_non_negative_integer!(state["max_iterations"], "RLM max_iterations"),
      max_llm_calls: require_non_negative_integer!(state["max_llm_calls"], "RLM max_llm_calls"),
      max_recursion_depth:
        require_non_negative_integer!(
          Map.get(state, "max_recursion_depth", 1),
          "RLM max_recursion_depth"
        ),
      max_interpreter_steps:
        require_positive_integer!(
          Map.get(state, "max_interpreter_steps", 10_000),
          "RLM max_interpreter_steps"
        ),
      max_interpreter_value_bytes:
        require_positive_integer!(
          Map.get(state, "max_interpreter_value_bytes", 16_000_000),
          "RLM max_interpreter_value_bytes"
        ),
      max_interpreter_effects:
        require_positive_integer!(
          Map.get(state, "max_interpreter_effects", 100),
          "RLM max_interpreter_effects"
        ),
      max_time_ms:
        require_optional_non_negative_integer!(state["max_time_ms"], "RLM max_time_ms"),
      max_preview_chars:
        require_non_negative_integer!(state["max_preview_chars"], "RLM max_preview_chars"),
      max_observation_chars:
        require_non_negative_integer!(
          state["max_observation_chars"],
          "RLM max_observation_chars"
        ),
      dynamic_lm?: state["dynamic_lm"] == true,
      dynamic_sub_lm?: state["dynamic_sub_lm"] == true,
      dynamic_adapter?: state["dynamic_adapter"] == true
    }
  end

  def load(%{"type" => "semantic_f1"} = state) do
    require_keys!(state, ["type", "predict"])

    %DSEx.Evaluate.SemanticF1{
      predict: require_chain_of_thought!(load(state["predict"]), "SemanticF1")
    }
  end

  def load(%{"type" => "complete_and_grounded"} = state) do
    require_keys!(state, ["type", "predict"])

    %DSEx.Evaluate.CompleteAndGrounded{
      predict: require_chain_of_thought!(load(state["predict"]), "CompleteAndGrounded")
    }
  end

  def load(%{"type" => "knn_few_shot_program"} = state) do
    require_keys!(state, ["type", "student", "knn", "bootstrap_k"])
    knn = load(state["knn"])

    unless match?(%DSEx.Predict.KNN{}, knn) do
      raise ArgumentError, "saved KNNFewShot knn must be a KNN program"
    end

    %DSEx.Optimizer.KNNFewShot.Program{
      student: load(state["student"]),
      optimizer: %DSEx.Optimizer.KNNFewShot{
        knn: knn,
        bootstrap: DSEx.Optimizer.LabeledFewShot.new(k: state["bootstrap_k"])
      }
    }
  end

  def load(%{"type" => "ensemble_program"} = state) do
    require_keys!(state, ["type", "programs", "reduce_fn", "size", "deterministic"])
    programs = require_list!(state, "programs") |> Enum.map(&load/1)

    ensemble =
      DSEx.Optimizer.Ensemble.new(
        reduce_fn: load_optional_callback(state["reduce_fn"], 1, "Ensemble reducer"),
        size: state["size"],
        deterministic: state["deterministic"]
      )

    DSEx.Optimizer.Ensemble.compile(ensemble, programs)
  end

  def load(%{"type" => "agent"} = state) do
    require_keys!(state, [
      "type",
      "name",
      "handler",
      "tools",
      "children",
      "input_schema",
      "output_schema",
      "tool_policy"
    ])

    name = DSEx.Optimizer.Report.restore_json_safe(state["name"])

    children =
      state
      |> require_list!("children")
      |> Enum.map(fn child ->
        case load(child) do
          %DSEx.Agent{} = agent ->
            agent

          other ->
            raise ArgumentError,
                  "saved agent child must be an Agent, got: #{inspect(program_name(other))}"
        end
      end)

    DSEx.Agent.new(
      name,
      load_callback!(state["handler"], [2, 3], "agent #{name} handler"),
      tools: Map.values(load_tools!(state["tools"], "agent #{name}")),
      children: children,
      input_schema: DSEx.Optimizer.Report.restore_json_safe(state["input_schema"]),
      output_schema: DSEx.Optimizer.Report.restore_json_safe(state["output_schema"]),
      tool_policy: load_tool_policy!(state["tool_policy"], "agent #{name} tool policy")
    )
  end

  def load(%{"type" => "dsex_optimizer_trajectory"} = state),
    do: Trajectory.load!(state)

  def load(%{"type" => type}) do
    raise ArgumentError, "unsupported saved DSEx program type: #{inspect(type)}"
  end

  def load(state) when is_map(state) do
    raise ArgumentError, "saved DSEx program is missing required key \"type\""
  end

  def load(state) do
    raise ArgumentError, "saved DSEx program must be a map, got: #{inspect(state)}"
  end

  defp program_name(%module{}), do: module
  defp program_name(program), do: program

  defp with_registry(opts, fun) when is_list(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "DSEx.Saving options must be a keyword list"
    end

    unknown = Keyword.keys(opts) -- [:registry]
    if unknown != [], do: raise(ArgumentError, "unknown DSEx.Saving options: #{inspect(unknown)}")

    registry = Keyword.get(opts, :registry, %DSEx.Saving.Registry{})

    unless match?(%DSEx.Saving.Registry{}, registry) do
      raise ArgumentError, "DSEx.Saving :registry must be a DSEx.Saving.Registry"
    end

    previous = Process.get(@registry_context_key, :__missing__)
    Process.put(@registry_context_key, registry)

    try do
      fun.()
    after
      if previous == :__missing__,
        do: Process.delete(@registry_context_key),
        else: Process.put(@registry_context_key, previous)
    end
  end

  defp with_registry(opts, _fun) do
    raise ArgumentError, "DSEx.Saving options must be a keyword list, got: #{inspect(opts)}"
  end

  defp registry, do: Process.get(@registry_context_key, %DSEx.Saving.Registry{})

  defp dump_callback!(callback, context),
    do: DSEx.Saving.Registry.key_for!(registry(), callback, context)

  defp load_callback!(name, arities, context),
    do: DSEx.Saving.Registry.fetch!(registry(), name, arities, context)

  defp dump_optional_callback(nil, _context), do: nil
  defp dump_optional_callback(callback, context), do: dump_callback!(callback, context)

  defp load_optional_callback(nil, _arities, _context), do: nil

  defp load_optional_callback(name, arities, context),
    do: load_callback!(name, arities, context)

  defp dump_avatar_predict(%DSEx.Predict.Predict{} = predict, context) do
    predict
    |> dump()
    |> Map.put("signature", dump_portable_signature!(predict.signature, "#{context} signature"))
    |> Map.put("demos", dump_portable_value!(predict.demos, "#{context} demos"))
    |> Map.update!("config", &dump_portable_config!(&1, "#{context} config"))
    |> Map.put("metadata", dump_portable_value!(predict.metadata, "#{context} metadata"))
    |> require_portable_json!(context)
  end

  defp dump_avatar_predict(predict, context) do
    raise ArgumentError,
          "#{context} must be a Predict program, got: #{inspect(program_name(predict))}"
  end

  defp dump_portable_config!(config, context) do
    config
    |> redact_config_entries()
    |> require_portable_json!(context)
  end

  defp redact_config_entries(entries) when is_list(entries) do
    Enum.map(entries, fn
      [key, value] ->
        value = redact_config_entries(value)
        redacted = redact_dump(%{key => value})
        [key, Map.fetch!(redacted, key)]

      {key, value} ->
        value = redact_config_entries(value)
        redacted = redact_dump(%{key => value})
        [key, Map.fetch!(redacted, key)]

      value ->
        redact_config_entries(value)
    end)
  end

  defp redact_config_entries(value), do: redact_dump(value)

  defp dump_portable_value!(value, context) do
    value
    |> DSEx.Optimizer.Report.json_safe()
    |> redact_dump()
    |> require_portable_json!(context)
  end

  defp redact_dump(value) when is_struct(value) do
    value
    |> Map.from_struct()
    |> redact_dump()
  end

  defp redact_dump(%{
         "type" => "with_playbook",
         "program" => program,
         "playbook" => %{"policy" => %{"reject_secrets" => true}} = playbook
       }) do
    # Playbook admission already rejects secrets. Revalidate before preserving
    # integrity hashes that generic secret-shaped-value redaction would destroy.
    validated = playbook |> DSEx.Playbook.load!() |> DSEx.Playbook.dump()
    %{"type" => "with_playbook", "program" => redact_dump(program), "playbook" => validated}
  end

  defp redact_dump(%{"type" => "with_playbook"}) do
    raise ArgumentError, "portable playbook persistence requires reject_secrets: true"
  end

  defp redact_dump(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      cond do
        to_string(key) == "schema" -> {key, DSEx.Redaction.redact(nested, [])}
        sensitive_key?(key) -> {key, "[REDACTED]"}
        true -> {key, redact_dump(nested)}
      end
    end)
  end

  defp redact_dump(value) when is_list(value), do: Enum.map(value, &redact_dump/1)
  defp redact_dump(value) when is_binary(value), do: DSEx.Redaction.redact(value, [])
  defp redact_dump(value), do: value

  defp sensitive_key?(key) do
    normalized = key |> to_string() |> String.downcase() |> String.replace("-", "_")

    Enum.any?(@sensitive_keys, fn sensitive ->
      normalized == sensitive or String.ends_with?(normalized, "_#{sensitive}")
    end)
  end

  defp dump_portable_signature!(signature, context) do
    signature
    |> DSEx.Signature.dump()
    |> DSEx.Redaction.redact([])
    |> require_portable_json!(context)
  end

  defp dump_avatar_tools(tools) do
    tools
    |> dump_tools("Avatar")
    |> Enum.map(fn tool ->
      tool
      |> Map.update!("description", &DSEx.Redaction.redact(&1, []))
      |> Map.update!("schema", &DSEx.Redaction.redact(&1, []))
    end)
  end

  defp require_portable_json!(value, context) do
    value
    |> Jason.encode!()
    |> Jason.decode!()
  rescue
    _error ->
      reraise ArgumentError,
              "#{context} must contain only portable JSON data; functions and runtime references are not supported",
              __STACKTRACE__
  end

  defp dump_tools(tools, context) when is_map(tools) do
    tools
    |> Map.values()
    |> Enum.sort_by(&to_string(&1.name))
    |> Enum.map(fn tool ->
      %{
        "name" => DSEx.Optimizer.Report.json_safe(tool.name),
        "description" => tool.description,
        "schema" => DSEx.Optimizer.Report.json_safe(tool.schema),
        "runner" => dump_callback!(tool.run, "#{context} tool #{tool.name}")
      }
    end)
  end

  defp load_tools!(states, context) when is_list(states) do
    states
    |> Enum.map(fn state ->
      require_keys!(state, ["name", "description", "schema", "runner"])
      name = DSEx.Optimizer.Report.restore_json_safe(state["name"])

      DSEx.Tool.new(
        name,
        state["description"],
        load_callback!(state["runner"], 1, "#{context} tool #{name}"),
        schema: DSEx.Optimizer.Report.restore_json_safe(state["schema"])
      )
    end)
    |> DSEx.Tool.index_tools!("saved #{context}")
  end

  defp load_tools!(states, context) do
    raise ArgumentError, "saved #{context} tools must be a list, got: #{inspect(states)}"
  end

  defp dump_tool_policy(policy, _context) when not is_function(policy),
    do: DSEx.Optimizer.Report.json_safe(policy)

  defp dump_tool_policy(policy, context),
    do: %{"registry_callback" => dump_callback!(policy, context)}

  defp load_tool_policy!(%{"registry_callback" => name}, context),
    do: load_callback!(name, 2, context)

  defp load_tool_policy!(policy, context) do
    policy = DSEx.Optimizer.Report.restore_json_safe(policy)

    case DSEx.ToolPolicy.validate(policy) do
      {:ok, policy} -> policy
      {:error, message} -> raise ArgumentError, "invalid saved #{context}: #{message}"
    end
  end

  defp dump_react_mode!(:provider_native), do: "provider_native"
  defp dump_react_mode!(:dspy_3_2_1), do: "dspy_3_2_1"

  defp dump_react_mode!(mode) do
    raise ArgumentError, "unsupported ReAct mode for persistence: #{inspect(mode)}"
  end

  defp load_react_mode!("provider_native"), do: :provider_native
  defp load_react_mode!("dspy_3_2_1"), do: :dspy_3_2_1

  defp load_react_mode!(mode) do
    raise ArgumentError, "invalid saved ReAct mode: #{inspect(mode)}"
  end

  defp load_react_submit_tool(:provider_native),
    do: DSEx.Tool.new(:submit, "Submit final outputs", fn args -> args end)

  defp load_react_submit_tool(:dspy_3_2_1),
    do:
      DSEx.Tool.new(
        :submit,
        "Mark the task complete so the collected information can be extracted",
        fn _args -> "Completed." end
      )

  defp dump_portable_lm(nil, true, _context), do: nil

  defp dump_portable_lm(%DSEx.Clients.ReqLLM{} = lm, _dynamic?, _context),
    do: DSEx.Clients.ReqLLM.dump(lm)

  defp dump_portable_lm(lm, false, context) do
    raise ArgumentError,
          "#{context} is not portable; pin ReqLLM or use dynamic settings, got: #{inspect(program_name(lm))}"
  end

  defp dump_portable_lm(nil, false, _context), do: nil
  defp dump_portable_lm(_lm, true, _context), do: nil

  defp dump_adapter(_adapter, true), do: nil
  defp dump_adapter(adapter, false) when is_atom(adapter), do: Atom.to_string(adapter)

  defp require_predict!(%DSEx.Predict.Predict{} = predict, _context), do: predict

  defp require_predict!(program, context),
    do:
      raise(
        ArgumentError,
        "saved #{context} nested program must be Predict, got: #{inspect(program_name(program))}"
      )

  defp validate_avatar_predicts!(signature, actor, finisher) do
    expected = DSEx.Predict.Avatar.new(signature, [])
    actor_signature = actor.signature
    expected_actor = %{expected.actor.signature | instructions: actor_signature.instructions}

    unless is_binary(actor_signature.instructions) and
             signatures_equivalent?(actor_signature, expected_actor) do
      raise ArgumentError, "saved Avatar actor signature does not match the task signature"
    end

    unless signatures_equivalent?(finisher.signature, expected.finisher.signature) do
      raise ArgumentError, "saved Avatar finisher signature does not match the task signature"
    end

    :ok
  end

  defp signatures_equivalent?(left, right) do
    left |> DSEx.Signature.dump() |> json_normalize!() ==
      right |> DSEx.Signature.dump() |> json_normalize!()
  end

  defp require_program_of_thought!(%DSEx.Predict.ProgramOfThought{} = program), do: program

  defp require_program_of_thought!(program),
    do:
      raise(
        ArgumentError,
        "saved CodeAct nested program must be ProgramOfThought, got: #{inspect(program_name(program))}"
      )

  defp require_chain_of_thought!(%DSEx.Predict.ChainOfThought{} = program, _context),
    do: program

  defp require_chain_of_thought!(program, context),
    do:
      raise(
        ArgumentError,
        "saved #{context} nested program must be ChainOfThought, got: #{inspect(program_name(program))}"
      )

  defp require_non_negative_integer!(value, _context) when is_integer(value) and value >= 0,
    do: value

  defp require_non_negative_integer!(value, context),
    do:
      raise(
        ArgumentError,
        "saved #{context} must be a non-negative integer, got: #{inspect(value)}"
      )

  defp require_positive_integer!(value, _context) when is_integer(value) and value > 0,
    do: value

  defp require_positive_integer!(value, context),
    do:
      raise(ArgumentError, "saved #{context} must be a positive integer, got: #{inspect(value)}")

  defp require_optional_non_negative_integer!(nil, _context), do: nil

  defp require_optional_non_negative_integer!(value, context),
    do: require_non_negative_integer!(value, context)

  defp require_map_value!(value, _context) when is_map(value), do: value

  defp require_map_value!(value, context),
    do: raise(ArgumentError, "saved #{context} must be a map, got: #{inspect(value)}")

  defp require_threshold!(nil, _context), do: nil
  defp require_threshold!(value, _context) when is_integer(value) or is_float(value), do: value

  defp require_threshold!(value, context) do
    raise ArgumentError,
          "saved #{context} must be a number or nil, got: #{inspect(value)}"
  end

  defp json_normalize!(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp payload_checksum(payload) do
    payload
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("sha256:" <> &1))
  end

  defp maybe_put_adapter(opts, %{"dynamic_adapter" => true}), do: opts

  defp maybe_put_adapter(opts, state) do
    Keyword.put(opts, :adapter, decode_adapter(Map.get(state, "adapter")))
  end

  defp maybe_put_lm(opts, %{"dynamic_lm" => true}), do: opts

  defp maybe_put_lm(opts, state) do
    case decode_lm(Map.get(state, "lm")) do
      nil -> opts
      lm -> Keyword.put(opts, :lm, lm)
    end
  end

  defp decode_config(config) when is_list(config) do
    Enum.map(config, fn
      {k, v} -> {decode_config_key(k), decode_config_value(k, v)}
      [k, v] -> {decode_config_key(k), decode_config_value(k, v)}
      other -> raise ArgumentError, "invalid saved DSEx config entry: #{inspect(other)}"
    end)
  end

  defp decode_config(config) when is_map(config),
    do: Enum.map(config, fn {k, v} -> {decode_config_key(k), decode_config_value(k, v)} end)

  defp decode_config(config) do
    raise ArgumentError, "saved DSEx config must be a map or list, got: #{inspect(config)}"
  end

  defp decode_config_value(key, value)
       when key in [:provider_options, "provider_options"] and is_list(value),
       do: decode_config(value)

  defp decode_config_value(_key, value), do: value

  defp decode_adapter(nil), do: DSEx.Adapter.Chat

  defp decode_adapter(name) when is_binary(name) do
    case name do
      "Elixir.DSEx.Adapter.Chat" -> DSEx.Adapter.Chat
      "Elixir.DSEx.Adapter.JSON" -> DSEx.Adapter.JSON
      "Elixir.DSEx.Adapter.XML" -> DSEx.Adapter.XML
      "Elixir.DSEx.Adapter.TwoStep" -> DSEx.Adapter.TwoStep
      other -> raise ArgumentError, "unsupported saved DSEx adapter: #{inspect(other)}"
    end
  end

  defp decode_adapter(adapter) do
    raise ArgumentError,
          "invalid saved DSEx adapter reference: #{inspect(adapter)}; expected an allowlisted module name string"
  end

  defp decode_lm(nil), do: nil

  defp decode_lm(%{provider: :req_llm, model: model} = state) do
    decode_req_llm!(model, Map.get(state, :opts, []))
  end

  defp decode_lm(%{"provider" => "req_llm", "model" => model} = state) do
    decode_req_llm!(model, Map.get(state, "opts", []))
  end

  defp decode_lm(%{"provider" => :req_llm, "model" => model} = state) do
    decode_req_llm!(model, Map.get(state, "opts", []))
  end

  defp decode_lm(%{provider: :req_llm}) do
    raise ArgumentError, "saved req_llm client is missing required key :model"
  end

  defp decode_lm(%{"provider" => provider}) when provider in ["req_llm", :req_llm] do
    raise ArgumentError, "saved req_llm client is missing required key \"model\""
  end

  defp decode_lm(%{"provider" => provider}) do
    raise ArgumentError,
          "unsupported saved DSEx provider: #{inspect(provider)}; saved provider clients must use req_llm"
  end

  defp decode_lm(%{provider: provider}) do
    raise ArgumentError,
          "unsupported saved DSEx provider: #{inspect(provider)}; saved provider clients must use req_llm"
  end

  defp decode_lm(lm) do
    raise ArgumentError, "invalid saved DSEx LM client: #{inspect(lm)}"
  end

  defp decode_req_llm!(nil, _opts) do
    raise ArgumentError, "saved req_llm client is missing required model"
  end

  defp decode_req_llm!(model, opts) do
    DSEx.Clients.ReqLLM.new(model, opts: decode_config(opts))
  end

  defp dump_retriever(%DSEx.Retrieve.Memory{} = retriever) do
    %{
      "type" => "memory",
      "docs" => DSEx.Optimizer.Report.json_safe(retriever.docs),
      "k" => retriever.k
    }
  end

  defp dump_retriever(retriever) do
    raise ArgumentError,
          "unsupported saved DSEx retriever: #{inspect(retriever)}; only DSEx.Retrieve.Memory is portable"
  end

  defp load_retriever!(%{"type" => "memory"} = state) do
    DSEx.Retrieve.Memory.new(
      state |> Map.fetch!("docs") |> DSEx.Optimizer.Report.restore_json_safe(),
      k: Map.fetch!(state, "k")
    )
  end

  defp load_retriever!(%{"type" => type}) do
    raise ArgumentError, "unsupported saved DSEx retriever: #{inspect(type)}"
  end

  defp load_retriever!(retriever) do
    raise ArgumentError, "invalid saved DSEx retriever: #{inspect(retriever)}"
  end

  defp validate_program_of_thought_predict!(
         %DSEx.Signature{} = task_signature,
         %DSEx.Predict.Predict{signature: planner_signature} = predict
       ) do
    cond do
      DSEx.Signature.input_names(planner_signature) != DSEx.Signature.input_names(task_signature) ->
        raise ArgumentError,
              "saved ProgramOfThought planner inputs must match task inputs"

      planner_signature.instructions != task_signature.instructions ->
        raise ArgumentError,
              "saved ProgramOfThought planner instructions must match task instructions"

      DSEx.Signature.output_names(planner_signature) != [:program, :tool, :arguments] ->
        raise ArgumentError,
              "saved ProgramOfThought planner outputs must be [:program, :tool, :arguments]"

      true ->
        predict
    end
  end

  defp validate_program_of_thought_predict!(_task_signature, predict) do
    raise ArgumentError,
          "saved ProgramOfThought nested predict must be a saved Predict program, got: #{inspect(program_name(predict))}"
  end

  defp validate_program_of_thought_output_field!(%DSEx.Signature{} = task_signature, output_field) do
    if Enum.any?(
         DSEx.Signature.output_names(task_signature),
         &(to_string(&1) == to_string(output_field))
       ) do
      output_field
    else
      raise ArgumentError,
            "saved ProgramOfThought output_field must name one of the task outputs"
    end
  end

  defp decode_config_key(key) when is_atom(key), do: key

  defp decode_config_key(key) do
    case to_string(key) do
      "temperature" -> :temperature
      "max_tokens" -> :max_tokens
      "top_p" -> :top_p
      "stop" -> :stop
      "response_format" -> :response_format
      "tools" -> :tools
      "tool_choice" -> :tool_choice
      "parallel_tool_calls" -> :parallel_tool_calls
      "openai_parallel_tool_calls" -> :openai_parallel_tool_calls
      "stream" -> :stream
      "timeout" -> :timeout
      "retries" -> :retries
      "num_retries" -> :num_retries
      "retry_backoff_ms" -> :retry_backoff_ms
      "max_completion_tokens" -> :max_completion_tokens
      "receive_timeout" -> :receive_timeout
      "cache" -> :cache
      "rollout_id" -> :rollout_id
      "provider_options" -> :provider_options
      other -> other
    end
  end

  defp require_keys!(state, keys) do
    missing = Enum.reject(keys, &Map.has_key?(state, &1))

    case missing do
      [] ->
        :ok

      _ ->
        raise ArgumentError,
              "saved DSEx #{Map.get(state, "type", "program")} is missing required keys: #{inspect(missing)}"
    end
  end

  defp require_list!(state, key) do
    case Map.fetch!(state, key) do
      value when is_list(value) -> value
      value -> raise ArgumentError, "saved DSEx #{key} must be a list, got: #{inspect(value)}"
    end
  end

  defp require_map!(state, key) do
    case Map.fetch!(state, key) do
      value when is_map(value) -> value
      value -> raise ArgumentError, "saved DSEx #{key} must be a map, got: #{inspect(value)}"
    end
  end

  defp load_demo!(%{"__dsex_type__" => "example"} = demo) do
    case DSEx.Optimizer.Report.restore_json_safe(demo) do
      %DSEx.Example{} = example ->
        example

      other ->
        raise ArgumentError, "saved DSEx demo restored to invalid value: #{inspect(other)}"
    end
  end

  defp load_demo!(demo) when is_map(demo) or is_list(demo), do: DSEx.Example.new(demo)

  defp load_demo!(demo) do
    raise ArgumentError, "saved DSEx demo must be a map or keyword list, got: #{inspect(demo)}"
  end
end
