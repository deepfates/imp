defmodule DSEx.BenchmarkTruth.AxContractTest do
  use ExUnit.Case, async: true

  alias DSEx.BenchmarkTruth.{AxContract, RunContext}

  test "provider-free Ax vectors match or declare narrow native deviations" do
    rows = AxContract.compare(upstream())

    assert Enum.map(rows, & &1["id"]) ==
             ~w(typed_signature structured_output streaming_optional tools usage optimizer_selection)

    assert Enum.all?(rows, & &1["passing"])
    assert Enum.count(rows, &(&1["status"] == "matched")) == 4

    assert Enum.map(
             Enum.filter(rows, &(&1["status"] == "intentional_deviation")),
             & &1["id"]
           ) == ~w(tools optimizer_selection)

    assert Enum.all?(rows, &String.contains?(&1["source_test"], "#sha256="))
  end

  test "validator rejects a forged scientific-authority claim" do
    artifact = valid_artifact()
    forged = put_in(artifact, ["summary", "scientific_authority"], true)
    forged = reseal(forged)

    assert_raise ArgumentError, ~r/invalid Ax differential artifact/, fn ->
      AxContract.validate_artifact!(forged)
    end
  end

  test "validator rejects row result tampering before semantic admission" do
    artifact = valid_artifact()
    forged = put_in(artifact, ["rows", Access.at(0), "passing"], false)

    assert_raise ArgumentError, ~r/tampered benchmark run envelope/, fn ->
      AxContract.validate_artifact!(forged)
    end
  end

  defp valid_artifact do
    context =
      RunContext.new!(
        source_commits: %{
          "dsex" => "deepfates/dsex@fixture",
          "ax" => "ax-llm/ax@eb5835e54ba0c5b2fbac380daed1cb87faeefd5e"
        }
      )

    rows = AxContract.compare(upstream())

    RunContext.finish(context, %{
      "schema_version" => 1,
      "evidence_tier" => "t1_ax_independent_implementation_differential",
      "claim_scope" => "provider-free independent implementation comparison",
      "authority" => %{
        "role" => "independent_implementation_comparator",
        "repository" => "https://github.com/ax-llm/ax",
        "version" => "23.0.0",
        "commit" => "eb5835e54ba0c5b2fbac380daed1cb87faeefd5e",
        "npm_integrity" =>
          "sha512-CWL/vM9RfS0wvVvRbApjYfwhgLa5UOdJno5y2Ime+lWSLYBEwHOhiBJonx08jhh01KoyJYHWS+QcYeInqR7Fsw==",
        "source_tests" => Map.new(rows, &{&1["id"], &1["source_test"]})
      },
      "runtime" => %{
        "package" => "@ax-llm/ax",
        "version" => "23.0.0",
        "provider_calls" => 0,
        "network_calls" => 0
      },
      "rows" => rows,
      "summary" => %{
        "required_cases" => 6,
        "passing_cases" => 6,
        "matched_cases" => 4,
        "intentional_deviations" => 2,
        "contract_complete" => true,
        "scientific_authority" => false,
        "provider_calls" => 0
      }
    })
  end

  defp reseal(artifact) do
    payload = Map.drop(artifact, ["generated_at", "git_sha", "run_context"])

    context =
      RunContext.new!(
        source_commits: %{
          "dsex" => "deepfates/dsex@fixture",
          "ax" => "ax-llm/ax@eb5835e54ba0c5b2fbac380daed1cb87faeefd5e"
        }
      )

    RunContext.finish(context, payload)
  end

  defp upstream do
    %{
      "runtime" => %{"package" => "@ax-llm/ax", "version" => "23.0.0", "provider_calls" => 0},
      "cases" => %{
        "typed_signature" => %{
          "inputs" => [
            field("question", "string"),
            field("tags", "string", array: true, optional: true)
          ],
          "outputs" => [field("label", "class", options: ["yes", "no"]), field("score", "number")]
        },
        "structured_output" => %{
          "type" => "object",
          "required" => ~w(question label score),
          "properties" => %{
            "question" => schema("string"),
            "tags" => schema("array", items: "string"),
            "label" => schema("string", enum: ["yes", "no"]),
            "score" => schema("number")
          }
        },
        "streaming_optional" => %{
          "omitted" => %{"requiredField" => "only required"},
          "present" => %{"requiredField" => "required", "optionalField" => "present"}
        },
        "tools" => %{
          "objectResult" => %{"found" => true, "key" => "alpha"},
          "unknownToolError" => %{
            "name" => "ValidationError",
            "recoverable" => true,
            "listsAvailableTool" => true
          }
        },
        "usage" => %{
          "promptTokens" => 100,
          "completionTokens" => 30,
          "totalTokens" => 150,
          "reasoningTokens" => 7,
          "cacheReadTokens" => 20
        },
        "optimizer_selection" => %{
          "snapshot" => %{
            "recent::instruction" => %{"proposals" => 1},
            "stale::instruction" => %{"proposals" => 4}
          },
          "pickAtHalf" => "stale::instruction"
        }
      }
    }
  end

  defp field(name, type, opts \\ []) do
    %{
      "name" => name,
      "type" => type,
      "array" => Keyword.get(opts, :array, false),
      "optional" => Keyword.get(opts, :optional, false),
      "options" => Keyword.get(opts, :options, [])
    }
  end

  defp schema(type, opts \\ []) do
    %{
      "type" => type,
      "enum" => Keyword.get(opts, :enum, []),
      "items" => Keyword.get(opts, :items)
    }
  end
end
