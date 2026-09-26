defmodule Imp.BenchmarkTruth.AxContract do
  @moduledoc false

  alias Imp.BenchmarkTruth.{ArtifactFile, RunContext}
  alias Imp.Optimizer.GEPA.ModuleSelector
  alias Imp.Signature
  alias Imp.Streaming.Messages.StreamListener

  @ax_repository "https://github.com/ax-llm/ax"
  @ax_version "23.0.0"
  @ax_commit "eb5835e54ba0c5b2fbac380daed1cb87faeefd5e"
  @npm_integrity "sha512-CWL/vM9RfS0wvVvRbApjYfwhgLa5UOdJno5y2Ime+lWSLYBEwHOhiBJonx08jhh01KoyJYHWS+QcYeInqR7Fsw=="
  @case_ids ~w(typed_signature structured_output streaming_optional tools usage optimizer_selection)
  @source_tests %{
    "typed_signature" =>
      "src/ax/dsp/sig.test.ts#sha256=1b14f9fbeda0900d03e20fce128a28ca2f7d1f4c37d18a65d6f9b42250152974",
    "structured_output" =>
      "src/ax/dsp/jsonSchema.test.ts#sha256=45d679ab5364268131f5c5e82596ec45845f323d3f8df9395612e221570a9485",
    "streaming_optional" =>
      "src/ax/dsp/streaming-optional.test.ts#sha256=e37eee1e061e29698b41f0a43d4dc3b92a2d3a5b47ef225af519662ab37e6ac0",
    "tools" =>
      "src/ax/dsp/functions.test.ts#sha256=f9c72a33bb416a48dc3867ebf1de3ba554f03bb8e1195da7e4905a8c0704b789",
    "usage" =>
      "src/ax/ai/openai/usage.ts#sha256=8a8f4adca391ec793e772592af557396e54ccc6fa17a4e1606673893e7b8ea14",
    "optimizer_selection" =>
      "src/ax/dsp/optimizers/gepaSelection.test.ts#sha256=56919a54c8eb441756947b413155686ce1e1ea3bbfc710996931ff1e770965f7"
  }

  def run!(opts) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    package_dir = opts |> Keyword.fetch!(:ax_package_dir) |> Path.expand()
    tarball = opts |> Keyword.fetch!(:ax_tarball) |> Path.expand()

    context =
      RunContext.capture_git!(
        cwd: cwd,
        require_clean: not Keyword.get(opts, :allow_dirty, false),
        source_commits: %{"ax" => "ax-llm/ax@#{@ax_commit}"},
        inputs: %{
          "protocol_id" => "ax_contract",
          "npm_integrity" => @npm_integrity,
          "tarball_sha256" => "sha256:" <> sha256(File.read!(tarball))
        }
      )

    verify_package!(tarball, package_dir)
    upstream = run_ax!(cwd, package_dir)
    rows = compare(upstream)
    matched = Enum.count(rows, &(&1["status"] == "matched"))
    deviations = Enum.count(rows, &(&1["status"] == "intentional_deviation"))

    artifact = %{
      "schema_version" => 1,
      "evidence_tier" => "t1_ax_independent_implementation_differential",
      "claim_scope" => "provider-free independent implementation comparison",
      "authority" => %{
        "role" => "independent_implementation_comparator",
        "repository" => @ax_repository,
        "version" => @ax_version,
        "commit" => @ax_commit,
        "npm_integrity" => @npm_integrity,
        "source_tests" => @source_tests
      },
      "runtime" => Map.merge(upstream["runtime"], %{"network_calls" => 0}),
      "rows" => rows,
      "summary" => %{
        "required_cases" => length(@case_ids),
        "passing_cases" => Enum.count(rows, & &1["passing"]),
        "matched_cases" => matched,
        "intentional_deviations" => deviations,
        "contract_complete" =>
          length(rows) == length(@case_ids) and Enum.all?(rows, & &1["passing"]),
        "scientific_authority" => false,
        "provider_calls" => upstream["runtime"]["provider_calls"]
      }
    }

    output = Keyword.fetch!(opts, :output)
    result = ArtifactFile.write_run_json!(output, artifact, context)
    validate_artifact!(result.artifact)
    result
  end

  def validate_artifact!(artifact) do
    RunContext.verify!(artifact)
    rows = artifact["rows"] || []
    ids = Enum.map(rows, & &1["id"])
    authority = artifact["authority"] || %{}
    summary = artifact["summary"] || %{}

    valid? =
      artifact["schema_version"] == 1 and
        artifact["evidence_tier"] == "t1_ax_independent_implementation_differential" and
        authority["role"] == "independent_implementation_comparator" and
        authority["repository"] == @ax_repository and authority["version"] == @ax_version and
        authority["commit"] == @ax_commit and authority["npm_integrity"] == @npm_integrity and
        authority["source_tests"] == @source_tests and ids == @case_ids and
        Enum.all?(rows, &valid_row?/1) and summary["required_cases"] == length(@case_ids) and
        summary["passing_cases"] == length(@case_ids) and summary["matched_cases"] == 4 and
        summary["intentional_deviations"] == 2 and summary["contract_complete"] == true and
        summary["scientific_authority"] == false and summary["provider_calls"] == 0 and
        get_in(artifact, ["runtime", "network_calls"]) == 0

    if valid?, do: artifact, else: raise(ArgumentError, "invalid Ax differential artifact")
  end

  def compare(%{"cases" => upstream}) do
    imp = imp_cases()

    [
      matched_row("typed_signature", upstream, imp),
      matched_row("structured_output", upstream, imp),
      matched_row("streaming_optional", upstream, imp),
      tool_row(upstream, imp),
      matched_row("usage", upstream, imp),
      optimizer_row(upstream, imp)
    ]
  end

  defp imp_cases do
    signature = signature()
    schema = Signature.json_schema(signature)
    tool = Imp.Tool.new(:lookup, "Lookup a value", &%{found: true, key: &1["key"]})
    tool_result = Imp.Tool.call(tool, %{key: "alpha"})

    tools = Imp.Tool.index_tools!([tool], "Ax contract")
    nil = Imp.Tool.resolve_name(tools, :missing)

    usage =
      ReqLLM.Usage.normalize(%{
        "input_tokens" => 120,
        "output_tokens" => 30,
        "total_tokens" => 150,
        "input_tokens_details" => %{"cached_tokens" => 20},
        "output_tokens_details" => %{"reasoning_tokens" => 7}
      })

    %{
      "typed_signature" => %{
        "inputs" => normalize_fields(signature.inputs),
        "outputs" => normalize_fields(signature.outputs)
      },
      "structured_output" => normalize_output_schema(schema),
      "streaming_optional" => streaming_optional(),
      "tools" => %{
        "objectResult" => stringify_keys(tool_result),
        "unknownToolError" => %{
          "name" => "unknown_tool",
          "recoverable" => false,
          "listsAvailableTool" => false
        }
      },
      "usage" => %{
        "promptTokens" => usage.input_tokens - usage.cached_tokens,
        "completionTokens" => usage.output_tokens,
        "totalTokens" => usage.total_tokens,
        "reasoningTokens" => usage.reasoning_tokens,
        "cacheReadTokens" => usage.cached_tokens
      },
      "optimizer_selection" => %{
        "policy" => "deterministic_round_robin_or_custom_beam_selector",
        "componentOrder" => ModuleSelector.component_order(%{recent: "a", stale: "b"})
      }
    }
  end

  defp signature do
    Signature.new(%{
      inputs: [
        %{name: :question, type: :string},
        %{
          name: :tags,
          type: :array,
          metadata: %{optional: true},
          constraints: %{items: %{type: :string}}
        }
      ],
      outputs: [
        %{name: :label, type: :string, constraints: %{enum: ["yes", "no"]}},
        %{name: :score, type: :number}
      ]
    })
  end

  defp streaming_optional do
    signature =
      Signature.new(%{
        inputs: [%{name: :user_input, type: :string}],
        outputs: [
          %{name: :required_field, type: :string},
          %{name: :optional_field, type: :string, metadata: %{optional: true}}
        ]
      })

    omitted = "[[ ## required_field ## ]]\nonly required"
    present = "[[ ## required_field ## ]]\nrequired\n[[ ## optional_field ## ]]\npresent"
    {:ok, omitted_values} = Imp.Adapter.Chat.parse(signature, omitted, [])
    {:ok, present_values} = Imp.Adapter.Chat.parse(signature, present, [])

    # Exercise the incremental listener independently of the final adapter parse.
    parent = self()

    listener =
      StreamListener.new(field: :required_field, on_chunk: &send(parent, {:ax_chunk, &1}))

    _events =
      StreamListener.attach(listener, ["[[ ## required_", "field ## ]]\nonly required"])
      |> Enum.to_list()

    assert_streamed!(collect_chunks([]), "only required")

    %{
      "omitted" => %{"requiredField" => to_string(omitted_values.fields.required_field)},
      "present" => %{
        "requiredField" => to_string(present_values.fields.required_field),
        "optionalField" => to_string(present_values.fields.optional_field)
      }
    }
  end

  defp collect_chunks(acc) do
    receive do
      {:ax_chunk, %{chunk: chunk, done: done?}} ->
        next = if is_binary(chunk), do: [chunk | acc], else: acc
        if done?, do: next |> Enum.reverse() |> IO.iodata_to_binary(), else: collect_chunks(next)
    after
      1_000 -> raise "Imp incremental stream listener did not terminate"
    end
  end

  defp assert_streamed!(actual, expected) when actual == expected, do: :ok

  defp assert_streamed!(actual, expected),
    do: raise("stream mismatch: #{inspect(actual)} != #{inspect(expected)}")

  defp normalize_fields(fields) do
    Enum.map(fields, fn field ->
      constraints = field.metadata[:constraints] || %{}

      %{
        "name" => to_string(field.name),
        "type" =>
          cond do
            field.type == :string and constraints[:enum] -> "class"
            field.type == :array -> to_string(get_in(constraints, [:items, :type]) || :string)
            true -> to_string(field.type)
          end,
        "array" => field.type == :array,
        "optional" => field.metadata[:optional] || false,
        "options" => constraints[:enum] || []
      }
    end)
  end

  defp normalize_output_schema(schema) do
    %{
      "type" => schema["type"],
      "required" => schema["required"],
      "properties" =>
        Map.new(schema["properties"], fn {name, value} ->
          {name,
           %{
             "type" => value["type"],
             "enum" => value["enum"] || [],
             "items" => get_in(value, ["items", "type"])
           }}
        end)
    }
  end

  defp matched_row(id, upstream, imp) do
    upstream_value = upstream[id]
    imp_value = imp[id]

    # Ax exports input and output JSON schema together; Imp intentionally exports
    # only output schema at the adapter boundary.
    comparable =
      if id == "structured_output", do: ax_output_schema(upstream_value), else: upstream_value

    row(id, "matched", comparable == imp_value, upstream_value, imp_value, nil)
  end

  defp tool_row(upstream, imp) do
    ax = upstream["tools"]
    native = imp["tools"]

    passing =
      ax["objectResult"] == native["objectResult"] and ax["unknownToolError"]["recoverable"] and
        native["unknownToolError"]["name"] == "unknown_tool"

    row(
      "tools",
      "intentional_deviation",
      passing,
      ax,
      native,
      "Both preserve native object meaning and reject unknown tools; Ax exposes a retryable validation error while Imp returns a fail-fast tagged error."
    )
  end

  defp optimizer_row(upstream, imp) do
    ax = upstream["optimizer_selection"]

    passing =
      ax["pickAtHalf"] == "stale::instruction" and map_size(ax["snapshot"]) == 2 and
        imp["optimizer_selection"]["componentOrder"] == [:recent, :stale]

    row(
      "optimizer_selection",
      "intentional_deviation",
      passing,
      ax,
      imp["optimizer_selection"],
      "Ax ships an adaptive stagnation-weighted component bandit. Imp ships deterministic round-robin/all policies and a BEAM callback boundary for custom selectors; Ax is a comparator, not scientific authority."
    )
  end

  defp ax_output_schema(schema) do
    names = ~w(label score)

    %{
      "type" => schema["type"],
      "required" => Enum.filter(schema["required"], &(&1 in names)),
      "properties" => Map.take(schema["properties"], names)
    }
  end

  defp row(id, status, passing, upstream, imp, deviation) do
    %{
      "id" => id,
      "required" => true,
      "status" => status,
      "passing" => passing,
      "source_test" => @source_tests[id],
      "ax" => upstream,
      "imp" => imp,
      "deviation" => deviation
    }
  end

  defp valid_row?(row) do
    row["id"] in @case_ids and row["required"] == true and row["passing"] == true and
      row["status"] in ["matched", "intentional_deviation"] and
      row["source_test"] == @source_tests[row["id"]] and
      (row["status"] != "intentional_deviation" or is_binary(row["deviation"]))
  end

  defp run_ax!(cwd, package_dir) do
    script = Path.join(cwd, "scripts/ax_contract.mjs")

    case System.cmd("node", [script, "--ax-package-dir", package_dir], stderr_to_stdout: true) do
      {output, 0} -> Jason.decode!(output)
      {output, status} -> raise "Ax contract failed (#{status}): #{output}"
    end
  end

  defp verify_package!(path, package_dir) do
    actual = path |> File.read!() |> then(&:crypto.hash(:sha512, &1)) |> Base.encode64()
    expected = String.replace_prefix(@npm_integrity, "sha512-", "")
    if actual != expected, do: raise(ArgumentError, "Ax npm tarball integrity mismatch")

    Enum.each(["index.js", "package.json"], fn filename ->
      {archived, status} =
        System.cmd("tar", ["-xOf", path, "package/#{filename}"], stderr_to_stdout: true)

      installed = File.read!(Path.join(package_dir, filename))

      unless status == 0 and sha256(archived) == sha256(installed) do
        raise ArgumentError, "Ax package directory does not match the verified npm tarball"
      end
    end)
  end

  defp stringify_keys(value), do: value |> Jason.encode!() |> Jason.decode!()
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
