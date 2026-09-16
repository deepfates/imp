defmodule Imp.BenchmarkTruth.MultimodalManifest do
  @moduledoc false

  @payload_keys ~w(assets campaign_id claim_policy created_at limitations provider samples schema_version scoring signature)
  @provider_keys ~w(api capabilities credential_env endpoint generation identity_evidence model name pricing profile req_llm_dependency req_llm_model)
  @required_generation_keys ~w(max_tokens timeout_ms)
  @optional_generation_keys ~w(seed temperature top_p)
  @pricing_keys ~w(as_of cached_input_nano_usd_per_token cached_input_usd_per_1m currency input_nano_usd_per_token input_usd_per_1m output_nano_usd_per_token output_usd_per_1m pricing_basis source)
  @req_llm_dependency_keys ~w(package package_sha256 repository source source_revision version)
  @signature_keys ~w(input output output_schema prompt_contract)
  @scoring_keys ~w(family_thresholds normalization scorer)
  @claim_keys ~w(document_family image_family required_families)
  @asset_keys ~w(bytes mime_type path sha256)
  @sample_keys ~w(asset_ids delivery expected_capability family gold id prompt)
  @deliveries ~w(typed_image_data_uri typed_native_file)
  @req_llm_dependency %{
    "package" => "req_llm",
    "package_sha256" => "d610d4de14c7ef697a2aa4c30eada4e1ae172bec08bb3dea3bbe25f20feb5d40",
    "repository" => "https://github.com/agentjido/req_llm",
    "source" => "hexpm",
    "source_revision" => "9aa98a4e02da5083464d2eed268f48272f0d7180",
    "version" => "1.18.0"
  }
  @provider_profiles %{
    "google-gemini-2.5-flash-generate-content" => %{
      "api" => "generateContent",
      "capabilities" => %{"audio" => false, "image_input" => true, "native_pdf" => true},
      "credential_env" => "GEMINI_API_KEY",
      "endpoint" =>
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
      "identity_evidence" => "serialized_request_and_provider_id_if_available",
      "model" => "gemini-2.5-flash",
      "name" => "google",
      "pricing" => %{
        "as_of" => "2026-07-13",
        "cached_input_nano_usd_per_token" => 30,
        "cached_input_usd_per_1m" => "0.03",
        "currency" => "USD",
        "input_nano_usd_per_token" => 300,
        "input_usd_per_1m" => "0.30",
        "output_nano_usd_per_token" => 2500,
        "output_usd_per_1m" => "2.50",
        "pricing_basis" => "standard_text_image_video",
        "source" => "https://ai.google.dev/gemini-api/docs/pricing"
      },
      "req_llm_dependency" => @req_llm_dependency,
      "req_llm_model" => "google:gemini-2.5-flash"
    },
    "openai-gpt-4.1-mini-2025-04-14-responses" => %{
      "api" => "responses",
      "capabilities" => %{"audio" => false, "image_input" => true, "native_pdf" => true},
      "credential_env" => "OPENAI_API_KEY",
      "endpoint" => "https://api.openai.com/v1/responses",
      "identity_evidence" => "serialized_request_and_provider_response_id_required",
      "model" => "gpt-4.1-mini-2025-04-14",
      "name" => "openai",
      "pricing" => %{
        "as_of" => "2026-07-13",
        "cached_input_nano_usd_per_token" => 100,
        "cached_input_usd_per_1m" => "0.10",
        "currency" => "USD",
        "input_nano_usd_per_token" => 400,
        "input_usd_per_1m" => "0.40",
        "output_nano_usd_per_token" => 1600,
        "output_usd_per_1m" => "1.60",
        "pricing_basis" => "standard",
        "source" => "https://developers.openai.com/api/docs/models/gpt-4.1-mini"
      },
      "req_llm_dependency" => @req_llm_dependency,
      "req_llm_model" => "openai:gpt-4.1-mini-2025-04-14"
    }
  }

  def load!(path, opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!()) |> Path.expand()

    envelope = path |> File.read!() |> Jason.decode!()
    exact_keys!(envelope, ~w(payload payload_sha256), "manifest envelope")

    payload = Map.fetch!(envelope, "payload")
    expected = Map.fetch!(envelope, "payload_sha256")
    actual = sha256(Jason.encode!(payload))

    unless secure_equal?(expected, actual) do
      raise ArgumentError, "multimodal manifest checksum mismatch"
    end

    validate!(payload, root: root)
    %{payload: payload, sha256: actual, path: Path.expand(path)}
  end

  def validate!(payload, opts \\ []) when is_map(payload) do
    root = Keyword.get(opts, :root, File.cwd!()) |> Path.expand()
    exact_keys!(payload, @payload_keys, "manifest payload")

    require_equal!(payload["schema_version"], 2, "schema_version")
    require_string!(payload["campaign_id"], "campaign_id")
    require_string!(payload["created_at"], "created_at")

    validate_provider!(payload["provider"])
    validate_signature!(payload["signature"])
    validate_scoring!(payload["scoring"])
    validate_claim_policy!(payload["claim_policy"], payload["scoring"])
    assets = validate_assets!(payload["assets"], root)
    validate_samples!(payload["samples"], assets, payload["provider"])

    unless is_list(payload["limitations"]) and
             Enum.all?(payload["limitations"], &is_binary/1) do
      raise ArgumentError, "limitations must be a list of strings"
    end

    payload
  end

  def payload_sha256(payload), do: sha256(Jason.encode!(payload))

  def sample_bindings(payload) when is_map(payload) do
    Map.new(payload["samples"], fn sample ->
      assets =
        Enum.map(sample["asset_ids"], fn asset_id ->
          asset = Map.fetch!(payload["assets"], asset_id)

          %{
            "asset_id" => asset_id,
            "bytes" => asset["bytes"],
            "mime_type" => asset["mime_type"],
            "sha256" => asset["sha256"]
          }
        end)

      binding = %{
        "assets" => assets,
        "delivery" => sample["delivery"],
        "expected_capability" => sample["expected_capability"],
        "expected_output" => sample["gold"],
        "family" => sample["family"],
        "prompt_bytes" => byte_size(sample["prompt"]),
        "prompt_sha256" => sha256(sample["prompt"]),
        "sample_id" => sample["id"],
        "sample_sha256" => sha256(Jason.encode!(sample))
      }

      {sample["id"], binding}
    end)
  end

  def runtime_dependency!(payload) when is_map(payload) do
    dependency = payload["provider"]["req_llm_dependency"]

    runtime_version =
      case Application.spec(:req_llm, :vsn) do
        nil -> raise ArgumentError, "ReqLLM runtime dependency is not loaded"
        version -> to_string(version)
      end

    require_equal!(runtime_version, dependency["version"], "ReqLLM runtime version")
    dependency
  end

  def profiles, do: Map.keys(@provider_profiles) |> Enum.sort()

  defp validate_provider!(provider) do
    exact_keys!(provider, @provider_keys, "provider")
    profile = Map.get(@provider_profiles, provider["profile"])

    unless profile do
      raise ArgumentError,
            "unknown multimodal provider profile #{inspect(provider["profile"])}; expected one of #{inspect(profiles())}"
    end

    profile
    |> Map.drop(["capabilities"])
    |> Enum.each(fn {key, expected} ->
      require_equal!(provider[key], expected, "provider.#{key}")
    end)

    capabilities = provider["capabilities"]
    exact_keys!(capabilities, ~w(audio image_input native_pdf), "provider.capabilities")

    Enum.each(profile["capabilities"], fn {key, expected} ->
      require_equal!(capabilities[key], expected, "capabilities.#{key}")
    end)

    generation = provider["generation"]
    generation_keys = Map.keys(generation)

    unless Enum.all?(@required_generation_keys, &(&1 in generation_keys)) and
             Enum.all?(
               generation_keys,
               &(&1 in (@required_generation_keys ++ @optional_generation_keys))
             ) do
      raise ArgumentError,
            "provider.generation must contain #{inspect(@required_generation_keys)} and only supported optional keys #{inspect(@optional_generation_keys)}"
    end

    require_positive_integer!(generation["max_tokens"], "generation.max_tokens")
    require_positive_integer!(generation["timeout_ms"], "generation.timeout_ms")
    maybe_require_number!(generation, "temperature")
    maybe_require_number!(generation, "top_p")
    maybe_require_integer!(generation, "seed")

    exact_keys!(provider["pricing"], @pricing_keys, "provider.pricing")
    pricing = provider["pricing"]
    require_equal!(pricing["currency"], "USD", "pricing.currency")
    require_positive_integer!(pricing["input_nano_usd_per_token"], "input token price")

    require_positive_integer!(
      pricing["cached_input_nano_usd_per_token"],
      "cached input token price"
    )

    require_positive_integer!(pricing["output_nano_usd_per_token"], "output token price")

    Enum.each(
      ~w(input_usd_per_1m cached_input_usd_per_1m output_usd_per_1m pricing_basis source as_of),
      fn key ->
        require_string!(pricing[key], "pricing.#{key}")
      end
    )

    exact_keys!(provider["req_llm_dependency"], @req_llm_dependency_keys, "req_llm_dependency")
    require_equal!(provider["req_llm_dependency"], @req_llm_dependency, "req_llm_dependency")
  end

  defp validate_signature!(signature) do
    exact_keys!(signature, @signature_keys, "signature")

    Enum.each(
      ~w(input output prompt_contract),
      &require_string!(signature[&1], "signature.#{&1}")
    )

    require_equal!(
      signature["output_schema"],
      %{"answer" => "string_or_integer"},
      "output_schema"
    )
  end

  defp validate_scoring!(scoring) do
    exact_keys!(scoring, @scoring_keys, "scoring")
    require_equal!(scoring["scorer"], "exact_match", "scoring.scorer")
    require_equal!(scoring["normalization"], ["trim", "unicode_lowercase"], "normalization")

    thresholds = scoring["family_thresholds"]
    exact_keys!(thresholds, ~w(image native_document), "family_thresholds")

    Enum.each(thresholds, fn {family, threshold} ->
      unless is_number(threshold) and threshold >= 0 and threshold <= 1 do
        raise ArgumentError, "threshold for #{family} must be between 0 and 1"
      end
    end)
  end

  defp validate_claim_policy!(policy, scoring) do
    exact_keys!(policy, @claim_keys, "claim_policy")
    require_equal!(policy["image_family"], "image", "claim_policy.image_family")
    require_equal!(policy["document_family"], "native_document", "claim_policy.document_family")
    require_equal!(policy["required_families"], ["image", "native_document"], "required_families")

    unless Map.keys(scoring["family_thresholds"]) |> Enum.sort() ==
             Enum.sort(policy["required_families"]) do
      raise ArgumentError, "family thresholds must exactly match required claim families"
    end
  end

  defp validate_assets!(assets, root) when is_map(assets) and map_size(assets) > 0 do
    Map.new(assets, fn {id, asset} ->
      require_string!(id, "asset id")
      exact_keys!(asset, @asset_keys, "asset #{id}")
      Enum.each(~w(path mime_type sha256), &require_string!(asset[&1], "asset #{id}.#{&1}"))
      require_positive_integer!(asset["bytes"], "asset #{id}.bytes")

      path = confined_path!(root, asset["path"])
      bytes = File.read!(path)

      unless byte_size(bytes) == asset["bytes"] and sha256(bytes) == asset["sha256"] do
        raise ArgumentError, "multimodal asset drift detected for #{id}"
      end

      {id, Map.put(asset, "absolute_path", path)}
    end)
  end

  defp validate_assets!(_assets, _root),
    do: raise(ArgumentError, "assets must be a non-empty map")

  defp validate_samples!(samples, assets, provider) when is_list(samples) and samples != [] do
    ids = Enum.map(samples, & &1["id"])
    if Enum.uniq(ids) != ids, do: raise(ArgumentError, "sample ids must be unique")

    Enum.each(samples, fn sample ->
      exact_keys!(sample, @sample_keys, "sample")

      Enum.each(~w(id family prompt delivery expected_capability), fn key ->
        require_string!(sample[key], "sample.#{key}")
      end)

      unless sample["family"] in ~w(image native_document),
        do: raise(ArgumentError, "unsupported sample family #{inspect(sample["family"])}")

      unless sample["delivery"] in @deliveries,
        do: raise(ArgumentError, "unsupported delivery #{inspect(sample["delivery"])}")

      unless is_list(sample["asset_ids"]) and sample["asset_ids"] != [] and
               Enum.all?(sample["asset_ids"], &Map.has_key?(assets, &1)) do
        raise ArgumentError, "sample #{sample["id"]} references unknown assets"
      end

      capability = sample["expected_capability"]

      unless provider["capabilities"][capability] == true do
        raise ArgumentError,
              "sample #{sample["id"]} requires unsupported capability #{capability}"
      end

      validate_family_delivery!(sample)

      unless is_binary(sample["gold"]) or is_integer(sample["gold"]),
        do: raise(ArgumentError, "sample #{sample["id"]} gold must be a string or integer")
    end)
  end

  defp validate_samples!(_samples, _assets, _provider),
    do: raise(ArgumentError, "samples must be a non-empty list")

  defp validate_family_delivery!(%{
         "family" => "image",
         "delivery" => "typed_image_data_uri",
         "expected_capability" => "image_input",
         "asset_ids" => [_]
       }),
       do: :ok

  defp validate_family_delivery!(%{
         "family" => "native_document",
         "delivery" => "typed_native_file",
         "expected_capability" => "native_pdf",
         "asset_ids" => [_]
       }),
       do: :ok

  defp validate_family_delivery!(sample) do
    raise ArgumentError,
          "sample #{sample["id"]} has an ambiguous family/delivery/capability combination"
  end

  defp confined_path!(root, relative) do
    unless is_binary(relative) and Path.type(relative) == :relative do
      raise ArgumentError, "asset path must be repository-relative"
    end

    path = Path.expand(relative, root)

    unless String.starts_with?(path, root <> "/") do
      raise ArgumentError, "asset path escapes repository root"
    end

    path
  end

  defp exact_keys!(map, expected, context) when is_map(map) do
    actual = Map.keys(map) |> Enum.sort()
    expected = Enum.sort(expected)

    unless actual == expected,
      do: raise(ArgumentError, "#{context} keys must be exactly #{inspect(expected)}")
  end

  defp exact_keys!(_map, _expected, context), do: raise(ArgumentError, "#{context} must be a map")

  defp require_equal!(actual, expected, field) do
    unless actual == expected,
      do:
        raise(ArgumentError, "#{field} must equal #{inspect(expected)}, got: #{inspect(actual)}")
  end

  defp require_string!(value, _field) when is_binary(value) and value != "", do: value

  defp require_string!(value, field),
    do: raise(ArgumentError, "#{field} must be a non-empty string, got: #{inspect(value)}")

  defp require_number!(value, _field) when is_number(value), do: value

  defp require_number!(value, field),
    do: raise(ArgumentError, "#{field} must be numeric, got: #{inspect(value)}")

  defp require_integer!(value, _field) when is_integer(value), do: value

  defp require_integer!(value, field),
    do: raise(ArgumentError, "#{field} must be an integer, got: #{inspect(value)}")

  defp maybe_require_number!(map, key) do
    if Map.has_key?(map, key), do: require_number!(map[key], "generation.#{key}")
  end

  defp maybe_require_integer!(map, key) do
    if Map.has_key?(map, key), do: require_integer!(map[key], "generation.#{key}")
  end

  defp require_positive_integer!(value, _field) when is_integer(value) and value > 0, do: value

  defp require_positive_integer!(value, field),
    do: raise(ArgumentError, "#{field} must be a positive integer, got: #{inspect(value)}")

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_equal?(_left, _right), do: false

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
