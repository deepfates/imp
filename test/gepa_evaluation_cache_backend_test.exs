defmodule Imp.Optimizer.GEPA.EvaluationCacheBackendTest do
  use ExUnit.Case, async: true

  alias Imp.Adapters.Types.Image
  alias Imp.Optimizer.GEPA.EvaluationCache.{Codec, Disk, Memory}
  alias Imp.Optimizer.GEPA.Result

  setup do
    run_dir =
      Path.join(
        System.tmp_dir!(),
        "imp-gepa-cache-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf!(run_dir) end)
    %{run_dir: run_dir}
  end

  test "memory backend preserves hit, miss, put, and assemble semantics" do
    candidate = %{main: "careful"}

    cache =
      Memory.new()
      |> Memory.put(
        candidate,
        [:alpha, :beta],
        Result.new(["A", "B"], [0.25, 0.75])
      )

    {hits, [1]} = Memory.lookup(cache, candidate, [:beta, :missing, :alpha])

    result =
      Memory.assemble(
        [:beta, :missing, :alpha],
        hits,
        [1],
        Result.new(["fresh"], [1.0], metadata: %{metric_calls: 1})
      )

    assert result.outputs == ["B", "fresh", "A"]
    assert result.scores == [0.75, 1.0, 0.25]
    assert result.metadata == %{cache_hits: 2, cache_misses: 1, metric_calls: 1}
  end

  test "disk backend supports misses, partial batches, and ordered assembly", %{run_dir: run_dir} do
    cache = Disk.new(run_dir)
    candidate = %{planner: "plan", writer: "write"}

    assert {%{}, [0, 1]} = Disk.lookup(cache, candidate, [:one, :two])

    Disk.put(
      cache,
      candidate,
      [:one],
      Result.new([%{answer: "one"}], [0.5], objective_scores: [%{quality: 0.75}])
    )

    {hits, [1]} = Disk.lookup(cache, candidate, [:one, :two])

    result =
      Disk.assemble(
        [:one, :two],
        hits,
        [1],
        Result.new([%{answer: "two"}], [1.0],
          objective_scores: [%{quality: 1.0}],
          metadata: %{metric_calls: 1}
        )
      )

    assert result.outputs == [%{answer: "one"}, %{answer: "two"}]
    assert result.scores == [0.5, 1.0]
    assert result.objective_scores == [%{quality: 0.75}, %{quality: 1.0}]
    assert result.metadata.cache_hits == 1
    assert result.metadata.cache_misses == 1
  end

  test "concurrent BEAM processes publish complete entries", %{run_dir: run_dir} do
    cache = Disk.new(run_dir)
    candidate = %{main: "concurrent"}
    examples = Enum.map(1..40, &%{id: &1})

    examples
    |> Task.async_stream(
      fn example ->
        Disk.put(cache, candidate, [example], Result.new([{:ok, example.id}], [1.0]))
      end,
      max_concurrency: 16,
      ordered: false,
      timeout: 10_000
    )
    |> Enum.each(&assert({:ok, ^cache} = &1))

    1..20
    |> Task.async_stream(
      fn _index ->
        Disk.put(cache, candidate, [:shared], Result.new([:complete], [1.0]))
      end,
      max_concurrency: 20,
      ordered: false,
      timeout: 10_000
    )
    |> Enum.each(&assert({:ok, ^cache} = &1))

    assert {hits, []} = Disk.lookup(cache, candidate, examples ++ [:shared])
    assert map_size(hits) == 41
    assert hits[40].output == :complete
  end

  test "entries survive constructing a new backend for the same run directory", %{
    run_dir: run_dir
  } do
    candidate = %{main: "persistent"}
    first = Disk.new(run_dir)
    Disk.put(first, candidate, [%{id: 7}], Result.new([{:answer, 7}], [0.9]))

    reopened = Disk.new(run_dir)
    assert {hits, []} = Disk.lookup(reopened, candidate, [%{id: 7}])
    assert hits[0].output == {:answer, 7}
    assert hits[0].score == 0.9
  end

  test "corrupt payloads fail closed as misses", %{run_dir: run_dir} do
    cache = Disk.new(run_dir)
    candidate = %{main: "checksum"}
    example = %{id: 1}
    Disk.put(cache, candidate, [example], Result.new(["original"], [1.0]))

    path = Disk.entry_path(cache, candidate, example)
    artifact = path |> File.read!() |> Jason.decode!()
    tampered = put_in(artifact, ["payload", "output"], "tampered")
    File.write!(path, Jason.encode!(tampered))

    assert {%{}, [0]} = Disk.lookup(cache, candidate, [example])
  end

  test "schema mismatches fail closed as misses", %{run_dir: run_dir} do
    cache = Disk.new(run_dir)
    candidate = %{main: "schema"}
    Disk.put(cache, candidate, [:example], Result.new([:ok], [1.0]))

    path = Disk.entry_path(cache, candidate, :example)
    artifact = path |> File.read!() |> Jason.decode!() |> Map.put("schema_version", 999)
    File.write!(path, Jason.encode!(artifact))

    assert {%{}, [0]} = Disk.lookup(cache, candidate, [:example])
  end

  test "image outputs round trip through Optimizer.Report codecs", %{run_dir: run_dir} do
    cache = Disk.new(run_dir)
    candidate = %{main: "vision"}

    image = %Image{
      data: "aW1hZ2UtYnl0ZXM=",
      mime_type: "image/png",
      metadata: %{detail: :high, source: {:camera, 2}}
    }

    Disk.put(cache, candidate, [:image], Result.new([%{image: image}], [1.0]))

    assert {hits, []} = Disk.lookup(cache, candidate, [:image])
    assert hits[0].output == %{image: image}
  end

  test "candidate and example secrets never appear in cache paths or artifacts", %{
    run_dir: run_dir
  } do
    candidate_secret = "sk-candidate-super-secret"
    example_secret = "Bearer example-super-secret"
    cache = Disk.new(run_dir)
    candidate = %{main: candidate_secret}
    example = %{authorization: example_secret}

    Disk.put(cache, candidate, [example], Result.new([:ok], [1.0]))

    paths = Path.wildcard(Path.join(cache.root, "**/*"))
    refute Enum.any?(paths, &String.contains?(&1, candidate_secret))
    refute Enum.any?(paths, &String.contains?(&1, example_secret))

    path = Disk.entry_path(cache, candidate, example)
    assert Path.basename(Path.dirname(path)) =~ ~r/^[a-f0-9]{2}$/
    assert Path.basename(path) =~ ~r/^[a-f0-9]{64}\.json$/
    refute File.read!(path) =~ candidate_secret
    refute File.read!(path) =~ example_secret
  end

  test "untrusted atom tags cannot intern new atoms", %{run_dir: run_dir} do
    cache = Disk.new(run_dir)
    candidate = %{main: "atom-safe"}
    example = :example
    Disk.put(cache, candidate, [example], Result.new([:ok], [1.0]))

    atom_name = "imp_untrusted_atom_#{System.unique_integer([:positive, :monotonic])}"

    assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end

    path = Disk.entry_path(cache, candidate, example)
    artifact = path |> File.read!() |> Jason.decode!()

    payload =
      Map.put(artifact["payload"], "output", %{
        "__imp_type__" => "atom",
        "value" => atom_name
      })

    artifact =
      artifact
      |> Map.put("payload", payload)
      |> Map.put("payload_sha256", Codec.checksum(payload))

    File.write!(path, Jason.encode!(artifact))

    assert {%{}, [0]} = Disk.lookup(cache, candidate, [example])
    assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end
  end
end
