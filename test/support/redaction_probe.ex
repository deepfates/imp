defmodule Imp.Test.RedactionProbe do
  @moduledoc false

  # A value that holds credentials only a struct's place hides: a retriever's
  # header values and URL query secrets, a ReqLLM client's custom header, an
  # MCP OAuth store's derived key, and a tuple, a list and a retriever used as
  # map keys. None of the secrets looks like a credential, so a writer that
  # converts the value before redacting it writes them out.

  import ExUnit.Assertions

  @subscription "PROBE-SUBSCRIPTION-VALUE-7F3A"
  @custom "PROBE-CUSTOM-HEADER-VALUE-7F3A"
  @url_key "PROBE-URL-KEY-VALUE-7F3A"
  @url_token "PROBE-URL-TOKEN-VALUE-7F3A"
  @llm_header "PROBE-LLM-HEADER-VALUE-7F3A"
  @key_header "PROBE-KEY-HEADER-VALUE-7F3A"
  @tuple_key "PROBE-TUPLE-KEY-VALUE-7F3A"
  @oauth_secret "PROBE-OAUTH-SECRET-VALUE-7F3A-0123456789"

  # A credential shape, for the keys that are only hidden by what they hold.
  @shaped "sk-proj-" <> String.duplicate("PrObE7f3A", 5)

  defmodule ProbeError do
    @moduledoc false
    defexception [:probe]

    @impl true
    def message(_error), do: "probe failure"
  end

  def store(root) do
    Imp.MCP.OAuth.store(directory: Path.join(root, "oauth"), secret: @oauth_secret)
  end

  # The retrievers are built without their default body, response and sleep
  # functions: a function is not JSON, so the writers that encode JSON would
  # refuse the probe before redaction mattered.
  def value(store) do
    %{
      retriever:
        struct(Imp.Retrievers.HTTP,
          url: "https://retriever.test/search?key=" <> @url_key,
          headers: [{"X-Subscription-Token", @subscription}, {"X-Probe-Custom", @custom}]
        ),
      token_retriever:
        struct(Imp.Retrievers.HTTP, url: "https://retriever.test/search?token=" <> @url_token),
      lm:
        Imp.req_llm("openai:gpt-4o-mini",
          req_http_options: [headers: [{"X-Probe-Custom", @llm_header}]]
        ),
      store: store,
      keyed: %{
        {:api_key, @tuple_key} => 1,
        {:note, @shaped} => 2,
        [@shaped] => 3,
        struct(Imp.Retrievers.HTTP,
          url: "https://retriever.test/keyed",
          headers: [{"X-Subscription-Token", @key_header}]
        ) => 4
      }
    }
  end

  def secrets(store) do
    [
      @subscription,
      @custom,
      @url_key,
      @url_token,
      @llm_header,
      @key_header,
      @tuple_key,
      @shaped,
      store.key
    ]
  end

  # Everything a writer produced, as bytes: a binary in a term appears in its
  # external form as the bytes it holds.
  def bytes(output) when is_binary(output), do: output
  def bytes(output), do: :erlang.term_to_binary(output)

  def leaked(output, store) do
    written = bytes(output)
    for secret <- secrets(store), :binary.match(written, secret) != :nomatch, do: secret
  end

  # No secret is written, and the non-secret fields remain: the URL's host and
  # path, the header names, the model and the store's directory.
  def assert_redacted(output, store) do
    leaked = leaked(output, store)
    assert leaked == [], "secret values written: #{inspect(leaked)}"
    written = bytes(output)

    for kept <- [
          "retriever.test/search",
          "X-Subscription-Token",
          "X-Probe-Custom",
          "gpt-4o-mini",
          store.directory
        ] do
      assert :binary.match(written, kept) != :nomatch, "#{kept} is missing from the output"
    end
  end
end
