defmodule Imp.Persistence.LegacyTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.{Artifact, GEPA.EvaluationCache.Codec, Report}

  test "restores nested legacy JSON tags without weakening collision checks" do
    legacy = %{
      "value" => %{
        "__dsex_type__" => "tuple",
        "items" => [%{"__dsex_type__" => "atom", "value" => "ok"}, 1]
      }
    }

    assert Report.restore_json_safe(legacy) == %{value: {:ok, 1}}

    assert_raise ArgumentError, ~r/contains both/, fn ->
      Report.restore_json_safe(%{
        "__dsex_type__" => "atom",
        "__imp_type__" => "atom",
        "value" => "ok"
      })
    end
  end

  test "loads a checksummed legacy program envelope without rewriting it" do
    path = temp_path("program")
    on_exit(fn -> File.rm(path) end)
    payload = Imp.predict("question -> answer") |> Imp.Saving.dump()

    legacy = %{
      "artifact_type" => "dsex_program_artifact",
      "schema_version" => 1,
      "payload_sha256" => Codec.checksum(payload),
      "payload" => payload
    }

    File.write!(path, Jason.encode!(legacy))
    assert %Imp.Predict.Predict{} = Imp.Saving.load!(path)
    assert Jason.decode!(File.read!(path)) == legacy
  end

  test "validates old optimizer checksums before normalizing derived digests" do
    path = temp_path("optimizer")
    on_exit(fn -> File.rm(path) end)

    candidate = Artifact.candidate("baseline", Imp.predict("question -> answer"))
    current = Artifact.new(candidate)

    legacy_payload =
      current["payload"]
      |> deep_replace("__imp_type__", "__dsex_type__")
      |> deep_replace("imp_optimizer_trajectory", "dsex_optimizer_trajectory")

    legacy = %{
      current
      | "artifact_type" => "dsex_optimizer_artifact",
        "payload" => legacy_payload,
        "payload_sha256" => Codec.checksum(legacy_payload)
    }

    File.write!(path, Jason.encode!(legacy))
    assert %{champion_id: "baseline"} = path |> Artifact.read!() |> Artifact.inspect()

    tampered = put_in(legacy, ["payload", "revision"], 2)
    File.write!(path, Jason.encode!(tampered))

    assert_raise ArgumentError, ~r/legacy optimizer artifact payload checksum mismatch/, fn ->
      Artifact.read!(path)
    end
  end

  test "normalizes only known manifest runtime keys and rejects collisions" do
    rlm = %{
      "models" => %{"root" => %{"dsex" => "openai:test", "dspy" => "openai/test"}},
      "approaches" => %{"rlm" => %{"runtimes" => ["dsex", "dspy"]}}
    }

    assert get_in(Imp.Persistence.Legacy.rlm_manifest(rlm), ["models", "root", "imp"]) ==
             "openai:test"

    instruction = %{"source_commits" => %{"dsex" => "legacy", "dspy" => "upstream"}}

    assert Imp.Persistence.Legacy.instruction_manifest(instruction)["source_commits"] == %{
             "imp" => "legacy",
             "dspy" => "upstream"
           }

    assert_raise ArgumentError, ~r/contains both dsex and imp keys/, fn ->
      Imp.Persistence.Legacy.instruction_manifest(%{
        "source_commits" => %{"dsex" => "old", "imp" => "new"}
      })
    end
  end

  test "canonicalizes exact GEPA and RLM identities at frozen-evidence boundaries" do
    gepa = %{
      "campaign_id" => "dsex-gepa-paper-campaign-v2",
      "environment" => %{
        "python_env" => "DSEX_GEPA_PYTHON",
        "gepa_root_env" => "DSEX_GEPA_ROOT",
        "unrelated" => "DSEX_OTHER"
      }
    }

    assert Imp.Persistence.Legacy.gepa_manifest(gepa) == %{
             "campaign_id" => "imp-gepa-paper-campaign-v2",
             "environment" => %{
               "python_env" => "IMP_GEPA_PYTHON",
               "gepa_root_env" => "IMP_GEPA_ROOT",
               "unrelated" => "DSEX_OTHER"
             }
           }

    fixture = %{
      "cases" => [
        %{"id" => "dsex_symbolic_recurse_extension"},
        %{"id" => "upstream_case"}
      ]
    }

    assert Imp.Persistence.Legacy.rlm_contract_fixture(fixture)["cases"] == [
             %{"id" => "imp_symbolic_recurse_extension"},
             %{"id" => "upstream_case"}
           ]

    result = %{"rows" => [%{"id" => "dsex_symbolic_recurse_extension"}]}

    assert Imp.Persistence.Legacy.rlm_contract_result(result)["rows"] == [
             %{"id" => "imp_symbolic_recurse_extension"}
           ]
  end

  defp deep_replace(value, from, to) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      key = if key == from, do: to, else: key
      {key, deep_replace(nested, from, to)}
    end)
  end

  defp deep_replace(value, from, to) when is_list(value),
    do: Enum.map(value, &deep_replace(&1, from, to))

  defp deep_replace(value, from, to) when is_binary(value),
    do: if(value == from, do: to, else: value)

  defp deep_replace(value, _from, _to), do: value

  defp temp_path(name) do
    Path.join(System.tmp_dir!(), "imp-legacy-#{name}-#{System.unique_integer([:positive])}.json")
  end
end
