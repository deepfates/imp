defmodule Imp.Saving do
  @moduledoc """
  JSON save/load helpers for portable program state.

  Saved programs are treated as an external trust boundary. Loading validates the
  artifact shape, allowlists adapters and provider clients, and never restores
  credentials from disk.
  """

  alias Imp.Optimizer.Trajectory

  @predict_required_keys ["type", "signature", "demos", "config", "metadata"]
  @portable_predict_metadata_atoms %{
    "training_artifact" => :training_artifact,
    "job_id" => :job_id,
    "provider" => :provider,
    "base_model" => :base_model,
    "result_model" => :result_model,
    "artifact_sha256" => :artifact_sha256,
    "mlx_lm" => :mlx_lm
  }
  @rag_required_keys ["type", "program", "retriever", "query_field", "context_field", "k", "hops"]
  @program_of_thought_required_keys ["type", "signature", "predict", "output_field"]
  @artifact_type "imp_program_artifact"
  @artifact_schema_version 1
  @registry_context_key {__MODULE__, :registry}

  @doc """
  Writes `program` to `path` as a checksummed JSON artifact, readable with
  `read!/2`. The file is written atomically with mode `0600` and carries no
  credentials. Takes the same `:registry` option as `dump/2`.
  """
  @spec save!(struct(), Path.t(), keyword()) :: :ok
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
    io = File.open!(temporary, [:write, :binary, :exclusive])

    try do
      File.chmod!(temporary, 0o600)
      :ok = IO.binwrite(io, Jason.encode!(artifact, pretty: true) <> "\n")
      :ok = :file.sync(io)
    after
      File.close(io)
    end

    try do
      File.rename!(temporary, path)
      :ok
    after
      File.rm(temporary)
    end
  end

  @doc """
  Reads a program artifact written by `save!/3` and returns the program.

  The artifact's checksum is verified before anything in it is loaded. Raises
  `File.Error` when the file cannot be read and `ArgumentError` when it is not
  a checksummed Imp artifact or its program cannot be loaded. Takes the same
  `:registry` option as `load/2`.
  """
  @spec read!(Path.t(), keyword()) :: struct()
  def read!(path, opts \\ []) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> then(&with_registry(opts, fn -> load_artifact!(&1) end))
  end

  @doc """
  Returns `program` as a JSON-safe map that `load/2` turns back into it.

  Credentials are left out. A program that holds callbacks (metrics, tool
  runners, policies) is dumped by their names in the `:registry`, an
  `Imp.Saving.Registry`.
  """
  @spec dump(struct(), keyword()) :: map()
  def dump(program, opts) do
    with_registry(opts, fn -> dump(program) end)
  end

  @doc "Same as `dump(program, [])`."
  @spec dump(struct()) :: map()
  def dump(program) do
    program
    |> dump_state()
    |> redact_dump()
  end

  @doc """
  Loads a program from the portable map `dump/2` returns.

  Returns `{:ok, program}`, or `{:error, %ArgumentError{}}` when `state` is not
  a program Imp can load: a missing or unknown `"type"`, a malformed field, an
  adapter or client outside the allowlist, or a callback name the `:registry`
  does not hold. Nothing in `state` is turned into an atom that does not
  already exist, and no credential is read from it.

  Options:

    * `:registry` - an `Imp.Saving.Registry` naming the callbacks a saved
      program refers to (metrics, tool runners, policies).
  """
  @spec load(map(), keyword()) :: {:ok, struct()} | {:error, Exception.t()}
  def load(state, opts \\ []) do
    {:ok, load!(state, opts)}
  rescue
    error in ArgumentError -> {:error, error}
  end

  @doc """
  Loads a program from the portable map `dump/2` returns, raising
  `ArgumentError` where `load/2` returns an error.
  """
  @spec load!(map(), keyword()) :: struct()
  def load!(state, opts \\ []) do
    with_registry(opts, fn -> load_state!(state) end)
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
      raise ArgumentError, "saved Imp artifact payload checksum mismatch"
    end

    load_state!(payload)
  end

  defp load_artifact!(%{"artifact_type" => @artifact_type, "schema_version" => version}) do
    raise ArgumentError, "unsupported saved Imp artifact schema version: #{inspect(version)}"
  end

  defp load_artifact!(_state) do
    raise ArgumentError, "saved Imp file is not a checksummed program artifact envelope"
  end

  defp dump_state(%Imp.Predict{} = program) do
    program
    |> Imp.Predict.dump()
    |> Map.update!("config", &dump_portable_config!(&1, "Predict config"))
    |> Map.put("type", "predict")
  end

  defp dump_state(%Imp.Playbook.WithContext{} = wrapper) do
    %{
      "type" => "with_playbook",
      "program" => dump(wrapper.program),
      "playbook" => Imp.Playbook.dump(wrapper.playbook)
    }
  end

  defp dump_state(%Imp.Predict.ChainOfThought{predict: predict}) do
    predict |> dump() |> Map.put("type", "chain_of_thought")
  end

  defp dump_state(%Imp.Predict.RAG{} = rag) do
    %{
      "type" => "rag",
      "program" => dump(rag.program),
      "retriever" => dump_retriever(rag.retriever),
      "query_field" => Imp.Optimizer.Report.encode_term(rag.query_field),
      "context_field" => Imp.Optimizer.Report.encode_term(rag.context_field),
      "k" => rag.k,
      "hops" => rag.hops
    }
  end

  defp dump_state(%Imp.Predict.ProgramOfThought{} = pot) do
    %{
      "type" => "program_of_thought",
      "signature" => Imp.Signature.dump(pot.signature),
      "predict" => dump(pot.predict),
      "output_field" => Imp.Optimizer.Report.encode_term(pot.output_field)
    }
  end

  defp dump_state(%Imp.Predict.MultiChainComparison{} = comparison) do
    %{
      "type" => "multi_chain_comparison",
      "predict" => dump(comparison.predict),
      "last_key" => Imp.Optimizer.Report.encode_term(comparison.last_key),
      "m" => comparison.m
    }
  end

  defp dump_state(%Imp.Predict.KNN{} = knn) do
    %{
      "type" => "knn",
      "examples" => Imp.Optimizer.Report.encode_term(knn.trainset),
      "k" => knn.k,
      "vectorizer" => dump_vectorizer!(knn.vectorizer)
    }
  end

  defp dump_state(%Imp.Predict.Avatar{} = avatar) do
    state = %{
      "type" => "avatar",
      "signature" => dump_portable_signature!(avatar.signature, "Avatar signature"),
      "actor" => dump_avatar_predict(avatar.actor, "Avatar actor"),
      "finisher" => dump_avatar_predict(avatar.finisher, "Avatar finisher"),
      "tools" => dump_avatar_tools(avatar.tools),
      "max_iters" => avatar.max_iters,
      "tool_timeout_ms" => avatar.tool_timeout_ms,
      "tool_policy" => dump_tool_policy(avatar.tool_policy, "Avatar tool policy"),
      "metadata" => dump_portable_value!(avatar.metadata, "Avatar metadata")
    }

    require_portable_json!(state, "Avatar")
  end

  defp dump_state(%Imp.Predict.BestOfN{} = best) do
    %{
      "type" => "best_of_n",
      "program" => dump(best.program),
      "metric" => dump_callback!(best.metric, "BestOfN metric"),
      "feedback" => dump_optional_callback(best.feedback_fn, "BestOfN feedback"),
      "n" => best.n,
      "threshold" => best.threshold
    }
  end

  defp dump_state(%Imp.Predict.Refine{} = refine) do
    %{
      "type" => "refine",
      "program" => dump(refine.program),
      "metric" => dump_callback!(refine.metric, "Refine metric"),
      "feedback" => dump_optional_callback(refine.feedback_fn, "Refine feedback"),
      "n" => refine.n,
      "threshold" => refine.threshold,
      "fail_count" => refine.fail_count
    }
  end

  defp dump_state(%Imp.Predict.Assertions{} = assertions) do
    %{
      "type" => "assertions",
      "program" => dump(assertions.program),
      "assertions" =>
        Enum.map(assertions.assertions, fn assertion ->
          %{
            "name" => Imp.Optimizer.Report.encode_term(assertion.name),
            "predicate" => dump_callback!(assertion.predicate, "assertion predicate"),
            "message" => assertion.message
          }
        end),
      "max_attempts" => assertions.max_attempts,
      "strict" => assertions.strict
    }
  end

  defp dump_state(%Imp.Predict.ReAct{} = react) do
    reserved = Imp.Predict.ReAct.reserved_tool_name(react.mode)

    %{
      "type" => "react",
      "signature" => Imp.Signature.dump(react.signature),
      "react" => dump(react.react),
      "tools" => dump_tools(Map.delete(react.tools, reserved), "ReAct"),
      "max_iters" => react.max_iters,
      "mode" => dump_react_mode!(react.mode),
      "tool_policy" => dump_tool_policy(react.tool_policy, "ReAct tool policy")
    }
  end

  defp dump_state(%Imp.Predict.ReActV2{} = react) do
    %{
      "type" => "react_v2",
      "signature" => Imp.Signature.dump(react.signature),
      "react" => dump(react.react),
      "tools" => dump_tools(Map.delete(react.tools, :submit), "ReActV2"),
      "max_iters" => react.max_iters,
      "last_request_note" => react.last_request_note,
      "finish_on" => dump_finish_on(react.finish_on),
      "tool_policy" => dump_tool_policy(react.tool_policy, "ReActV2 tool policy")
    }
  end

  defp dump_state(%Imp.Predict.CodeAct{} = code_act) do
    %{
      "type" => "code_act",
      "program_of_thought" => dump(code_act.program_of_thought),
      "tools" => dump_tools(code_act.tools, "CodeAct"),
      "max_iters" => code_act.max_iters,
      "tool_policy" => dump_tool_policy(code_act.tool_policy, "CodeAct tool policy")
    }
  end

  defp dump_state(%Imp.Predict.RLM{} = rlm) do
    %{
      "type" => "rlm",
      "signature" => Imp.Signature.dump(rlm.signature),
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

  defp dump_state(%Imp.Evaluate.SemanticF1{} = evaluator) do
    %{
      "type" => "semantic_f1",
      "predict" => dump(evaluator.predict),
      "threshold" => evaluator.threshold,
      "decompositional" => evaluator.decompositional
    }
  end

  defp dump_state(%Imp.Evaluate.CompleteAndGrounded{predict: predict})
       when not is_nil(predict) do
    %{"type" => "complete_and_grounded", "predict" => dump(predict)}
  end

  defp dump_state(%Imp.Evaluate.CompleteAndGrounded{} = evaluator) do
    %{
      "type" => "complete_and_grounded_v2",
      "completeness" => dump(evaluator.completeness),
      "groundedness" => dump(evaluator.groundedness),
      "threshold" => evaluator.threshold
    }
  end

  defp dump_state(%Imp.Optimizer.KNNFewShot.Program{} = program) do
    %{
      "type" => "knn_few_shot_program",
      "student" => dump(program.student),
      "knn" => dump(program.optimizer.knn),
      "teacher" => if(program.teacher, do: dump(program.teacher)),
      "bootstrap" => dump_knn_bootstrap!(program.optimizer.bootstrap)
    }
  end

  defp dump_state(%Imp.Optimizer.Ensemble.Program{} = program) do
    %{
      "type" => "ensemble_program",
      "programs" => Enum.map(program.programs, &dump/1),
      "reduce_fn" => dump_optional_callback(program.ensemble.reduce_fn, "Ensemble reducer"),
      "size" => program.ensemble.size,
      "deterministic" => program.ensemble.deterministic,
      "seed" => program.ensemble.seed
    }
  end

  defp dump_state(%Imp.Optimizer.Artifact.ParameterSnapshot{} = snapshot) do
    %{
      "type" => "optimizer_parameter_snapshot",
      "predictors" =>
        Enum.map(snapshot.predictors, fn %{name: name, predictor: predictor} ->
          %{
            "name" => encode_parameter_name!(name),
            "predictor" => dump(predictor)
          }
        end)
    }
  end

  defp dump_state(%Trajectory{} = trajectory), do: Trajectory.dump(trajectory)

  defp dump_state(program) do
    raise ArgumentError,
          "unsupported Imp program for saving: #{inspect(program_name(program))}; " <>
            "portable saving supports data-only program graphs; callback-bearing programs require named registries"
  end

  defp load_state!(%{"type" => "predict"} = state) do
    require_keys!(state, @predict_required_keys)
    signature = Map.fetch!(state, "signature")
    demos = require_list!(state, "demos")
    config = Map.fetch!(state, "config")

    metadata =
      state
      |> require_map!("metadata")
      |> decode_predict_metadata()

    opts =
      [
        demos: Enum.map(demos, &load_demo!/1),
        config: decode_config(config),
        metadata: metadata
      ]
      |> maybe_put_adapter(state)
      |> maybe_put_lm(state)

    Imp.Predict.new(Imp.Signature.load!(signature), opts)
  end

  defp load_state!(%{"type" => "with_playbook"} = state) do
    require_keys!(state, ["type", "program", "playbook"])

    Imp.Playbook.WithContext.new(
      load_state!(Map.fetch!(state, "program")),
      Imp.Playbook.load!(Map.fetch!(state, "playbook"))
    )
  end

  defp load_state!(%{"type" => "chain_of_thought"} = state) do
    predict = state |> Map.put("type", "predict") |> load_state!()
    %Imp.Predict.ChainOfThought{predict: predict}
  end

  defp load_state!(%{"type" => "rag"} = state) do
    require_keys!(state, @rag_required_keys)

    Imp.Predict.RAG.new(
      load_state!(Map.fetch!(state, "program")),
      load_retriever!(Map.fetch!(state, "retriever")),
      query_field: Imp.Optimizer.Report.decode_term(Map.fetch!(state, "query_field")),
      context_field: Imp.Optimizer.Report.decode_term(Map.fetch!(state, "context_field")),
      k: Map.fetch!(state, "k"),
      hops: Map.fetch!(state, "hops")
    )
  end

  defp load_state!(%{"type" => "program_of_thought"} = state) do
    require_keys!(state, @program_of_thought_required_keys)
    signature = Imp.Signature.load!(Map.fetch!(state, "signature"))
    predict = load_state!(Map.fetch!(state, "predict"))
    output_field = Imp.Optimizer.Report.decode_term(Map.fetch!(state, "output_field"))

    %Imp.Predict.ProgramOfThought{
      signature: signature,
      predict: validate_program_of_thought_predict!(signature, predict),
      output_field: validate_program_of_thought_output_field!(signature, output_field)
    }
  end

  defp load_state!(%{"type" => "multi_chain_comparison"} = state) do
    require_keys!(state, ["type", "predict", "last_key", "m"])
    predict = load_state!(Map.fetch!(state, "predict"))
    last_key = Imp.Optimizer.Report.decode_term(Map.fetch!(state, "last_key"))
    m = Map.fetch!(state, "m")

    unless match?(%Imp.Predict{}, predict) and is_integer(m) and m > 0 and
             last_key in Imp.Signature.output_names(predict.signature) do
      raise ArgumentError, "invalid saved MultiChainComparison program state"
    end

    %Imp.Predict.MultiChainComparison{predict: predict, last_key: last_key, m: m}
  end

  defp load_state!(%{"type" => "knn"} = state) do
    require_keys!(state, ["type", "examples", "k", "vectorizer"])
    examples = Imp.Optimizer.Report.decode_term(Map.fetch!(state, "examples"))
    vectorizer = load_vectorizer!(Map.fetch!(state, "vectorizer"))
    # Re-embeds the trainset at load: the stored artifact carries the corpus
    # (examples) and the derivation (vectorizer), never stale vectors.
    Imp.Predict.KNN.new(Map.fetch!(state, "k"), examples, vectorizer: vectorizer)
  end

  defp load_state!(%{"type" => "avatar"} = state) do
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

    signature = Imp.Signature.load!(state["signature"])
    actor = require_predict!(load_state!(state["actor"]), "Avatar actor")
    finisher = require_predict!(load_state!(state["finisher"]), "Avatar finisher")
    tools = load_tools!(state["tools"], "Avatar")
    max_iters = require_non_negative_integer!(state["max_iters"], "Avatar max_iters")

    tool_timeout_ms =
      state
      |> Map.get("tool_timeout_ms", 30_000)
      |> require_non_negative_integer!("Avatar tool_timeout_ms")

    tool_policy = load_tool_policy!(state["tool_policy"], "Avatar tool policy")

    metadata =
      state
      |> Map.get("metadata", %{})
      |> Imp.Optimizer.Report.decode_term()
      |> require_map_value!("Avatar metadata")

    validate_avatar_predicts!(signature, actor, finisher)

    %Imp.Predict.Avatar{
      signature: signature,
      actor: actor,
      finisher: finisher,
      tools: tools,
      max_iters: max_iters,
      tool_timeout_ms: tool_timeout_ms,
      tool_policy: tool_policy,
      metadata: metadata
    }
  end

  defp load_state!(%{"type" => "best_of_n"} = state) do
    require_keys!(state, ["type", "program", "metric", "feedback", "n", "threshold"])

    Imp.Predict.BestOfN.new(
      load_state!(Map.fetch!(state, "program")),
      load_callback!(Map.fetch!(state, "metric"), 2, "BestOfN metric"),
      n: require_non_negative_integer!(Map.fetch!(state, "n"), "BestOfN n"),
      threshold: require_threshold!(Map.fetch!(state, "threshold"), "BestOfN threshold"),
      feedback_fn: load_optional_callback(state["feedback"], 1, "BestOfN feedback")
    )
  end

  defp load_state!(%{"type" => "refine"} = state) do
    # A Refine saved before 0.5.0 names its attempt count "max_attempts".
    state =
      case Map.pop(state, "max_attempts") do
        {nil, state} -> state
        {attempts, state} -> Map.put_new(state, "n", attempts)
      end

    require_keys!(state, ["type", "program", "metric", "feedback", "n", "threshold", "fail_count"])

    Imp.Predict.Refine.new(
      load_state!(Map.fetch!(state, "program")),
      load_callback!(Map.fetch!(state, "metric"), 2, "Refine metric"),
      n: require_non_negative_integer!(Map.fetch!(state, "n"), "Refine n"),
      threshold: require_threshold!(Map.fetch!(state, "threshold"), "Refine threshold"),
      fail_count:
        require_optional_non_negative_integer!(
          Map.fetch!(state, "fail_count"),
          "Refine fail_count"
        ),
      feedback_fn: load_optional_callback(state["feedback"], 1, "Refine feedback")
    )
  end

  defp load_state!(%{"type" => "assertions"} = state) do
    require_keys!(state, ["type", "program", "assertions", "max_attempts", "strict"])

    assertions =
      state
      |> require_list!("assertions")
      |> Enum.map(fn assertion ->
        require_keys!(assertion, ["name", "predicate", "message"])

        Imp.Assertion.new(
          Imp.Optimizer.Report.decode_term(assertion["name"]),
          load_callback!(assertion["predicate"], [1, 2], "assertion predicate"),
          message: assertion["message"]
        )
      end)

    Imp.Predict.Assertions.new(load_state!(state["program"]), assertions,
      max_attempts: state["max_attempts"],
      strict: state["strict"]
    )
  end

  defp load_state!(%{"type" => "react"} = state) do
    require_keys!(state, [
      "type",
      "signature",
      "react",
      "tools",
      "max_iters",
      "tool_policy",
      "mode"
    ])

    tools = load_tools!(state["tools"], "ReAct")
    mode = load_react_mode!(Map.fetch!(state, "mode"))
    signature = Imp.Signature.load!(state["signature"])
    reserved_name = Imp.Predict.ReAct.reserved_tool_name(mode)
    reserved = Imp.Predict.ReAct.reserved_tool(mode, signature)

    %Imp.Predict.ReAct{
      signature: signature,
      react: require_predict!(load_state!(state["react"]), "ReAct"),
      tools: Map.put(tools, reserved_name, reserved),
      max_iters: require_non_negative_integer!(state["max_iters"], "ReAct max_iters"),
      tool_policy: load_tool_policy!(state["tool_policy"], "ReAct tool policy"),
      mode: mode
    }
  end

  defp load_state!(%{"type" => "react_v2"} = state) do
    require_keys!(state, ["type", "signature", "react", "tools", "max_iters", "tool_policy"])
    tools = load_tools!(state["tools"], "ReActV2")
    signature = Imp.Signature.load!(state["signature"])

    %Imp.Predict.ReActV2{
      signature: signature,
      react: require_predict!(load_state!(state["react"]), "ReActV2"),
      tools: Imp.Predict.ReActV2.put_submit(tools, signature),
      max_iters: require_non_negative_integer!(state["max_iters"], "ReActV2 max_iters"),
      last_request_note: load_react_v2_last_request_note!(state["last_request_note"]),
      finish_on: load_finish_on!(state["finish_on"]),
      tool_policy: load_tool_policy!(state["tool_policy"], "ReActV2 tool policy")
    }
    |> Imp.Predict.ReActV2.restore_loop()
  end

  defp load_state!(%{"type" => "code_act"} = state) do
    require_keys!(state, [
      "type",
      "program_of_thought",
      "tools",
      "max_iters",
      "tool_policy"
    ])

    %Imp.Predict.CodeAct{
      program_of_thought: require_program_of_thought!(load_state!(state["program_of_thought"])),
      tools: load_tools!(state["tools"], "CodeAct"),
      max_iters: require_non_negative_integer!(state["max_iters"], "CodeAct max_iters"),
      tool_policy: load_tool_policy!(state["tool_policy"], "CodeAct tool policy")
    }
  end

  defp load_state!(%{"type" => "rlm"} = state) do
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
      "max_recursion_depth",
      "max_interpreter_steps",
      "max_interpreter_value_bytes",
      "max_interpreter_effects",
      "max_time_ms",
      "max_preview_chars",
      "max_observation_chars",
      "dynamic_lm",
      "dynamic_sub_lm",
      "dynamic_adapter"
    ])

    %Imp.Predict.RLM{
      signature: Imp.Signature.load!(state["signature"]),
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
          Map.fetch!(state, "max_recursion_depth"),
          "RLM max_recursion_depth"
        ),
      max_interpreter_steps:
        require_positive_integer!(
          Map.fetch!(state, "max_interpreter_steps"),
          "RLM max_interpreter_steps"
        ),
      max_interpreter_value_bytes:
        require_positive_integer!(
          Map.fetch!(state, "max_interpreter_value_bytes"),
          "RLM max_interpreter_value_bytes"
        ),
      max_interpreter_effects:
        require_positive_integer!(
          Map.fetch!(state, "max_interpreter_effects"),
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

  defp load_state!(%{"type" => "semantic_f1"} = state) do
    require_keys!(state, ["type", "predict", "threshold", "decompositional"])

    %Imp.Evaluate.SemanticF1{
      predict: require_chain_of_thought!(load_state!(state["predict"]), "SemanticF1"),
      threshold: require_threshold!(Map.fetch!(state, "threshold"), "SemanticF1 threshold"),
      decompositional: Map.fetch!(state, "decompositional") == true
    }
  end

  defp load_state!(%{"type" => "complete_and_grounded_v2"} = state) do
    require_keys!(state, ["type", "completeness", "groundedness", "threshold"])

    %Imp.Evaluate.CompleteAndGrounded{
      completeness:
        require_chain_of_thought!(
          load_state!(state["completeness"]),
          "CompleteAndGrounded completeness"
        ),
      groundedness:
        require_chain_of_thought!(
          load_state!(state["groundedness"]),
          "CompleteAndGrounded groundedness"
        ),
      threshold: require_threshold!(state["threshold"], "CompleteAndGrounded threshold")
    }
  end

  defp load_state!(%{"type" => "knn_few_shot_program"} = state) do
    require_keys!(state, ["type", "student", "knn", "teacher", "bootstrap"])
    knn = load_state!(state["knn"])

    unless match?(%Imp.Predict.KNN{}, knn) do
      raise ArgumentError, "saved KNNFewShot knn must be a KNN program"
    end

    bootstrap = Map.fetch!(state, "bootstrap")

    require_keys!(bootstrap, [
      "metric",
      "metric_threshold",
      "max_bootstrapped_demos",
      "max_labeled_demos",
      "max_rounds",
      "max_errors",
      "timeout"
    ])

    metric = load_optional_callback(bootstrap["metric"], [2, 3], "KNNFewShot bootstrap metric")

    %Imp.Optimizer.KNNFewShot.Program{
      student: load_state!(state["student"]),
      teacher: if(state["teacher"], do: load_state!(state["teacher"])),
      optimizer: %Imp.Optimizer.KNNFewShot{
        knn: knn,
        bootstrap:
          Imp.Optimizer.BootstrapFewShot.new(metric,
            metric_threshold: bootstrap["metric_threshold"],
            max_bootstrapped_demos: bootstrap["max_bootstrapped_demos"],
            max_labeled_demos: bootstrap["max_labeled_demos"],
            max_rounds: bootstrap["max_rounds"],
            max_errors: decode_infinity(bootstrap["max_errors"]),
            timeout: decode_infinity(bootstrap["timeout"])
          )
      }
    }
  end

  defp load_state!(%{"type" => "ensemble_program"} = state) do
    require_keys!(state, ["type", "programs", "reduce_fn", "size", "deterministic"])
    programs = require_list!(state, "programs") |> Enum.map(&load_state!/1)

    ensemble =
      Imp.Optimizer.Ensemble.new(
        reduce_fn: load_optional_callback(state["reduce_fn"], 1, "Ensemble reducer"),
        size: state["size"],
        deterministic: state["deterministic"],
        seed: Map.get(state, "seed", 0)
      )

    Imp.Optimizer.Ensemble.compile(ensemble, programs)
  end

  defp load_state!(%{"type" => "optimizer_parameter_snapshot"} = state) do
    exact_keys!(state, ["type", "predictors"], "saved optimizer parameter snapshot")

    entries =
      state
      |> require_list!("predictors")
      |> Enum.map(fn entry ->
        exact_keys!(entry, ["name", "predictor"], "saved optimizer parameter snapshot entry")

        name = decode_parameter_name!(entry["name"])
        predictor = load_parameter_predictor!(entry["predictor"])
        %{name: name, predictor: predictor}
      end)

    Imp.Optimizer.Artifact.ParameterSnapshot.new(entries)
  end

  defp load_state!(%{"type" => "imp_optimizer_trajectory"} = state), do: Trajectory.load!(state)

  defp load_state!(%{"type" => type}) do
    raise ArgumentError, "unsupported saved Imp program type: #{inspect(type)}"
  end

  defp load_state!(state) when is_map(state) do
    raise ArgumentError, "saved Imp program is missing required key \"type\""
  end

  defp load_state!(path) when is_binary(path) do
    raise ArgumentError,
          "a saved Imp program is the map Imp.dump/1 returns, got the string #{inspect(path)}; " <>
            "to read a file Imp.save!/2 wrote, use Imp.read!/1"
  end

  defp load_state!(state) do
    raise ArgumentError, "saved Imp program must be a map, got: #{inspect(state)}"
  end

  defp program_name(%module{}), do: module
  defp program_name(program), do: program

  defp with_registry(opts, fun) when is_list(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "Imp.Saving options must be a keyword list"
    end

    unknown = Keyword.keys(opts) -- [:registry]
    if unknown != [], do: raise(ArgumentError, "unknown Imp.Saving options: #{inspect(unknown)}")

    registry = Keyword.get(opts, :registry, %Imp.Saving.Registry{})

    unless match?(%Imp.Saving.Registry{}, registry) do
      raise ArgumentError, "Imp.Saving :registry must be an Imp.Saving.Registry"
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
    raise ArgumentError, "Imp.Saving options must be a keyword list, got: #{inspect(opts)}"
  end

  defp registry, do: Process.get(@registry_context_key, %Imp.Saving.Registry{})

  defp dump_callback!(callback, context),
    do: Imp.Saving.Registry.key_for!(registry(), callback, context)

  defp load_callback!(name, arities, context),
    do: Imp.Saving.Registry.fetch!(registry(), name, arities, context)

  defp dump_optional_callback(nil, _context), do: nil
  defp dump_optional_callback(callback, context), do: dump_callback!(callback, context)

  # KNNFewShot's per-call BootstrapFewShot arguments. Teacher settings can carry
  # a live LM handle, so a non-empty `teacher_settings` raises rather than
  # dumping an artifact whose optimizer behavior has quietly changed.
  defp dump_knn_bootstrap!(%Imp.Optimizer.BootstrapFewShot{} = bootstrap) do
    unless bootstrap.teacher_settings == [] do
      raise ArgumentError,
            "saved KNNFewShot bootstrap teacher_settings are not portable; " <>
              "got: #{inspect(bootstrap.teacher_settings)}"
    end

    %{
      "metric" => dump_optional_callback(bootstrap.metric, "KNNFewShot bootstrap metric"),
      "metric_threshold" => bootstrap.metric_threshold,
      "max_bootstrapped_demos" => bootstrap.max_bootstrapped_demos,
      "max_labeled_demos" => bootstrap.max_labeled_demos,
      "max_rounds" => bootstrap.max_rounds,
      "max_errors" => encode_infinity(bootstrap.max_errors),
      "timeout" => encode_infinity(bootstrap.timeout)
    }
  end

  defp encode_infinity(:infinity), do: "infinity"
  defp encode_infinity(value), do: value

  defp decode_infinity("infinity"), do: :infinity
  defp decode_infinity(value), do: value

  # The KNN vectorizer is either an Imp.Embeddings provider module (portable by
  # name, revalidated at load) or a function (portable only through the
  # named-callback registry, like every other persisted callback).
  defp dump_vectorizer!(module) when is_atom(module),
    do: %{"kind" => "module", "name" => Atom.to_string(module)}

  defp dump_vectorizer!(fun) when is_function(fun, 2),
    do: %{"kind" => "callback", "name" => dump_callback!(fun, "KNN vectorizer")}

  defp load_vectorizer!(%{"kind" => "module", "name" => name}) when is_binary(name) do
    module =
      try do
        String.to_existing_atom(name)
      rescue
        ArgumentError ->
          reraise ArgumentError,
                  [message: "saved KNN vectorizer references unknown module #{inspect(name)}"],
                  __STACKTRACE__
      end

    case Imp.Predict.KNN.validate_vectorizer(module) do
      {:ok, module} ->
        module

      {:error, message} ->
        raise ArgumentError, "saved KNN vectorizer #{inspect(name)}: #{message}"
    end
  end

  defp load_vectorizer!(%{"kind" => "callback", "name" => name}),
    do: load_callback!(name, [2], "KNN vectorizer")

  defp load_vectorizer!(state) do
    raise ArgumentError, "invalid saved KNN vectorizer state: #{inspect(state)}"
  end

  defp load_optional_callback(nil, _arities, _context), do: nil

  defp load_optional_callback(name, arities, context),
    do: load_callback!(name, arities, context)

  defp dump_avatar_predict(%Imp.Predict{} = predict, context) do
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
    entries
    |> Imp.Redaction.drop_credentials()
    |> Imp.Redaction.drop_headers()
    |> Enum.map(fn
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
    |> Imp.Redaction.redact()
    |> Imp.Optimizer.Report.encode_term()
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
    validated = playbook |> Imp.Playbook.load!() |> Imp.Playbook.dump()
    %{"type" => "with_playbook", "program" => redact_dump(program), "playbook" => validated}
  end

  defp redact_dump(%{"type" => "with_playbook"}) do
    raise ArgumentError, "portable playbook persistence requires reject_secrets: true"
  end

  defp redact_dump(%{"__imp_type__" => "map", "entries" => entries} = value)
       when is_list(entries) do
    entries =
      Enum.map(entries, fn
        [encoded_key, nested] ->
          case json_safe_key_name(encoded_key) do
            {:ok, key} when is_atom(key) or is_binary(key) ->
              if Imp.Redaction.credential_entry?(key, nested),
                do: [encoded_key, "[REDACTED]"],
                else: [redact_dump(encoded_key), redact_dump(nested)]

            :error ->
              [redact_dump(encoded_key), redact_dump(nested)]
          end

        nested ->
          redact_dump(nested)
      end)

    Map.put(value, "entries", entries)
  end

  defp redact_dump(%{provider: :req_llm, model: _model} = value) do
    value
    |> Imp.Redaction.drop_credentials()
    |> Map.new(fn
      {:model, nested} -> {:model, redact_req_llm_model(nested)}
      {key, nested} -> redact_req_llm_entry(key, nested)
    end)
  end

  defp redact_dump(%{"provider" => provider, "model" => _model} = value)
       when provider in ["req_llm", :req_llm] do
    value
    |> Imp.Redaction.drop_credentials()
    |> Map.new(fn
      {"model", nested} -> {"model", redact_req_llm_model(nested)}
      {key, nested} -> redact_req_llm_entry(key, nested)
    end)
  end

  defp redact_dump(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      cond do
        Imp.Redaction.credential_entry?(key, nested) -> {key, "[REDACTED]"}
        true -> {key, redact_dump(nested)}
      end
    end)
  end

  defp redact_dump([key, value]) when is_atom(key) or is_binary(key) or is_map(key) do
    if Imp.Redaction.credential_entry?(key, value),
      do: [key, "[REDACTED]"],
      else: [key, redact_dump(value)]
  end

  defp redact_dump(value) when is_list(value), do: Enum.map(value, &redact_dump/1)

  defp redact_dump({key, value}) when is_atom(key) or is_binary(key) do
    if Imp.Redaction.credential_entry?(key, value),
      do: [key, "[REDACTED]"],
      else: [key, redact_dump(value)]
  end

  defp redact_dump(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&redact_dump/1)
  end

  defp redact_dump(value) when is_binary(value), do: Imp.Redaction.redact(value, [])
  defp redact_dump(value), do: value

  defp redact_req_llm_model(model) when is_binary(model), do: model

  defp redact_req_llm_model(model) when is_map(model) do
    model
    |> Imp.Redaction.drop_credentials()
    |> Map.new(fn {key, value} ->
      normalized = key |> to_string() |> String.downcase()

      cond do
        normalized in ["id", "model"] and is_binary(value) -> {key, value}
        true -> {key, redact_dump(value)}
      end
    end)
  end

  defp redact_req_llm_model(model), do: redact_dump(model)

  defp redact_req_llm_entry(key, value) do
    if Imp.Redaction.credential_entry?(key, value),
      do: {key, "[REDACTED]"},
      else: {key, redact_dump(value)}
  end

  defp json_safe_key_name(%{"__imp_type__" => "atom", "value" => value})
       when is_binary(value),
       do: {:ok, value}

  defp json_safe_key_name(value) when is_binary(value), do: {:ok, value}
  defp json_safe_key_name(_value), do: :error

  defp dump_portable_signature!(signature, context) do
    signature
    |> Imp.Signature.dump()
    |> Imp.Redaction.redact([])
    |> require_portable_json!(context)
  end

  defp dump_avatar_tools(tools) do
    tools
    |> dump_tools("Avatar")
    |> Enum.map(fn tool ->
      tool
      |> Map.update!("description", &Imp.Redaction.redact(&1, []))
      |> Map.update!("schema", &Imp.Redaction.redact/1)
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
        "name" => Imp.Optimizer.Report.encode_term(tool.name),
        "description" => tool.description,
        "schema" => Imp.Optimizer.Report.encode_term(tool.schema),
        "runner" => dump_callback!(tool.run, "#{context} tool #{tool.name}")
      }
    end)
  end

  defp load_tools!(states, context) when is_list(states) do
    states
    |> Enum.map(fn state ->
      require_keys!(state, ["name", "description", "schema", "runner"])
      name = Imp.Optimizer.Report.decode_term(state["name"])

      Imp.Tool.new(
        name,
        state["description"],
        load_callback!(state["runner"], 1, "#{context} tool #{name}"),
        schema: Imp.Optimizer.Report.decode_term(state["schema"])
      )
    end)
    |> Imp.Tool.index_tools!("saved #{context}")
  end

  defp load_tools!(states, context) do
    raise ArgumentError, "saved #{context} tools must be a list, got: #{inspect(states)}"
  end

  defp dump_tool_policy(policy, _context) when not is_function(policy),
    do: Imp.Optimizer.Report.encode_term(policy)

  defp dump_tool_policy(policy, context),
    do: %{"registry_callback" => dump_callback!(policy, context)}

  defp load_tool_policy!(%{"registry_callback" => name}, context),
    do: load_callback!(name, 2, context)

  defp load_tool_policy!(policy, context) do
    policy = Imp.Optimizer.Report.decode_term(policy)

    case Imp.ToolPolicy.validate(policy) do
      {:ok, policy} -> policy
      {:error, message} -> raise ArgumentError, "invalid saved #{context}: #{message}"
    end
  end

  # A terminal tool's decision function is host code, so it persists the way a
  # tool runner and a tool policy do: by registry name, not by value.
  defp dump_finish_on(finish_on),
    do: Map.new(finish_on, fn {name, fun} -> {name, dump_callback!(fun, "ReActV2 finish_on")} end)

  defp load_finish_on!(nil), do: %{}

  defp load_finish_on!(finish_on) when is_map(finish_on),
    do:
      Map.new(finish_on, fn {name, key} ->
        {name, load_callback!(key, 3, "ReActV2 finish_on")}
      end)

  defp load_finish_on!(other),
    do: raise(ArgumentError, "invalid saved ReActV2 finish_on: #{inspect(other)}")

  defp load_react_v2_last_request_note!(nil), do: nil
  defp load_react_v2_last_request_note!(note) when is_binary(note), do: note

  defp load_react_v2_last_request_note!(other),
    do: raise(ArgumentError, "invalid saved ReActV2 last_request_note: #{inspect(other)}")

  defp dump_react_mode!(:provider_native), do: "provider_native"
  defp dump_react_mode!(:dspy), do: "dspy"

  defp dump_react_mode!(mode) do
    raise ArgumentError, "unsupported ReAct mode for persistence: #{inspect(mode)}"
  end

  defp load_react_mode!("provider_native"), do: :provider_native
  defp load_react_mode!("dspy"), do: :dspy
  # The mode's name before 0.5.0, still in programs saved then.
  defp load_react_mode!("dspy_3_2_1"), do: :dspy

  defp load_react_mode!(mode) do
    raise ArgumentError, "invalid saved ReAct mode: #{inspect(mode)}"
  end

  @doc false
  # Shared by every dumping program (Predict, RLM, ...): a pinned
  # (`dynamic?: false`) LM that cannot be serialized raises here and never dumps
  # as nil, because a `{"dynamic_lm" => false, "lm" => nil}` artifact would load
  # as a dynamic program that silently answers with the global LM.
  def dump_portable_lm(nil, true, _context), do: nil

  def dump_portable_lm(%Imp.Clients.ReqLLM{} = lm, _dynamic?, _context),
    do: Imp.Clients.ReqLLM.dump(lm)

  def dump_portable_lm(lm, false, context) do
    raise ArgumentError,
          "#{context} is not portable; pin ReqLLM or use dynamic settings, got: #{inspect(program_name(lm))}"
  end

  def dump_portable_lm(_lm, true, _context), do: nil

  defp dump_adapter(_adapter, true), do: nil
  defp dump_adapter(adapter, false) when is_atom(adapter), do: Atom.to_string(adapter)

  defp require_predict!(%Imp.Predict{} = predict, _context), do: predict

  defp require_predict!(program, context),
    do:
      raise(
        ArgumentError,
        "saved #{context} nested program must be Predict, got: #{inspect(program_name(program))}"
      )

  defp validate_avatar_predicts!(signature, actor, finisher) do
    expected = Imp.Predict.Avatar.new(signature, [])
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
    left |> Imp.Signature.dump() |> json_normalize!() ==
      right |> Imp.Signature.dump() |> json_normalize!()
  end

  defp require_program_of_thought!(%Imp.Predict.ProgramOfThought{} = program), do: program

  defp require_program_of_thought!(program),
    do:
      raise(
        ArgumentError,
        "saved CodeAct nested program must be ProgramOfThought, got: #{inspect(program_name(program))}"
      )

  defp require_chain_of_thought!(%Imp.Predict.ChainOfThought{} = program, _context),
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
    config
    |> Imp.Redaction.drop_credentials()
    |> Enum.map(fn
      {k, v} -> {decode_config_key(k), decode_config_value(k, v)}
      [k, v] -> {decode_config_key(k), decode_config_value(k, v)}
      other -> raise ArgumentError, "invalid saved Imp config entry: #{inspect(other)}"
    end)
  end

  defp decode_config(config) when is_map(config) do
    config
    |> Imp.Redaction.drop_credentials()
    |> Enum.map(fn {k, v} -> {decode_config_key(k), decode_config_value(k, v)} end)
  end

  defp decode_config(config) do
    raise ArgumentError, "saved Imp config must be a map or list, got: #{inspect(config)}"
  end

  defp decode_config_value(key, value)
       when key in [:provider_options, "provider_options"] and is_list(value),
       do: decode_config(value)

  defp decode_config_value(key, value)
       when key in [:headers, "headers"] and is_list(value) do
    value
    |> Imp.Redaction.drop_credentials()
    |> Enum.map(fn
      {header, header_value} -> {header, header_value}
      [header, header_value] -> {header, header_value}
      other -> raise ArgumentError, "invalid saved ReqLLM header: #{inspect(other)}"
    end)
  end

  defp decode_config_value(_key, value), do: value

  defp decode_predict_metadata(metadata) do
    # These tags are part of the supported TrainingJob.rebind/3 program
    # artifact. Decode only this explicit Saving-owned vocabulary before the
    # existing-atom-only generic decoder sees the remaining metadata.
    metadata
    |> decode_portable_predict_metadata_atoms()
    |> Imp.Optimizer.Report.decode_term()
  end

  defp decode_portable_predict_metadata_atoms(%{"__imp_type__" => "atom", "value" => value} = tag)
       when map_size(tag) == 2 and is_binary(value) do
    Map.get(@portable_predict_metadata_atoms, value, tag)
  end

  defp decode_portable_predict_metadata_atoms(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, decode_portable_predict_metadata_atoms(value)} end)
  end

  defp decode_portable_predict_metadata_atoms(list) when is_list(list),
    do: Enum.map(list, &decode_portable_predict_metadata_atoms/1)

  defp decode_portable_predict_metadata_atoms(value), do: value

  @req_llm_option_keys %{
    "temperature" => :temperature,
    "seed" => :seed,
    "max_tokens" => :max_tokens,
    "top_p" => :top_p,
    "stop" => :stop,
    "response_format" => :response_format,
    "tools" => :tools,
    "tool_choice" => :tool_choice,
    "parallel_tool_calls" => :parallel_tool_calls,
    "openai_parallel_tool_calls" => :openai_parallel_tool_calls,
    "stream" => :stream,
    "json_retries" => :json_retries,
    "json_fallback" => :json_fallback,
    "timeout" => :timeout,
    "retries" => :retries,
    "num_retries" => :num_retries,
    "retry_backoff_ms" => :retry_backoff_ms,
    "max_retries" => :max_retries,
    "max_completion_tokens" => :max_completion_tokens,
    "receive_timeout" => :receive_timeout,
    "cache" => :cache,
    "rollout_id" => :rollout_id,
    "native_json_schema" => :native_json_schema,
    "provider_options" => :provider_options,
    "headers" => :headers,
    "base_url" => :base_url,
    "request_id" => :request_id,
    "input_envelope" => :input_envelope,
    "reasoning_effort" => :reasoning_effort,
    "openrouter_reasoning_wire" => :openrouter_reasoning_wire,
    "req_http_options" => :req_http_options
  }

  @req_http_option_keys %{
    "retry" => :retry,
    "max_retries" => :max_retries
  }

  defp decode_req_llm_opts(opts) when is_list(opts) do
    opts
    |> Imp.Redaction.drop_credentials()
    |> decode_allowlisted_entries!(@req_llm_option_keys, "saved ReqLLM options", fn key, value ->
      decode_req_llm_option_value!(key, value)
    end)
  end

  defp decode_req_llm_opts(opts) do
    raise ArgumentError, "saved ReqLLM options must be a list, got: #{inspect(opts)}"
  end

  defp decode_req_llm_option_value!(:max_retries, value),
    do: require_non_negative_integer!(value, "ReqLLM max_retries")

  defp decode_req_llm_option_value!(:seed, value),
    do: require_positive_integer!(value, "ReqLLM seed")

  defp decode_req_llm_option_value!(:req_http_options, value),
    do: decode_req_http_options!(value)

  defp decode_req_llm_option_value!(:input_envelope, value),
    do: decode_req_llm_input_envelope!(value)

  defp decode_req_llm_option_value!(:reasoning_effort, value),
    do: require_reasoning_effort!(value)

  defp decode_req_llm_option_value!(:openrouter_reasoning_wire, value)
       when value in ~w(top_level nested),
       do: String.to_atom(value)

  defp decode_req_llm_option_value!(:openrouter_reasoning_wire, value) do
    raise ArgumentError,
          "saved ReqLLM openrouter_reasoning_wire is unsupported: #{inspect(value)}"
  end

  defp decode_req_llm_option_value!(key, value), do: decode_config_value(key, value)

  defp decode_req_llm_input_envelope!(entries) when is_list(entries) do
    decoded =
      decode_allowlisted_entries!(
        entries,
        %{"max_bytes" => :max_bytes, "reservation_tokens" => :reservation_tokens},
        "saved ReqLLM input_envelope",
        fn key, value ->
          require_positive_integer!(value, "ReqLLM input_envelope #{key}")
        end
      )

    unless Keyword.has_key?(decoded, :max_bytes) do
      raise ArgumentError, "saved ReqLLM input_envelope requires max_bytes"
    end

    decoded
  end

  defp decode_req_llm_input_envelope!(value) do
    raise ArgumentError,
          "saved ReqLLM input_envelope must be a list, got: #{inspect(value)}"
  end

  defp require_reasoning_effort!(effort)
       when effort in ~w(none minimal low medium high xhigh default),
       do: effort

  defp require_reasoning_effort!(effort) do
    raise ArgumentError,
          "saved ReqLLM reasoning_effort is unsupported: #{inspect(effort)}"
  end

  defp decode_req_http_options!(options) when is_list(options) do
    decode_allowlisted_entries!(
      options,
      @req_http_option_keys,
      "saved ReqLLM req_http_options",
      &decode_req_http_option_value!/2
    )
  end

  defp decode_req_http_options!(options) do
    raise ArgumentError,
          "saved ReqLLM req_http_options must be a list, got: #{inspect(options)}"
  end

  defp decode_req_http_option_value!(:retry, value) when is_boolean(value), do: value

  defp decode_req_http_option_value!(:retry, value) do
    raise ArgumentError,
          "saved ReqLLM req_http_options retry must be a boolean, got: #{inspect(value)}"
  end

  defp decode_req_http_option_value!(:max_retries, value),
    do: require_non_negative_integer!(value, "ReqLLM req_http_options max_retries")

  defp decode_allowlisted_entries!(entries, allowlist, context, decode_value) do
    {decoded, seen} =
      Enum.map_reduce(entries, MapSet.new(), fn entry, seen ->
        {raw_key, value} = decode_saved_pair!(entry, context)
        key_name = if is_atom(raw_key), do: Atom.to_string(raw_key), else: raw_key

        unless is_binary(key_name) do
          raise ArgumentError, "#{context} key must be a string or atom, got: #{inspect(raw_key)}"
        end

        key =
          Map.get(allowlist, key_name) ||
            raise(ArgumentError, "unknown #{context} key: #{inspect(key_name)}")

        if MapSet.member?(seen, key) do
          raise ArgumentError, "duplicate #{context} key: #{inspect(key_name)}"
        end

        {{key, decode_value.(key, value)}, MapSet.put(seen, key)}
      end)

    _ = seen
    decoded
  end

  defp decode_saved_pair!({key, value}, _context), do: {key, value}
  defp decode_saved_pair!([key, value], _context), do: {key, value}

  defp decode_saved_pair!(entry, context) do
    raise ArgumentError, "invalid #{context} entry: #{inspect(entry)}"
  end

  defp decode_adapter(nil), do: Imp.Adapter.Chat

  defp decode_adapter(name) when is_binary(name) do
    case name do
      "Elixir.Imp.Adapter.Chat" -> Imp.Adapter.Chat
      "Elixir.Imp.Adapter.JSON" -> Imp.Adapter.JSON
      "Elixir.Imp.Adapter.XML" -> Imp.Adapter.XML
      "Elixir.Imp.Adapter.TwoStep" -> Imp.Adapter.TwoStep
      "Elixir.Imp.Adapter.PlanFirst" -> Imp.Adapter.PlanFirst
      "Elixir.Imp.Adapter.SingleField" -> Imp.Adapter.SingleField
      other -> raise ArgumentError, "unsupported saved Imp adapter: #{inspect(other)}"
    end
  end

  defp decode_adapter(adapter) do
    raise ArgumentError,
          "invalid saved Imp adapter reference: #{inspect(adapter)}; expected an allowlisted module name string"
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
          "unsupported saved Imp provider: #{inspect(provider)}; saved provider clients must use req_llm"
  end

  defp decode_lm(%{provider: provider}) do
    raise ArgumentError,
          "unsupported saved Imp provider: #{inspect(provider)}; saved provider clients must use req_llm"
  end

  defp decode_lm(lm) do
    raise ArgumentError, "invalid saved Imp LM client: #{inspect(lm)}"
  end

  defp decode_req_llm!(nil, _opts) do
    raise ArgumentError, "saved req_llm client is missing required model"
  end

  defp decode_req_llm!(model, opts) do
    model = Imp.Redaction.drop_credentials(model)
    Imp.Clients.ReqLLM.new(model, opts: decode_req_llm_opts(opts))
  end

  defp dump_retriever(%Imp.Retrieve.Memory{} = retriever) do
    %{
      "type" => "memory",
      "docs" => Imp.Optimizer.Report.encode_term(retriever.docs),
      "k" => retriever.k
    }
  end

  # The retriever is named, not printed: a retriever's struct can carry a
  # bearer token.
  defp dump_retriever(retriever) do
    raise ArgumentError,
          "unsupported saved Imp retriever: #{retriever_name(retriever)}; " <>
            "only Imp.Retrieve.Memory is portable"
  end

  defp retriever_name(%module{}), do: inspect(module)
  defp retriever_name(fun) when is_function(fun), do: "a function"
  defp retriever_name(module) when is_atom(module), do: inspect(module)
  defp retriever_name(_other), do: "a retriever that is not a struct"

  defp load_retriever!(%{"type" => "memory"} = state) do
    Imp.Retrieve.Memory.new(
      state |> Map.fetch!("docs") |> Imp.Optimizer.Report.decode_term(),
      k: Map.fetch!(state, "k")
    )
  end

  defp load_retriever!(%{"type" => type}) do
    raise ArgumentError, "unsupported saved Imp retriever: #{inspect(type)}"
  end

  defp load_retriever!(retriever) do
    raise ArgumentError, "invalid saved Imp retriever: #{inspect(retriever)}"
  end

  defp validate_program_of_thought_predict!(
         %Imp.Signature{} = task_signature,
         %Imp.Predict{signature: planner_signature} = predict
       ) do
    cond do
      Imp.Signature.input_names(planner_signature) != Imp.Signature.input_names(task_signature) ->
        raise ArgumentError,
              "saved ProgramOfThought planner inputs must match task inputs"

      planner_signature.instructions != task_signature.instructions ->
        raise ArgumentError,
              "saved ProgramOfThought planner instructions must match task instructions"

      Imp.Signature.output_names(planner_signature) != [:program, :tool, :arguments] ->
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

  defp validate_program_of_thought_output_field!(%Imp.Signature{} = task_signature, output_field) do
    if Enum.any?(
         Imp.Signature.output_names(task_signature),
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
      "json_retries" -> :json_retries
      "json_fallback" -> :json_fallback
      "timeout" -> :timeout
      "retries" -> :retries
      "num_retries" -> :num_retries
      "retry_backoff_ms" -> :retry_backoff_ms
      "max_completion_tokens" -> :max_completion_tokens
      "receive_timeout" -> :receive_timeout
      "cache" -> :cache
      "rollout_id" -> :rollout_id
      "native_json_schema" -> :native_json_schema
      "provider_options" -> :provider_options
      "headers" -> :headers
      "base_url" -> :base_url
      "request_id" -> :request_id
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
              "saved Imp #{Map.get(state, "type", "program")} is missing required keys: #{inspect(missing)}"
    end
  end

  defp exact_keys!(state, keys, context) when is_map(state) do
    if MapSet.equal?(MapSet.new(Map.keys(state)), MapSet.new(keys)) do
      :ok
    else
      raise ArgumentError, "#{context} has unexpected or missing keys"
    end
  end

  defp exact_keys!(_state, _keys, context) do
    raise ArgumentError, "#{context} must be a map"
  end

  # Optimizer artifacts are an untrusted persistence boundary. Predictor names
  # are compared with the trusted live program during Artifact.apply/4, so the
  # wire representation stays a string and never interns an atom from bytes.
  # The tagged-atom clause accepts the schema-2 and schema-3 encodings without
  # depending on which atoms the loading VM happens to have interned.
  defp encode_parameter_name!(name) when is_atom(name), do: Atom.to_string(name)
  defp encode_parameter_name!(name) when is_binary(name), do: name

  defp decode_parameter_name!(name) when is_binary(name), do: name

  defp decode_parameter_name!(%{"__imp_type__" => "atom", "value" => name} = state)
       when is_binary(name) do
    exact_keys!(state, ["__imp_type__", "value"], "saved optimizer parameter name")
    name
  end

  defp decode_parameter_name!(name) do
    raise ArgumentError,
          "saved optimizer parameter name must be a string or legacy atom tag, got: #{inspect(name)}"
  end

  # Parameter snapshots cross the untrusted Artifact boundary. Unlike a normal
  # saved program, their identifier vocabulary is reconciled with a trusted
  # live program by Artifact.apply/4, so demos and metadata must not depend on
  # atoms already interned in the loading VM.
  defp load_parameter_predictor!(%{"type" => "predict"} = state) do
    require_keys!(state, @predict_required_keys)
    signature = Map.fetch!(state, "signature")
    demos = require_list!(state, "demos")
    config = Map.fetch!(state, "config")

    metadata =
      state
      |> require_map!("metadata")
      |> Imp.Optimizer.Report.decode_term_portable()

    opts =
      [
        demos: Enum.map(demos, &load_portable_demo!/1),
        config: decode_config(config),
        metadata: metadata
      ]
      |> maybe_put_adapter(state)
      |> maybe_put_lm(state)

    Imp.Predict.new(Imp.Signature.load!(signature), opts)
  end

  defp load_parameter_predictor!(state) do
    raise ArgumentError,
          "saved optimizer parameter predictor must be a Predict state, got: #{inspect(state)}"
  end

  defp require_list!(state, key) do
    case Map.fetch!(state, key) do
      value when is_list(value) -> value
      value -> raise ArgumentError, "saved Imp #{key} must be a list, got: #{inspect(value)}"
    end
  end

  defp require_map!(state, key) do
    case Map.fetch!(state, key) do
      value when is_map(value) -> value
      value -> raise ArgumentError, "saved Imp #{key} must be a map, got: #{inspect(value)}"
    end
  end

  defp load_demo!(%{"__imp_type__" => "example"} = demo) do
    case Imp.Optimizer.Report.decode_term(demo) do
      %Imp.Example{} = example ->
        example

      other ->
        raise ArgumentError, "saved Imp demo restored to invalid value: #{inspect(other)}"
    end
  end

  defp load_demo!(demo) when is_map(demo) or is_list(demo), do: Imp.Example.new(demo)

  defp load_demo!(demo) do
    raise ArgumentError, "saved Imp demo must be a map or keyword list, got: #{inspect(demo)}"
  end

  defp load_portable_demo!(%{"__imp_type__" => "example"} = demo) do
    case Imp.Optimizer.Report.decode_term_portable(demo) do
      %Imp.Example{} = example ->
        example

      other ->
        raise ArgumentError,
              "saved optimizer parameter demo restored to invalid value: #{inspect(other)}"
    end
  end

  defp load_portable_demo!(demo) when is_map(demo) or is_list(demo), do: Imp.Example.new(demo)

  defp load_portable_demo!(demo) do
    raise ArgumentError,
          "saved optimizer parameter demo must be a map or keyword list, got: #{inspect(demo)}"
  end
end
