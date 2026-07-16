defmodule Imp.RedactionTest do
  use ExUnit.Case, async: true

  alias Imp.Adapters.Types.Image

  @credential_canaries [
    auth: "CANARY_BARE_AUTH_7f913",
    bearer: "CANARY_BARE_BEARER_4c286",
    session: "CANARY_BARE_SESSION_91a42",
    api_key: "CANARY_API_KEY_2dd71",
    authorization: "CANARY_AUTHORIZATION_8ab35",
    proxy_authorization: "CANARY_PROXY_AUTHORIZATION_61ee4",
    token: "CANARY_BARE_TOKEN_b4502",
    api_token: "CANARY_API_TOKEN_07d36",
    auth_token: "CANARY_AUTH_TOKEN_4a813",
    bearer_token: "CANARY_BEARER_TOKEN_9560c",
    access_token: "CANARY_ACCESS_TOKEN_3518e",
    refresh_token: "CANARY_REFRESH_TOKEN_f8159",
    id_token: "CANARY_ID_TOKEN_a7946",
    session_token: "CANARY_SESSION_TOKEN_523cd",
    access_key: "CANARY_ACCESS_KEY_ec371",
    access_key_id: "CANARY_ACCESS_KEY_ID_b3298",
    secret_access_key: "CANARY_SECRET_ACCESS_KEY_68e12",
    secret_key: "CANARY_SECRET_KEY_03f54",
    client_secret: "CANARY_CLIENT_SECRET_d770a",
    private_key: "CANARY_PRIVATE_KEY_2f69b",
    private_token: "CANARY_PRIVATE_TOKEN_c1248",
    service_account_key: "CANARY_SERVICE_ACCOUNT_KEY_879e3",
    password: "CANARY_PASSWORD_20f17",
    secret: "CANARY_SECRET_668bd",
    credential: "CANARY_CREDENTIAL_d102a",
    credentials: "CANARY_CREDENTIALS_790fc",
    aws_access_key_id: "CANARY_AWS_ACCESS_KEY_ID_a1409",
    "x-api-key": "CANARY_X_API_KEY_9c372"
  ]

  defmodule OrdinaryStruct do
    defstruct [:value]
  end

  test "redacts nested ASI image credentials without scanning opaque image data" do
    base64 = String.duplicate("c2VjcmV0", 12)

    image = %Image{
      url: "https://example.test/image?token=sk-url-secret-1234567890",
      data: base64,
      mime_type: "image/png",
      metadata: %{
        authorization: "Bearer abcdefghijklmnop",
        nested: [%{api_key: "short-secret", label: "keep"}]
      }
    }

    redacted =
      Imp.Redaction.redact(%{
        side_information: %{prompt: [%{"Image" => image}]}
      })

    assert %Image{} = redacted.side_information.prompt |> hd() |> Map.fetch!("Image")
    redacted_image = redacted.side_information.prompt |> hd() |> Map.fetch!("Image")

    assert redacted_image.url == "[REDACTED]"
    assert redacted_image.data == base64
    assert redacted_image.mime_type == image.mime_type
    assert redacted_image.metadata.authorization == "[REDACTED]"
    assert redacted_image.metadata.nested == [%{api_key: "[REDACTED]", label: "keep"}]
  end

  test "strong credential syntaxes redact without treating auth prose or ordinary URLs as secrets" do
    basic = "Basic " <> Base.encode64("audit-user:audit-pass")
    bearer = "Bearer abcdefghijklmnop"
    session = "session=CANARY_SESSION_ASSIGNMENT_5d83b"
    ordinary_url = "https://example.test/images/public-diagram.png?version=12"
    prose = "Bearer authentication is an authorization mechanism."

    redacted =
      Imp.Redaction.redact(%{
        prose: prose,
        basic_prose: "Basic authentication is enabled for this endpoint.",
        message: bearer,
        description: "lookup facts #{bearer}",
        code: ~s(token = "#{bearer}"),
        quoted_output: inspect(bearer),
        basic: basic,
        cookie: session,
        ordinary_url: ordinary_url,
        headers: [{"authorization", bearer}],
        image: %Image{url: "https://example.test/image/sk-image-canary-1234567890"},
        ordinary_image: %Image{url: ordinary_url}
      })

    assert redacted.prose == prose
    assert redacted.basic_prose == "Basic authentication is enabled for this endpoint."
    assert redacted.ordinary_url == ordinary_url
    assert redacted.ordinary_image.url == ordinary_url
    assert redacted.message == "[REDACTED]"
    assert redacted.description == "[REDACTED]"
    assert redacted.code == "[REDACTED]"
    assert redacted.quoted_output == "[REDACTED]"
    assert redacted.basic == "[REDACTED]"
    assert redacted.cookie == "[REDACTED]"
    assert redacted.headers == [{"authorization", "[REDACTED]"}]
    assert redacted.image.url == "[REDACTED]"
  end

  test "ordinary structs and maps retain existing redaction behavior" do
    assert Imp.Redaction.redact(%OrdinaryStruct{value: %{api_key: "secret"}}) == %{
             value: %{api_key: "[REDACTED]"}
           }

    assert Imp.Redaction.redact(%{label: "keep", nested: %{token: "short"}}) == %{
             label: "keep",
             nested: %{token: "[REDACTED]"}
           }

    assert Imp.Redaction.redact({:error, {:provider, "Bearer abcdefghijklmnop"}}) ==
             {:error, {:provider, "[REDACTED]"}}
  end

  test "redaction and credential dropping preserve improper provider lists" do
    provider_reason = [:provider_error, %{api_key: "CANARY_IMPROPER_SECRET"} | "messages"]

    assert Imp.Redaction.redact(provider_reason) ==
             [:provider_error, %{api_key: "[REDACTED]"} | "messages"]

    assert Imp.Redaction.drop_credentials(provider_reason) ==
             [:provider_error, %{} | "messages"]
  end

  test "malformed typed credential keys fail closed across map boundaries" do
    typed_key = %{"__imp_type__" => "atom", "value" => "api_key", "extra" => "ignored"}
    atom_typed_key = %{__imp_type__: :atom, value: "authorization", extra: true}

    assert Imp.Redaction.credential_key?(typed_key)
    assert Imp.Redaction.credential_key?(atom_typed_key)

    assert Imp.Redaction.redact(%{typed_key => "CANARY_TYPED_KEY_SECRET"}) == %{
             typed_key => "[REDACTED]"
           }

    assert Imp.Redaction.drop_credentials(%{typed_key => "CANARY_TYPED_KEY_SECRET"}) == %{}

    tagged = %{
      "__imp_type__" => "map",
      "entries" => [[typed_key, "CANARY_TYPED_KEY_SECRET"]]
    }

    assert Imp.Redaction.redact(tagged)["entries"] == [[typed_key, "[REDACTED]"]]
    assert Imp.Redaction.drop_credentials(tagged)["entries"] == []
  end

  test "mixed tagged-map envelopes cannot hide credential entries" do
    encoded_key = %{"value" => "api_key", __imp_type__: "atom"}

    envelopes = [
      %{"__imp_type__" => "map", entries: [[encoded_key, "CANARY_MIXED_TAGGED_SECRET"]]},
      %{"entries" => [[encoded_key, "CANARY_MIXED_TAGGED_SECRET"]], __imp_type__: :map},
      %{__imp_type__: "map", entries: [[encoded_key, "CANARY_MIXED_TAGGED_SECRET"]]}
    ]

    Enum.each(envelopes, fn envelope ->
      refute inspect(Imp.Redaction.redact(envelope)) =~ "CANARY_MIXED_TAGGED_SECRET"
      refute inspect(Imp.Redaction.drop_credentials(envelope)) =~ "CANARY_MIXED_TAGGED_SECRET"
    end)
  end

  test "credential-named semantic schema descriptors remain data, not credentials" do
    schema = %{token: :string, api_key: :string, authorization: :string}

    assert Imp.Redaction.redact(schema) == schema
    assert Imp.Redaction.drop_credentials(schema) == schema

    assert Imp.Redaction.redact(%{token: "CANARY_ACTUAL_TOKEN"}) == %{
             token: "[REDACTED]"
           }

    assert Imp.Redaction.drop_credentials(%{token: "CANARY_ACTUAL_TOKEN"}) == %{}
  end

  test "canonical credential classification covers provider variants without swallowing semantics" do
    Enum.each(@credential_canaries, fn {key, _canary} ->
      assert Imp.Redaction.credential_key?(key), "expected credential key: #{inspect(key)}"
    end)

    assert Imp.Redaction.credential_key?(:openai_api_key)
    assert Imp.Redaction.credential_key?("awsAccessKeyId")
    assert Imp.Redaction.credential_key?("vault-secret-access-key")
    assert Imp.Redaction.credential_key?("refreshToken")
    assert Imp.Redaction.credential_key?("providerSessionToken")
    assert Imp.Redaction.credential_key?(:provider_auth)
    assert Imp.Redaction.credential_key?("providerAuth")
    assert Imp.Redaction.credential_key?(:provider_bearer)
    assert Imp.Redaction.credential_key?("providerSession")

    Enum.each(
      [
        :max_tokens,
        "maxTokens",
        :request_id,
        "requestId",
        :session_count,
        :authentication_mode,
        :authored_by,
        :bearer_capacity,
        :secretary
      ],
      fn key ->
        refute Imp.Redaction.credential_key?(key), "unexpected credential key: #{inspect(key)}"
      end
    )

    assert Imp.Redaction.redact(%{access_key_id: "AKIAINLINEPLAINTEXT"}) == %{
             access_key_id: "[REDACTED]"
           }
  end

  test "redacts credential boundaries recursively without redacting semantic IDs or paths" do
    canary_map = Map.new(@credential_canaries)
    long_id = String.duplicate("a", 40)
    long_hex = String.duplicate("b", 64)
    path = "/private/tmp/models/#{long_hex}/fused"

    payload = %{
      top_level: canary_map,
      provider_options: %{
        nested: [canary_map],
        max_tokens: 128,
        request_id: long_id
      },
      headers: Enum.map(@credential_canaries, fn {key, canary} -> {to_string(key), canary} end),
      inline_model: Map.merge(%{id: long_id, model: path}, canary_map)
    }

    redacted = Imp.Redaction.redact(payload)
    rendered = inspect(redacted)

    Enum.each(@credential_canaries, fn {_key, canary} ->
      refute rendered =~ canary
    end)

    assert redacted.provider_options.max_tokens == 128
    assert redacted.provider_options.request_id == long_id
    assert redacted.inline_model.id == long_id
    assert redacted.inline_model.model == path
    assert Enum.all?(redacted.headers, fn {_key, value} -> value == "[REDACTED]" end)
  end

  test "credential removal drops nested runtime options and preserves semantic pairs" do
    canary_map = Map.new(@credential_canaries)

    sanitized =
      Imp.Redaction.drop_credentials(%{
        opts: @credential_canaries ++ [max_tokens: 64, request_id: "request-42"],
        provider_options: Map.merge(canary_map, %{region: "us-west-2"}),
        headers:
          Enum.map(@credential_canaries, fn {key, canary} -> {to_string(key), canary} end) ++
            [{"x-tenant", "tenant-a"}],
        inline_model: Map.merge(%{id: "model-42", model: "/models/model-42"}, canary_map)
      })

    rendered = inspect(sanitized)

    Enum.each(@credential_canaries, fn {_key, canary} ->
      refute rendered =~ canary
    end)

    assert sanitized.opts == [max_tokens: 64, request_id: "request-42"]
    assert sanitized.provider_options == %{region: "us-west-2"}
    assert sanitized.headers == [{"x-tenant", "tenant-a"}]
    assert sanitized.inline_model == %{id: "model-42", model: "/models/model-42"}
  end

  test "telemetry recursively redacts measurements and metadata credential canaries" do
    event = [:imp, :redaction, :credential_boundary]
    ref = Imp.Test.TelemetryHelpers.attach([event])
    canary_map = Map.new(@credential_canaries)
    basic = "Basic " <> Base.encode64("telemetry-user:telemetry-pass")
    bearer = "Bearer CANARYTELEMETRYBEARER12345"
    session_assignment = "session=CANARY_TELEMETRY_SESSION_824ac"
    image_secret = "sk-telemetry-image-url-1234567890"
    prose = "Bearer authentication is an authorization mechanism."
    ordinary_url = "https://example.test/public/telemetry.png"
    typed_key = %{"__imp_type__" => "atom", "value" => "api_key", "extra" => "bypass"}
    typed_canary = "CANARY_TELEMETRY_TYPED_KEY"

    assert :ok =
             Imp.Telemetry.execute(
               event,
               %{
                 provider_options: canary_map,
                 max_tokens: 32,
                 request_id: "measurement-request",
                 basic_header: basic,
                 message: bearer,
                 typed: %{typed_key => typed_canary}
               },
               %{
                 opts: @credential_canaries,
                 headers:
                   Enum.map(@credential_canaries, fn {key, canary} ->
                     {to_string(key), canary}
                   end),
                 model: Map.merge(%{id: "inline-model"}, canary_map),
                 cookie_line: session_assignment,
                 image: %Image{
                   url: "https://example.test/private/#{image_secret}",
                   data: "aW1hZ2U="
                 },
                 prose: prose,
                 ordinary_url: ordinary_url
               }
             )

    assert_received {^ref, ^event, measurements, metadata}
    rendered = inspect({measurements, metadata})

    Enum.each(@credential_canaries, fn {_key, canary} ->
      refute rendered =~ canary
    end)

    for canary <- [basic, bearer, session_assignment, image_secret],
        do: refute(rendered =~ canary)

    refute rendered =~ typed_canary
    assert measurements.typed[typed_key] == "[REDACTED]"

    assert measurements.max_tokens == 32
    assert measurements.request_id == "measurement-request"
    assert measurements.basic_header == "[REDACTED]"
    assert measurements.message == "[REDACTED]"
    assert metadata.model.id == "inline-model"
    assert metadata.cookie_line == "[REDACTED]"
    assert metadata.image.url == "[REDACTED]"
    assert metadata.image.data == "aW1hZ2U="
    assert metadata.prose == prose
    assert metadata.ordinary_url == ordinary_url
  end
end
