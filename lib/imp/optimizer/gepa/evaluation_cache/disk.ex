defmodule Imp.Optimizer.GEPA.EvaluationCache.Disk do
  @moduledoc """
  Durable, content-addressed GEPA evaluation cache.

  Entries live below `run_dir/evaluation_cache/v1`. Candidate and example
  content is encoded through `Imp.Optimizer.Report`, canonicalized as JSON,
  and represented in paths only by SHA-256 digests. Each JSON envelope carries
  a schema version, its complete identity, and a checksum over the cached
  output. Reads accept only the exact expected envelope and fail closed as a
  cache miss on malformed, corrupt, or incompatible data.

  Writes are synchronized per entry across BEAM processes, fsynced to a unique
  owner-only temporary file, and atomically renamed into place. Existing valid
  entries are immutable: concurrent evaluations of the same identity retain
  whichever complete entry was published first.
  """

  @behaviour Imp.Optimizer.GEPA.EvaluationCache.Backend

  alias Imp.Optimizer.GEPA.{Candidate, EvaluationCache, Result}
  alias Imp.Optimizer.GEPA.EvaluationCache.Codec
  alias Imp.Optimizer.Report

  @artifact_type "imp_gepa_evaluation_cache_entry"
  @schema_version 1
  @artifact_keys MapSet.new([
                   "artifact_type",
                   "schema_version",
                   "identity",
                   "payload_sha256",
                   "payload"
                 ])
  @payload_keys MapSet.new(["output", "score", "objective_scores"])

  @enforce_keys [:root]
  defstruct [:root]

  @type t :: %__MODULE__{root: Path.t()}

  @doc "Opens a durable cache under the supplied run directory."
  @spec new(Path.t() | keyword()) :: t()
  def new(run_dir) when is_binary(run_dir), do: new(run_dir: run_dir)

  def new(opts) when is_list(opts) do
    run_dir = opts |> Keyword.fetch!(:run_dir) |> Path.expand()

    # Cache entries are keyed only by candidate and example, so a reused
    # run_dir with a different configuration (model, params, metric) would
    # replay stale scores. An identity term partitions the cache per
    # configuration; runs without one share the historical "default" root.
    identity_segment =
      case Keyword.get(opts, :identity) do
        nil -> []
        identity -> [Codec.digest(identity)]
      end

    root = Path.join([run_dir, "evaluation_cache", "v#{@schema_version}"] ++ identity_segment)
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    %__MODULE__{root: root}
  end

  @doc "Returns the content-addressed path for a candidate/example pair."
  @spec entry_path(t(), Candidate.t(), term()) :: Path.t()
  def entry_path(%__MODULE__{} = cache, candidate, example) do
    {_candidate_digest, _example_digest, entry_digest} = identity(candidate, example)
    Path.join([cache.root, String.slice(entry_digest, 0, 2), entry_digest <> ".json"])
  end

  @impl true
  def lookup(%__MODULE__{} = cache, candidate, examples) when is_list(examples) do
    candidate_digest = candidate |> Candidate.validate!() |> Codec.digest()

    examples
    |> Enum.with_index()
    |> Enum.reduce({%{}, []}, fn {example, index}, {hits, misses} ->
      example_digest = Codec.digest(example)

      case fetch_entry(cache, candidate_digest, example_digest) do
        {:ok, entry} -> {Map.put(hits, index, entry), misses}
        {:error, _reason} -> {hits, [index | misses]}
      end
    end)
    |> then(fn {hits, misses} -> {hits, Enum.reverse(misses)} end)
  end

  @impl true
  def put(%__MODULE__{} = cache, candidate, examples, %Result{} = result)
      when is_list(examples) do
    candidate = Candidate.validate!(candidate)
    result = Result.validate!(result, length(examples), candidate, false)
    candidate_digest = Codec.digest(candidate)
    objective_scores = result.objective_scores || List.duplicate(nil, length(examples))

    examples
    |> Enum.zip(result.outputs)
    |> Enum.zip(result.scores)
    |> Enum.zip(objective_scores)
    |> Enum.each(fn {{{example, output}, score}, objectives} ->
      example_digest = Codec.digest(example)
      write_entry(cache, candidate_digest, example_digest, output, score, objectives)
    end)

    cache
  end

  @impl true
  def assemble(examples, hits, missing_indexes, missing_result),
    do: EvaluationCache.assemble(examples, hits, missing_indexes, missing_result)

  defp write_entry(cache, candidate_digest, example_digest, output, score, objectives) do
    entry_digest = entry_digest(candidate_digest, example_digest)
    path = path(cache, entry_digest)
    payload = payload(output, score, objectives)
    artifact = artifact(candidate_digest, example_digest, entry_digest, payload)
    encoded = Codec.canonical_json!(artifact) <> "\n"
    File.mkdir_p!(Path.dirname(path))

    lock = {{__MODULE__, path}, self()}

    case :global.trans(
           lock,
           fn -> publish_entry(cache, candidate_digest, example_digest, path, encoded) end
         ) do
      :ok -> :ok
      {:aborted, reason} -> raise "GEPA disk cache lock aborted: #{inspect(reason)}"
    end
  end

  defp publish_entry(cache, candidate_digest, example_digest, path, encoded) do
    case fetch_entry(cache, candidate_digest, example_digest) do
      {:ok, _entry} -> :ok
      {:error, _reason} -> atomic_write!(path, encoded)
    end
  end

  defp fetch_entry(cache, candidate_digest, example_digest) do
    entry_digest = entry_digest(candidate_digest, example_digest)

    with {:ok, encoded} <- File.read(path(cache, entry_digest)),
         {:ok, artifact} <- Jason.decode(encoded),
         :ok <- validate_artifact(artifact, candidate_digest, example_digest, entry_digest),
         {:ok, entry} <- restore_entry(artifact["payload"]) do
      {:ok, entry}
    else
      {:error, :enoent} -> {:error, :miss}
      _invalid -> {:error, :invalid}
    end
  rescue
    _error -> {:error, :invalid}
  catch
    _kind, _reason -> {:error, :invalid}
  end

  defp validate_artifact(artifact, candidate_digest, example_digest, entry_digest)
       when is_map(artifact) do
    with :ok <- exact_keys(artifact, @artifact_keys),
         :ok <- validate_header(artifact),
         :ok <-
           validate_identity(artifact["identity"], candidate_digest, example_digest, entry_digest) do
      validate_payload(artifact["payload"], artifact["payload_sha256"])
    end
  end

  defp validate_artifact(_artifact, _candidate_digest, _example_digest, _entry_digest),
    do: {:error, :invalid}

  defp validate_header(%{
         "artifact_type" => @artifact_type,
         "schema_version" => @schema_version
       }),
       do: :ok

  defp validate_header(_artifact), do: {:error, :invalid}

  defp validate_identity(identity, candidate_digest, example_digest, entry_digest) do
    expected = %{
      "candidate_sha256" => candidate_digest,
      "example_sha256" => example_digest,
      "entry_sha256" => entry_digest
    }

    if identity == expected, do: :ok, else: {:error, :invalid}
  end

  defp validate_payload(payload, checksum) when is_map(payload) do
    case exact_keys(payload, @payload_keys) do
      :ok ->
        if secure_equal?(checksum, Codec.checksum(payload)),
          do: :ok,
          else: {:error, :invalid}

      {:error, :invalid} = error ->
        error
    end
  end

  defp validate_payload(_payload, _checksum), do: {:error, :invalid}

  defp exact_keys(map, keys) do
    if MapSet.equal?(MapSet.new(Map.keys(map)), keys), do: :ok, else: {:error, :invalid}
  end

  defp restore_entry(payload) do
    output = Report.decode_term(payload["output"])
    objectives = Report.decode_term(payload["objective_scores"])
    score = payload["score"]

    if is_number(score) and valid_objectives?(objectives) do
      {:ok,
       %EvaluationCache.Entry{
         output: output,
         score: score,
         objective_scores: objectives
       }}
    else
      {:error, :invalid}
    end
  end

  defp valid_objectives?(nil), do: true

  defp valid_objectives?(objectives) when is_map(objectives) do
    Enum.all?(objectives, fn {name, score} ->
      (is_atom(name) or is_binary(name)) and is_number(score)
    end)
  end

  defp valid_objectives?(_objectives), do: false

  defp artifact(candidate_digest, example_digest, entry_digest, payload) do
    %{
      "artifact_type" => @artifact_type,
      "schema_version" => @schema_version,
      "identity" => %{
        "candidate_sha256" => candidate_digest,
        "example_sha256" => example_digest,
        "entry_sha256" => entry_digest
      },
      "payload_sha256" => Codec.checksum(payload),
      "payload" => payload
    }
  end

  defp payload(output, score, objective_scores) do
    %{
      "output" => Report.encode_term(output),
      "score" => score,
      "objective_scores" => Report.encode_term(objective_scores)
    }
  end

  defp identity(candidate, example) do
    candidate_digest = candidate |> Candidate.validate!() |> Codec.digest()
    example_digest = Codec.digest(example)
    {candidate_digest, example_digest, entry_digest(candidate_digest, example_digest)}
  end

  defp entry_digest(candidate_digest, example_digest) do
    Codec.digest(%{
      "artifact_type" => @artifact_type,
      "schema_version" => @schema_version,
      "candidate_sha256" => candidate_digest,
      "example_sha256" => example_digest
    })
  end

  defp path(cache, entry_digest) do
    Path.join([cache.root, String.slice(entry_digest, 0, 2), entry_digest <> ".json"])
  end

  defp atomic_write!(path, encoded) do
    temporary = path <> ".tmp-" <> random_suffix()
    io = File.open!(temporary, [:write, :binary, :exclusive])

    try do
      File.chmod!(temporary, 0o600)
      :ok = IO.binwrite(io, encoded)
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

  defp random_suffix do
    12
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_equal?(_left, _right), do: false
end
