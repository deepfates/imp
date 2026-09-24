defmodule MultimodalQualityBenchmarkTest do
  use ExUnit.Case, async: false

  alias Imp.BenchmarkTruth.MultimodalCheckpoint, as: Checkpoint
  alias Imp.BenchmarkTruth.MultimodalManifest, as: Manifest
  alias Imp.BenchmarkTruth.MultimodalRunner, as: Runner
  alias Imp.Test.LocalHTTP

  @manifest "benchmarks/data/multimodal/manifest.json"
  @openai_manifest "benchmarks/data/multimodal/openai-responses-manifest.json"
  @secret "openai-test-secret-that-must-never-persist"

  defmodule UnsafeProviderError do
    defexception [:message, :status, :response_body]
  end

  defmodule ProviderFailureFake do
    def generate_text(_model, _messages, opts) do
      {:error,
       %UnsafeProviderError{
         message: "provider rejected credential #{Keyword.fetch!(opts, :api_key)}",
         status: 400,
         response_body: ["improper" | :tail]
       }}
    end
  end

  test "plan records only redacted pre-dispatch intent and makes no claim" do
    artifact = Runner.run(mode: :plan, manifest: @openai_manifest, max_concurrency: 2)

    assert artifact["mode"] == "plan"

    assert artifact["summary"] == %{
             "complete" => true,
             "dispatched" => 0,
             "failed" => 6,
             "passed" => 0,
             "resumed" => 0,
             "rows" => 6,
             "samples" => 6,
             "written" => 0
           }

    refute artifact["claims"]["multimodal_quality"]
    refute artifact["input_evidence"]["pre_dispatch_intents_authorize_claims"]
    assert "mode_is_not_live" in artifact["claim_gate"]["rejections"]

    encoded = Jason.encode!(artifact)
    refute encoded =~ "data:image"
    refute encoded =~ "base64"
  end

  test "real ReqLLM serialization records redacted image and native PDF proof" do
    {base_url, request_pid} = start_openai_fixture()

    artifact =
      local_live_run(tmp_path("serialized-audit.json"), base_url, max_concurrency: 2)

    assert artifact["summary"] == %{
             "complete" => true,
             "dispatched" => 6,
             "failed" => 0,
             "passed" => 6,
             "resumed" => 0,
             "rows" => 6,
             "samples" => 6,
             "written" => 6
           }

    refute artifact["claims"]["multimodal_quality"]
    assert artifact["claim_gate"]["rejections"] == ["serialized_endpoint_mismatch"]

    assert artifact["usage"] == %{
             "cache_classification" => "provider_reported",
             "cached_input_tokens" => 60,
             "cost" => %{
               "cached_input_nano_usd" => 6_000,
               "classification" => "exact_from_provider_usage",
               "exact" => true,
               "output_nano_usd" => 48_000,
               "total_nano_usd" => 270_000,
               "total_usd" => "0.000270000",
               "uncached_input_nano_usd" => 216_000
             },
             "input_tokens" => 600,
             "output_tokens" => 30,
             "total_tokens" => 630,
             "uncached_input_tokens" => 540
           }

    assert Enum.all?(artifact["rows"], fn row ->
             request = row["audit"]["request"]
             response = row["audit"]["response"]

             row["outcome"] == "passed" and row["dispatch"]["count"] == 1 and
               is_binary(row["dispatch"]["req_llm_request_id"]) and
               request["serialization_boundary"] ==
                 "Req request step after ReqLLM provider encode_body and before transport" and
               request["dependency"] ==
                 artifact["provider"]["req_llm_dependency"] and
               request["ordered_part_types"] in [
                 ["input_image", "input_text"],
                 ["input_file", "input_text"]
               ] and
               response["usage"]["source"] ==
                 "response.usage.input_tokens_details.cached_tokens" and
               is_binary(row["provider"]["provider_response_id"]) and
               is_nil(row["provider"]["provider_request_id"]) and
               row["provider"]["provider_id_limitation"] ==
                 "provider request ID not exposed"
           end)

    requests = collect_requests(request_pid, 6)
    assert Enum.all?(requests, &(&1.path == "/v1/responses" and &1.method == "POST"))

    ordered_types =
      Enum.map(requests, fn request ->
        request.body
        |> Jason.decode!()
        |> Map.fetch!("input")
        |> List.first()
        |> Map.fetch!("content")
        |> Enum.map(& &1["type"])
      end)

    assert Enum.count(ordered_types, &(&1 == ["input_image", "input_text"])) == 4
    assert Enum.count(ordered_types, &(&1 == ["input_file", "input_text"])) == 2

    encoded = Jason.encode!(artifact)
    refute encoded =~ @secret
    refute encoded =~ "data:image/png;base64"
    refute encoded =~ Base.encode64(File.read!("benchmarks/data/multimodal/project-register.pdf"))
  end

  test "six authenticated family and score rows are rejected by the exact row schema" do
    manifest = Manifest.load!(@openai_manifest)
    bindings = Manifest.sample_bindings(manifest.payload)
    identity = checkpoint_identity(manifest)
    path = tmp_path("minimal-forgery.json")
    checkpoint = Checkpoint.load!(path, identity, bindings)

    minimal_rows =
      Map.new(manifest.payload["samples"], fn sample ->
        {sample["id"], %{"family" => sample["family"], "score" => 1.0}}
      end)

    checkpoint
    |> Map.put("completed", minimal_rows)
    |> write_authenticated_checkpoint!(path)

    assert_raise ArgumentError, ~r/inexact schema/, fn ->
      Checkpoint.load!(path, identity, bindings)
    end
  end

  test "recomputed unkeyed SHA cannot authenticate a tampered checkpoint" do
    manifest = Manifest.load!(@openai_manifest)
    bindings = Manifest.sample_bindings(manifest.payload)
    identity = checkpoint_identity(manifest)
    path = tmp_path("unkeyed-tamper.json")
    Checkpoint.load!(path, identity, bindings)

    envelope = path |> File.read!() |> Jason.decode!()
    payload = put_in(envelope, ["payload", "identity", "campaign_id"], "forged-campaign")

    payload =
      Map.put(payload, "payload_sha256", Checkpoint.recompute_payload_sha256(payload["payload"]))

    File.write!(path, Jason.encode!(payload, pretty: true))

    assert_raise ArgumentError, ~r/authentication mismatch/, fn ->
      Checkpoint.load!(path, identity, bindings)
    end
  end

  test "checkpoint cannot be resumed against a different checksummed manifest" do
    openai = Manifest.load!(@openai_manifest)
    google = Manifest.load!(@manifest)
    path = tmp_path("cross-manifest.json")

    Checkpoint.load!(path, checkpoint_identity(openai), Manifest.sample_bindings(openai.payload))

    assert_raise ArgumentError, ~r/campaign identity mismatch/, fn ->
      Checkpoint.load!(
        path,
        checkpoint_identity(google),
        Manifest.sample_bindings(google.payload)
      )
    end
  end

  test "the campaign records the loaded ReqLLM package and a checkpoint cannot resume under another" do
    manifest = Manifest.load!(@openai_manifest)
    refute Map.has_key?(manifest.payload["provider"], "req_llm_dependency")

    loaded = Application.spec(:req_llm, :vsn) |> to_string()
    {:hex, :req_llm, ^loaded, package_sha256, _, _, "hexpm", _} = Mix.Dep.Lock.read()[:req_llm]

    assert Manifest.runtime_dependency!() == %{
             "package" => "req_llm",
             "package_sha256" => package_sha256,
             "source" => "hexpm",
             "version" => loaded
           }

    artifact = Runner.run(mode: :plan, manifest: @openai_manifest, max_concurrency: 1)
    assert artifact["provider"]["req_llm_dependency"] == Manifest.runtime_dependency!()

    path = tmp_path("other-req-llm.json")
    bindings = Manifest.sample_bindings(manifest.payload)
    identity = checkpoint_identity(manifest)
    Checkpoint.load!(path, identity, bindings)

    other_build =
      put_in(identity, ["provider", "req_llm_dependency", "version"], "0.0.0-other")

    assert_raise ArgumentError, ~r/campaign identity mismatch/, fn ->
      Checkpoint.load!(path, other_build, bindings)
    end
  end

  test "duplicate provider response IDs are rejected before checkpoint completion" do
    {base_url, _request_pid} = start_openai_fixture(response_id: "resp_duplicated")

    assert_raise ArgumentError, ~r/duplicate multimodal checkpoint provider response IDs/, fn ->
      local_live_run(tmp_path("duplicate-response.json"), base_url, max_concurrency: 1)
    end
  end

  test "authenticated duplicate dispatch evidence is rejected on resume" do
    {base_url, _request_pid} = start_openai_fixture()
    path = tmp_path("duplicate-dispatch.json")
    local_live_run(path, base_url, max_concurrency: 1)

    envelope = path |> File.read!() |> Jason.decode!()
    payload = envelope["payload"]
    [first_id, second_id | _] = payload["completed"] |> Map.keys() |> Enum.sort()
    dispatch_id = get_in(payload, ["completed", first_id, "dispatch", "req_llm_request_id"])

    payload =
      payload
      |> put_in(["completed", second_id, "dispatch", "req_llm_request_id"], dispatch_id)
      |> put_in(["completed", second_id, "audit", "request", "req_llm_request_id"], dispatch_id)

    write_authenticated_checkpoint!(payload, path)
    manifest = Manifest.load!(@openai_manifest)

    assert_raise ArgumentError, ~r/duplicate multimodal checkpoint dispatch evidence/, fn ->
      Checkpoint.load!(
        path,
        checkpoint_identity(manifest),
        Manifest.sample_bindings(manifest.payload)
      )
    end
  end

  test "an authenticated passing row with a wrong answer is rejected" do
    {base_url, _request_pid} = start_openai_fixture()
    path = tmp_path("wrong-row.json")
    local_live_run(path, base_url, max_concurrency: 1)

    envelope = path |> File.read!() |> Jason.decode!()
    payload = envelope["payload"]
    [sample_id | _] = payload["completed"] |> Map.keys() |> Enum.sort()
    payload = put_in(payload, ["completed", sample_id, "answer"], "forged-wrong-answer")
    write_authenticated_checkpoint!(payload, path)

    manifest = Manifest.load!(@openai_manifest)

    assert_raise ArgumentError, ~r/lacks exact dispatch\/usage\/outcome proof/, fn ->
      Checkpoint.load!(
        path,
        checkpoint_identity(manifest),
        Manifest.sample_bindings(manifest.payload)
      )
    end
  end

  test "missing cache classification prevents exact cost and passing rows" do
    {base_url, _request_pid} = start_openai_fixture(cache_classification: :missing)
    artifact = local_live_run(tmp_path("missing-cache.json"), base_url)

    assert artifact["summary"]["dispatched"] == 6
    assert artifact["summary"]["passed"] == 0
    assert artifact["usage"]["cache_classification"] == "incomplete"
    refute artifact["usage"]["cost"]["exact"]
    assert artifact["usage"]["cost"]["total_usd"] == nil

    assert Enum.all?(artifact["rows"], fn row ->
             row["outcome"] == "usage_unclassified" and
               row["failure"] == "cached_input_classification_missing" and
               row["usage"]["cached_input_tokens"] == nil and
               row["cost"]["classification"] ==
                 "unavailable_without_cached_input_classification" and
               row["cost"]["exact"] == false
           end)
  end

  test "durable completed rows resume without being counted as new dispatches" do
    {base_url, request_pid} = start_openai_fixture()
    checkpoint = tmp_path("crash-resume.json")

    assert_raise RuntimeError, ~r/injected multimodal runner crash/, fn ->
      local_live_run(checkpoint, base_url, max_concurrency: 1, crash_after_rows: 1)
    end

    assert length(collect_requests(request_pid, 1)) == 1

    artifact = local_live_run(checkpoint, base_url, max_concurrency: 1)

    assert artifact["summary"]["rows"] == 6
    assert artifact["summary"]["passed"] == 6
    assert artifact["summary"]["resumed"] == 1
    assert artifact["summary"]["dispatched"] == 5
    assert artifact["summary"]["written"] == 5
    assert length(collect_requests(request_pid, 5)) == 5
    refute_received {:serialized_request, ^request_pid, _request}
  end

  test "provider exception details remain structured and credential-redacted" do
    artifact =
      Runner.run(
        api_key: @secret,
        checkpoint: tmp_path("structured-provider-error.json"),
        manifest: @openai_manifest,
        mode: :live,
        req_module: ProviderFailureFake
      )

    assert artifact["summary"]["dispatched"] == 0
    assert Enum.all?(artifact["rows"], &(&1["outcome"] == "provider_error"))

    assert Enum.all?(artifact["rows"], fn row ->
             row["failure"] == %{
               "category" => "MultimodalQualityBenchmarkTest.UnsafeProviderError",
               "exception" => "MultimodalQualityBenchmarkTest.UnsafeProviderError",
               "http_status" => 400,
               "message" => "provider rejected credential [REDACTED]",
               "provider_code" => nil,
               "request_id" => nil
             }
           end)

    refute Jason.encode!(artifact) =~ @secret
  end

  test "asset drift and checksummed manifest tampering fail before dispatch" do
    manifest = Manifest.load!(@openai_manifest)

    drifted =
      put_in(manifest.payload, ["assets", "shape_board", "sha256"], String.duplicate("0", 64))

    assert_raise ArgumentError, ~r/asset drift detected/, fn -> Manifest.validate!(drifted) end

    tampered_path = tmp_path("tampered-manifest.json")

    @openai_manifest
    |> File.read!()
    |> String.replace("image_shape_count_blue_circles", "image_shape_count_blue_circlez",
      global: false
    )
    |> then(&File.write!(tampered_path, &1))

    assert_raise ArgumentError, ~r/manifest checksum mismatch/, fn ->
      Manifest.load!(tampered_path)
    end
  end

  defp local_live_run(checkpoint, base_url, opts \\ []) do
    Runner.run(
      [
        api_key: @secret,
        checkpoint: checkpoint,
        client_opts: [base_url: base_url <> "/v1"],
        manifest: @openai_manifest,
        mode: :live
      ] ++ opts
    )
  end

  defp start_openai_fixture(opts \\ []) do
    owner = self()
    request_pid = make_ref()
    fixed_response_id = Keyword.get(opts, :response_id)
    cache_classification = Keyword.get(opts, :cache_classification, :reported)

    base_url =
      LocalHTTP.start(fn request ->
        send(owner, {:serialized_request, request_pid, request})
        body = Jason.decode!(request.body)
        answer = body |> request_prompt() |> expected_answer()

        response_id =
          fixed_response_id || "resp_fixture_#{System.unique_integer([:positive, :monotonic])}"

        usage = %{
          "input_tokens" => 100,
          "output_tokens" => 5,
          "total_tokens" => 105
        }

        usage =
          if cache_classification == :reported,
            do: Map.put(usage, "input_tokens_details", %{"cached_tokens" => 10}),
            else: usage

        {200,
         %{
           "created_at" => 1_752_444_800,
           "id" => response_id,
           "model" => "gpt-4.1-mini-2025-04-14",
           "object" => "response",
           "output" => [
             %{
               "content" => [
                 %{
                   "annotations" => [],
                   "text" => Jason.encode!(%{"answer" => answer}),
                   "type" => "output_text"
                 }
               ],
               "id" => "msg_#{response_id}",
               "role" => "assistant",
               "status" => "completed",
               "type" => "message"
             }
           ],
           "status" => "completed",
           "usage" => usage
         }}
      end)

    {base_url, request_pid}
  end

  defp request_prompt(body) do
    body
    |> Map.fetch!("input")
    |> Enum.flat_map(&List.wrap(&1["content"]))
    |> Enum.find_value(fn
      %{"type" => "input_text", "text" => text} -> text
      _part -> nil
    end)
  end

  defp expected_answer(text) do
    cond do
      String.contains?(text, "How many blue circles") -> 3
      String.contains?(text, "left or right") -> "left"
      String.contains?(text, "BATCH CODE") -> "MINT-47"
      String.contains?(text, "BIN value") -> "C-12"
      String.contains?(text, "sum their Units") -> 35
      String.contains?(text, "which owner") -> "Priya"
    end
  end

  defp collect_requests(request_pid, count) do
    Enum.map(1..count, fn _ ->
      assert_receive {:serialized_request, ^request_pid, request}, 2_000
      request
    end)
  end

  defp checkpoint_identity(manifest) do
    manifest = Manifest.bind_runtime_dependency!(manifest)
    provider = manifest.payload["provider"]

    %{
      "campaign_id" => manifest.payload["campaign_id"],
      "checkpoint_schema_version" => 2,
      "generation" => provider["generation"],
      "manifest_sha256" => manifest.sha256,
      "provider" =>
        Map.take(
          provider,
          ~w(api endpoint model name pricing profile req_llm_dependency req_llm_model)
        ),
      "sample_set_sha256" =>
        manifest.payload
        |> Manifest.sample_bindings()
        |> Jason.encode!()
        |> sha256()
    }
  end

  defp write_authenticated_checkpoint!(payload, path) do
    key = File.read!(Checkpoint.key_path(path))

    tag =
      :crypto.mac(:hmac, :sha256, key, :erlang.term_to_binary(payload, [:deterministic]))
      |> Base.encode16(case: :lower)

    envelope = %{
      "authentication" => %{
        "algorithm" => "hmac-sha256",
        "key_id" => sha256(key),
        "tag" => tag
      },
      "payload" => payload,
      "payload_sha256" => Checkpoint.recompute_payload_sha256(payload)
    }

    File.write!(path, Jason.encode!(envelope, pretty: true) <> "\n")
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp tmp_path(name) do
    dir = Path.join(System.tmp_dir!(), "imp-multimodal-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    on_exit(fn -> File.rm_rf(dir) end)
    path
  end
end
