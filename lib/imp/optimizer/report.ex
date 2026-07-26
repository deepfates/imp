defmodule Imp.Optimizer.Report do
  @moduledoc "Optimizer candidate history and diagnostic metadata."

  @image_schema_version 1
  @report_keys MapSet.new([
                 "optimizer",
                 "best_score",
                 "candidate_count",
                 "candidates",
                 "errors",
                 "metadata"
               ])
  @optimizer_report_tag_keys MapSet.put(@report_keys, "__imp_type__")
  @atom_tag_keys MapSet.new(["__imp_type__", "value"])
  @tuple_tag_keys MapSet.new(["__imp_type__", "items"])
  @improper_list_tag_keys MapSet.new(["__imp_type__", "heads", "tail"])
  @example_tag_keys MapSet.new(["__imp_type__", "fields", "input_keys", "demos"])
  @image_tag_keys MapSet.new([
                    "__imp_type__",
                    "schema_version",
                    "url",
                    "data",
                    "mime_type",
                    "metadata"
                  ])
  @map_tag_keys MapSet.new(["__imp_type__", "entries"])
  # Public optimizer identities are part of the portable Report contract. A
  # clean BEAM may not have loaded the owning optimizer module yet, so relying
  # only on binary_to_existing_atom/2 makes a valid saved report depend on
  # incidental module load order. Keep this vocabulary explicit; every other
  # atom still requires a caller/module-owned existing atom and no decoder path
  # creates atoms dynamically.
  @portable_optimizer_atoms %{
    # GEPA's selected-artifact report is part of the public portable lifecycle.
    # These are the stable keys and enum values emitted by that report. They
    # must not depend on which GEPA implementation modules happened to be
    # loaded before Artifact.read!/1 in a fresh VM.
    "acceptance_policy" => :acceptance_policy,
    "acceptance" => :acceptance,
    "accepted" => :accepted,
    "aggregations" => :aggregations,
    "all_improvements" => :all_improvements,
    "ancestors" => :ancestors,
    "avatar" => :avatar,
    # BootstrapFewShot marks generated demonstrations with this owned field.
    # Saved programs decode demos before the optimizer module is necessarily
    # loaded in a fresh OS process, so this portable marker cannot depend on
    # incidental module load order.
    "augmented" => :augmented,
    "better_together" => :better_together,
    "batch_controller" => :batch_controller,
    "bootstrap_few_shot" => :bootstrap_few_shot,
    "bootstrap_finetune" => :bootstrap_finetune,
    "copro" => :copro,
    "combee" => :combee,
    "candidate_id" => :candidate_id,
    "candidate_selection_strategy" => :candidate_selection_strategy,
    "component_feedback" => :component_feedback,
    "components" => :components,
    "descriptions" => :descriptions,
    "diagnostics" => :diagnostics,
    "dimension" => :dimension,
    "duplication_factor" => :duplication_factor,
    "effective_batch_size" => :effective_batch_size,
    "enabled" => :enabled,
    "engine" => :engine,
    "equal_or_better" => :equal_or_better,
    "evaluation_policy" => :evaluation_policy,
    "feedback" => :feedback,
    "failures" => :failures,
    "frontier_size" => :frontier_size,
    "frontier_type" => :frontier_type,
    "full" => :full,
    "full_evaluations" => :full_evaluations,
    "generations" => :generations,
    "generalization" => :generalization,
    "gepa" => :gepa,
    "hybrid" => :hybrid,
    "id" => :id,
    "identity" => :identity,
    "implementation" => :implementation,
    "infinity" => :infinity,
    "infer_rules" => :infer_rules,
    "instance" => :instance,
    "instruction" => :instruction,
    "instruction_search" => :instruction_search,
    "iteration" => :iteration,
    "labeled_few_shot" => :labeled_few_shot,
    "mipro_v2" => :mipro_v2,
    "max_concurrency" => :max_concurrency,
    "max_concurrency_requested" => :max_concurrency_requested,
    "max_full_evaluations" => :max_full_evaluations,
    "max_iterations" => :max_iterations,
    "max_metric_calls" => :max_metric_calls,
    "max_reflection_calls" => :max_reflection_calls,
    "max_reflection_cost" => :max_reflection_cost,
    "merge_acceptance_policy" => :merge_acceptance_policy,
    "merge_candidates" => :merge_candidates,
    "merges_accepted" => :merges_accepted,
    "metric_calls" => :metric_calls,
    "minibatch_candidate_score" => :minibatch_candidate_score,
    "minibatch_parent_score" => :minibatch_parent_score,
    "minibatch_size" => :minibatch_size,
    "mode" => :mode,
    "mutation" => :mutation,
    "parameters" => :parameters,
    "parent_ids" => :parent_ids,
    "parent_id" => :parent_id,
    "proposal_concurrency" => :proposal_concurrency,
    "proposal_timeout" => :proposal_timeout,
    "current_best" => :current_best,
    "pareto" => :pareto,
    "random_search" => :random_search,
    "reflection_calls" => :reflection_calls,
    "rejected_candidates" => :rejected_candidates,
    "sampling_strategy" => :sampling_strategy,
    "score" => :score,
    "selection" => :selection,
    "selection_strategy" => :selection_strategy,
    # Optimize Anything stores the adapter's evaluation envelope in public
    # candidate history. A fresh consumer may load Result before Adapter, so
    # this Imp-owned key cannot depend on Adapter's module load order.
    "side_info" => :side_info,
    "signature_optimizer" => :signature_optimizer,
    "simba" => :simba,
    "single" => :single,
    "status" => :status,
    "stop_reason" => :stop_reason,
    "strict_improvement" => :strict_improvement,
    "timeout" => :timeout,
    "timeout_requested" => :timeout_requested,
    "validation_ids" => :validation_ids,
    "validation_score" => :validation_score,
    "Elixir.Imp.Optimizer.GEPA" => Imp.Optimizer.GEPA,
    "Elixir.Imp.Optimizer.GEPA.Engine" => Imp.Optimizer.GEPA.Engine
  }
  @optimizer_modules %{
    avatar: Imp.Optimizer.Avatar,
    better_together: Imp.Optimizer.BetterTogether,
    bootstrap_few_shot: Imp.Optimizer.BootstrapFewShot,
    bootstrap_finetune: Imp.Optimizer.BootstrapFinetune,
    copro: Imp.Optimizer.COPRO,
    gepa: Imp.Optimizer.GEPA,
    infer_rules: Imp.Optimizer.InferRules,
    instruction_search: Imp.Optimizer.InstructionSearch,
    labeled_few_shot: Imp.Optimizer.LabeledFewShot,
    mipro_v2: Imp.Optimizer.MIPROv2,
    random_search: Imp.Optimizer.RandomSearch,
    signature_optimizer: Imp.Optimizer.SignatureOptimizer,
    simba: Imp.Optimizer.SIMBA
  }

  defstruct optimizer: nil,
            best_score: nil,
            candidate_count: 0,
            candidates: [],
            errors: [],
            metadata: %{}

  @doc """
  Builds an optimizer report from atom-key, string-key, or keyword attributes.

  String-key support is intentional: report data is often restored from JSON
  artifacts or provider/debug payloads before it is attached back to a program.
  Malformed attribute containers raise Imp-context errors instead of generic
  `Map.new/1` failures.
  """
  def new(attrs \\ %{}) do
    attrs = normalize_attrs!(attrs)

    %__MODULE__{
      optimizer: fetch(attrs, :optimizer),
      best_score: fetch(attrs, :best_score),
      candidate_count: fetch(attrs, :candidate_count, 0),
      candidates: fetch(attrs, :candidates, []),
      errors: fetch(attrs, :errors, []),
      metadata: fetch(attrs, :metadata, %{})
    }
  end

  defp normalize_attrs!(attrs) when is_map(attrs) or is_list(attrs) do
    {normalized, _keys} =
      Enum.reduce(attrs, {%{}, MapSet.new()}, fn
        {key, value}, {normalized, keys} when is_atom(key) or is_binary(key) ->
          canonical_key = encode_key(key)

          if MapSet.member?(keys, canonical_key) do
            raise ArgumentError,
                  "Imp.Optimizer.Report.new/1 received colliding attribute key #{inspect(canonical_key)}"
          end

          {Map.put(normalized, key, value), MapSet.put(keys, canonical_key)}

        invalid, _acc ->
          raise ArgumentError,
                "Imp.Optimizer.Report.new/1 expects attrs as atom or string keyed pairs; got entry: #{inspect(invalid)}"
      end)

    normalized
  end

  defp normalize_attrs!(attrs) do
    raise ArgumentError,
          "Imp.Optimizer.Report.new/1 expects a map or keyword list; got: #{inspect(attrs)}"
  end

  def dump(%__MODULE__{} = report) do
    %{
      "optimizer" => dump_value(report.optimizer),
      "best_score" => dump_value(report.best_score),
      "candidate_count" => dump_value(report.candidate_count),
      "candidates" => Enum.map(report.candidates, &dump_value/1),
      "errors" => Enum.map(report.errors, &dump_value/1),
      "metadata" => dump_value(report.metadata)
    }
    |> Imp.Redaction.redact()
  end

  def load(state) when is_map(state) do
    reject_canonical_key_collisions!(state, "optimizer report state")
    validate_report_keys!(state)

    candidates = fetch_required!(state, :candidates)
    errors = fetch_required!(state, :errors)

    unless is_list(candidates) and is_list(errors) do
      raise ArgumentError, "malformed optimizer report state"
    end

    optimizer = state |> fetch_required!(:optimizer) |> load_value()
    ensure_optimizer_runtime_loaded!(optimizer)
    best_score = state |> fetch_required!(:best_score) |> load_value()
    candidate_count = state |> fetch_required!(:candidate_count) |> load_value()
    metadata = state |> fetch_required!(:metadata) |> load_value()

    unless (is_nil(optimizer) or is_atom(optimizer) or is_binary(optimizer)) and
             (is_nil(best_score) or is_number(best_score)) and
             is_integer(candidate_count) and candidate_count >= 0 and is_map(metadata) do
      raise ArgumentError, "malformed optimizer report state"
    end

    new(%{
      optimizer: optimizer,
      best_score: best_score,
      candidate_count: candidate_count,
      candidates: Enum.map(candidates, &load_value/1),
      errors: Enum.map(errors, &load_value/1),
      metadata: metadata
    })
  end

  @doc """
  Encodes an Elixir term into Imp's lossless tagged JSON representation.

  This is a structural codec, not a logging boundary. Callers writing telemetry,
  reports, or user-visible artifacts should use `json_safe/1` instead.
  """
  def encode_term(value), do: dump_value(value)

  @doc "Decodes a value produced by `encode_term/1`."
  def decode_term(value), do: load_value(value)

  @doc "Returns a JSON-encodable projection with credential-bearing data redacted."
  def json_safe(value), do: value |> dump_value() |> Imp.Redaction.redact()

  @doc false
  def json_projection(value), do: value |> dump_projection() |> Imp.Redaction.redact()

  def attach(program, %__MODULE__{} = report) do
    attached = Imp.ProgramAccess.put_metadata(program, :optimizer_report, report)

    if Imp.ProgramAccess.get_metadata(attached, :optimizer_report) == report do
      attached
    else
      Enum.reduce(Imp.ProgramParameters.predictors(attached), attached, fn %{name: name}, acc ->
        Imp.ProgramParameters.update_predictor(acc, name, fn predictor ->
          Imp.ProgramAccess.put_metadata(predictor, :optimizer_report, report)
        end)
      end)
    end
  end

  def fetch(%_{} = program) do
    case Imp.ProgramAccess.get_metadata(program, :optimizer_report) do
      %__MODULE__{} = report ->
        report

      nil ->
        program
        |> Imp.ProgramParameters.predictors()
        |> Enum.map(&Imp.ProgramAccess.get_metadata(&1.predictor, :optimizer_report))
        |> Enum.reject(&is_nil/1)
        |> consistent_predictor_report!()
    end
  end

  def fetch(_program), do: nil

  defp consistent_predictor_report!([]), do: nil

  defp consistent_predictor_report!([%__MODULE__{} = report | rest]) do
    if Enum.all?(rest, &(&1 == report)) do
      report
    else
      raise ArgumentError, "program predictors carry conflicting optimizer reports"
    end
  end

  defp consistent_predictor_report!(_reports) do
    raise ArgumentError, "program predictors carry malformed optimizer reports"
  end

  # Metadata atom keys are owned by the optimizer that emitted the report. A
  # fresh BEAM may not have loaded that module's literal vocabulary yet. Load
  # only the explicit public allowlist; never derive a module or create an atom
  # from report data.
  defp ensure_optimizer_runtime_loaded!(optimizer) do
    case Map.fetch(@optimizer_modules, optimizer) do
      {:ok, module} ->
        case Code.ensure_loaded(module) do
          {:module, ^module} ->
            :ok

          {:error, reason} ->
            raise ArgumentError,
                  "cannot load #{inspect(optimizer)} report owner: #{inspect(reason)}"
        end

      :error ->
        :ok
    end
  end

  defp dump_value(%Imp.Example{} = example) do
    %{
      "__imp_type__" => "example",
      "fields" => dump_value(Imp.Example.to_map(example)),
      "input_keys" => dump_value(example.input_keys),
      "demos" => dump_value(example.demos)
    }
  end

  defp dump_value(%Imp.Adapter.Types.Image{} = image) do
    %{
      "__imp_type__" => "image",
      "schema_version" => @image_schema_version,
      "url" => image.url,
      "data" => image.data,
      "mime_type" => image.mime_type,
      "metadata" => dump_value(image.metadata)
    }
  end

  defp dump_value(%__MODULE__{} = report) do
    Map.put(dump(report), "__imp_type__", "optimizer_report")
  end

  defp dump_value(value) when is_struct(value) do
    value
    |> Map.from_struct()
    |> dump_value()
  end

  defp dump_value(map) when is_map(map) and map_size(map) == 0, do: %{}

  defp dump_value(map) when is_map(map) do
    if Enum.all?(Map.keys(map), &is_binary/1) do
      dump_plain_map(map)
    else
      dump_tagged_map(map)
    end
  end

  defp dump_value(list) when is_list(list) do
    case split_list(list) do
      {:proper, items} ->
        Enum.map(items, &dump_value/1)

      {:improper, heads, tail} ->
        %{
          "__imp_type__" => "improper_list",
          "heads" => Enum.map(heads, &dump_value/1),
          "tail" => dump_value(tail)
        }
    end
  end

  defp dump_value(tuple) when is_tuple(tuple) do
    %{
      "__imp_type__" => "tuple",
      "items" => tuple |> Tuple.to_list() |> Enum.map(&dump_value/1)
    }
  end

  defp dump_value(value) when is_atom(value),
    do: %{"__imp_type__" => "atom", "value" => Atom.to_string(value)}

  defp dump_value(value), do: value

  defp dump_projection(%Imp.Example{} = example) do
    %{
      "__imp_type__" => "example",
      "fields" => dump_projection(Imp.Example.to_map(example)),
      "input_keys" => dump_projection(example.input_keys),
      "demos" => dump_projection(example.demos)
    }
  end

  defp dump_projection(%Imp.Adapter.Types.Image{} = image) do
    %{
      "__imp_type__" => "image",
      "schema_version" => @image_schema_version,
      "url" => image.url,
      "data" => image.data,
      "mime_type" => image.mime_type,
      "metadata" => dump_projection(image.metadata)
    }
  end

  defp dump_projection(%__MODULE__{} = report) do
    %{
      "optimizer" => dump_projection(report.optimizer),
      "best_score" => dump_projection(report.best_score),
      "candidate_count" => dump_projection(report.candidate_count),
      "candidates" => dump_projection(report.candidates),
      "errors" => dump_projection(report.errors),
      "metadata" => dump_projection(report.metadata)
    }
  end

  defp dump_projection(value) when is_struct(value) do
    value
    |> Map.from_struct()
    |> dump_projection()
  end

  defp dump_projection(map) when is_map(map) and map_size(map) == 0, do: %{}

  defp dump_projection(map) when is_map(map) do
    if Enum.all?(Map.keys(map), &(is_atom(&1) or is_binary(&1))) do
      Enum.reduce(map, %{}, fn {key, value}, encoded ->
        key = encode_key(key)

        if Map.has_key?(encoded, key) do
          raise ArgumentError,
                "optimizer report projection contains colliding JSON key #{inspect(key)}"
        end

        Map.put(encoded, key, dump_projection(value))
      end)
    else
      dump_tagged_map(map)
    end
  end

  defp dump_projection(list) when is_list(list) do
    case split_list(list) do
      {:proper, items} ->
        Enum.map(items, &dump_projection/1)

      {:improper, heads, tail} ->
        %{
          "__imp_type__" => "improper_list",
          "heads" => Enum.map(heads, &dump_projection/1),
          "tail" => dump_projection(tail)
        }
    end
  end

  defp dump_projection(tuple) when is_tuple(tuple) do
    %{
      "__imp_type__" => "tuple",
      "items" => tuple |> Tuple.to_list() |> Enum.map(&dump_projection/1)
    }
  end

  defp dump_projection(value) when is_atom(value),
    do: %{"__imp_type__" => "atom", "value" => Atom.to_string(value)}

  defp dump_projection(value), do: value

  defp dump_plain_map(map) do
    Enum.reduce(map, %{}, fn
      {key, value}, encoded when is_binary(key) ->
        Map.put(encoded, key, dump_value(value))

      {key, _value}, _encoded ->
        raise ArgumentError, "unsupported optimizer report map key: #{inspect(key)}"
    end)
  end

  defp dump_tagged_map(map) do
    entries =
      map
      |> Enum.sort_by(fn {key, _value} -> :erlang.term_to_binary(key, [:deterministic]) end)
      |> Enum.map(fn {key, value} ->
        encoded_key = dump_value(key)

        case Jason.encode(encoded_key) do
          {:ok, _json} ->
            [encoded_key, dump_value(value)]

          {:error, _reason} ->
            raise ArgumentError, "unsupported optimizer report map key: #{inspect(key)}"
        end
      end)

    %{"__imp_type__" => "map", "entries" => entries}
  end

  defp load_value(%{"__imp_type__" => "atom"} = state) do
    validate_exact_tag!(state, @atom_tag_keys, "atom")

    case state["value"] do
      value when is_binary(value) ->
        Map.get_lazy(@portable_optimizer_atoms, value, fn ->
          :erlang.binary_to_existing_atom(value, :utf8)
        end)

      _value ->
        raise ArgumentError, "malformed Imp atom JSON tag"
    end
  end

  defp load_value(%{"__imp_type__" => "optimizer_report"} = state) do
    validate_exact_tag!(state, @optimizer_report_tag_keys, "optimizer report")

    state
    |> Map.delete("__imp_type__")
    |> load()
  end

  defp load_value(%{"__imp_type__" => "improper_list"} = state) do
    validate_exact_tag!(state, @improper_list_tag_keys, "improper list")

    case state do
      %{"heads" => heads, "tail" => tail} when is_list(heads) and heads != [] ->
        heads
        |> Enum.map(&load_value/1)
        |> Enum.reverse()
        |> Enum.reduce(load_value(tail), fn head, acc -> [head | acc] end)

      _state ->
        raise ArgumentError, "malformed Imp improper-list JSON tag"
    end
  end

  defp load_value(%{"__imp_type__" => "example"} = state) do
    validate_exact_tag!(state, @example_tag_keys, "example")

    fields = load_value(state["fields"])
    input_keys = load_value(state["input_keys"])
    demos = load_value(state["demos"])

    unless is_map(fields) and (is_nil(input_keys) or is_list(input_keys)) and is_list(demos) do
      raise ArgumentError, "malformed Imp example JSON tag"
    end

    fields
    |> Imp.Example.new()
    |> maybe_with_inputs(input_keys)
    |> maybe_with_demos(demos)
  end

  defp load_value(%{"__imp_type__" => "image"} = state) do
    if valid_image_state?(state) do
      %Imp.Adapter.Types.Image{
        url: state["url"],
        data: state["data"],
        mime_type: state["mime_type"],
        metadata: load_value(state["metadata"])
      }
    else
      raise ArgumentError, "malformed Imp image JSON tag"
    end
  end

  defp load_value(%{"__imp_type__" => "tuple"} = state) do
    validate_exact_tag!(state, @tuple_tag_keys, "tuple")

    case state["items"] do
      items when is_list(items) -> items |> Enum.map(&load_value/1) |> List.to_tuple()
      _items -> raise ArgumentError, "malformed Imp tuple JSON tag"
    end
  end

  defp load_value(%{"__imp_type__" => "map"} = state) do
    validate_exact_tag!(state, @map_tag_keys, "map")

    case state["entries"] do
      entries when is_list(entries) ->
        Enum.reduce(entries, %{}, fn
          [key, value], decoded ->
            key = load_value(key)

            if Map.has_key?(decoded, key) do
              raise ArgumentError,
                    "optimizer report map contains duplicate decoded key #{inspect(key)}"
            end

            Map.put(decoded, key, load_value(value))

          _entry, _decoded ->
            raise ArgumentError, "malformed Imp map JSON tag"
        end)

      _entries ->
        raise ArgumentError, "malformed Imp map JSON tag"
    end
  end

  defp load_value(%{"__imp_type__" => type}),
    do: raise(ArgumentError, "unsupported Imp JSON wire tag: #{inspect(type)}")

  defp load_value(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, decoded ->
      unless is_binary(key) do
        raise ArgumentError, "unsupported optimizer report JSON map key: #{inspect(key)}"
      end

      Map.put(decoded, key, load_value(value))
    end)
  end

  defp load_value(list) when is_list(list), do: Enum.map(list, &load_value/1)
  defp load_value(value), do: value

  defp maybe_with_inputs(example, nil), do: example
  defp maybe_with_inputs(example, input_keys), do: Imp.Example.with_inputs(example, input_keys)

  defp maybe_with_demos(example, []), do: example
  defp maybe_with_demos(example, demos), do: Imp.Example.with_demos(example, demos)

  defp encode_key(key) when is_atom(key), do: Atom.to_string(key)
  defp encode_key(key), do: key

  defp fetch(map, key, default \\ nil) when is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp fetch_required!(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        case Map.fetch(map, Atom.to_string(key)) do
          {:ok, value} -> value
          :error -> raise ArgumentError, "malformed optimizer report state"
        end
    end
  end

  defp validate_report_keys!(state) do
    keys = state |> Map.keys() |> Enum.map(&encode_key/1) |> MapSet.new()

    unless MapSet.equal?(keys, @report_keys) do
      raise ArgumentError, "malformed optimizer report state"
    end
  end

  defp validate_exact_tag!(state, expected_keys, tag_name) do
    unless MapSet.equal?(MapSet.new(Map.keys(state)), expected_keys) do
      raise ArgumentError, "malformed Imp #{tag_name} JSON tag"
    end
  end

  defp split_list(list), do: split_list(list, [])
  defp split_list([], reversed), do: {:proper, Enum.reverse(reversed)}
  defp split_list([head | tail], reversed), do: split_list(tail, [head | reversed])
  defp split_list(tail, reversed), do: {:improper, Enum.reverse(reversed), tail}

  defp reject_canonical_key_collisions!(map, context) do
    _keys =
      Enum.reduce(Map.keys(map), MapSet.new(), fn
        key, keys when is_atom(key) or is_binary(key) ->
          canonical_key = encode_key(key)

          if MapSet.member?(keys, canonical_key) do
            raise ArgumentError, "#{context} contains colliding key #{inspect(canonical_key)}"
          end

          MapSet.put(keys, canonical_key)

        key, _keys ->
          raise ArgumentError, "#{context} contains unsupported key #{inspect(key)}"
      end)

    :ok
  end

  defp valid_image_state?(state) do
    MapSet.equal?(MapSet.new(Map.keys(state)), @image_tag_keys) and
      state["schema_version"] == @image_schema_version and
      optional_binary?(state["url"]) and
      optional_binary?(state["data"]) and
      optional_binary?(state["mime_type"]) and
      is_map(state["metadata"])
  end

  defp optional_binary?(value), do: is_nil(value) or is_binary(value)
end
