defmodule Imp.BenchmarkTruth.GepaSuiteTest do
  use ExUnit.Case, async: true

  alias Imp.BenchmarkTruth.GepaSuite

  test "loads verified optimization rows while keeping held-out bytes deferred" do
    root = tmp_root!()
    family = "AIMEBench"
    family_dir = Path.join(root, family)
    File.mkdir_p!(family_dir)

    train = [%{"problem" => "train", "answer" => "1"}]
    dev = [%{"problem" => "dev", "answer" => "2"}]
    test = [%{"problem" => "test", "answer" => "3"}]

    paths = GepaSuite.split_paths(root, family)
    write_jsonl!(paths.train, train)
    write_jsonl!(paths.dev, dev)
    write_jsonl!(paths.test, test)

    spec = %{
      "family" => family,
      "program" => "CoT",
      "signature" => "problem -> answer",
      "instructions" => "Solve the problem.",
      "input_keys" => ["problem"],
      "output_key" => "answer",
      "metric_calls" => 10,
      "upstream_metric" => "AIME.metric integer exact match",
      "split_counts" => %{"train" => 1, "dev" => 1, "test" => 1},
      "split_checksums" => %{
        "train" => sha256(paths.train),
        "dev" => sha256(paths.dev),
        "test" => sha256(paths.test)
      }
    }

    File.write!(
      Path.join(root, "families.json"),
      Jason.encode!(%{"families" => [spec]})
    )

    loaded = GepaSuite.load!(root, family)

    assert Enum.map(loaded.train, &Imp.Example.get(&1, :problem)) == ["train"]
    assert Enum.map(loaded.dev, &Imp.Example.get(&1, :problem)) == ["dev"]
    assert loaded.test_count == 1
    refute Map.has_key?(loaded, :test)

    assert Enum.map(GepaSuite.load_test!(loaded), &Imp.Example.get(&1, :problem)) == ["test"]
  end

  test "rejects source drift before constructing a program" do
    root = tmp_root!()
    family = "AIMEBench"
    family_dir = Path.join(root, family)
    File.mkdir_p!(family_dir)

    for split <- ~w(train dev test) do
      File.write!(Path.join(family_dir, split <> ".jsonl"), "{}\n")
    end

    File.write!(
      Path.join(root, "families.json"),
      Jason.encode!(%{
        "families" => [
          %{
            "family" => family,
            "program" => "CoT",
            "input_keys" => ["problem"],
            "split_counts" => %{"train" => 1, "dev" => 1, "test" => 1},
            "split_checksums" => %{
              "train" => "sha256:" <> String.duplicate("0", 64),
              "dev" => sha256(Path.join(family_dir, "dev.jsonl")),
              "test" => sha256(Path.join(family_dir, "test.jsonl"))
            }
          }
        ]
      })
    )

    assert_raise ArgumentError, ~r/train digest drift/, fn ->
      GepaSuite.load!(root, family)
    end
  end

  defp tmp_root! do
    root =
      Path.join(
        System.tmp_dir!(),
        "imp-gepa-suite-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp write_jsonl!(path, rows) do
    File.write!(path, Enum.map_join(rows, "", &(Jason.encode!(&1) <> "\n")))
  end

  defp sha256(path) do
    "sha256:" <>
      (path
       |> File.read!()
       |> then(&:crypto.hash(:sha256, &1))
       |> Base.encode16(case: :lower))
  end
end
