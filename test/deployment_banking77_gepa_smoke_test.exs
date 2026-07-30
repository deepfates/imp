defmodule DeploymentBanking77GEPASmokeTest do
  use ExUnit.Case, async: true

  @script Path.expand("../examples/deployment/banking77_gepa_smoke.exs", __DIR__)

  test "optional smoke is an ordinary public workflow, not a private runner stack" do
    source = File.read!(@script)
    assert length(String.split(source, "\n")) < 320
    Code.string_to_quoted!(source, file: @script)

    assert source =~ "Imp.Experiment.check"
    assert source =~ "Imp.Observability.trace"
    assert source =~ "Result.write!"
    assert source =~ "Artifact.write!"
    assert source =~ "ProgramServer.reload_parameters"
    assert source =~ "allow_fallbacks: false"
    assert source =~ "data_collection: \"deny\""
    assert source =~ "req_http_options: [retry: false, max_retries: 0]"

    refute source =~ "defmodule Banking77GEPASmoke.Ledger"
    refute source =~ "defmodule Banking77GEPASmoke.GuardedLM"
    refute File.exists?(Path.rootname(@script) <> ".json")
  end

  test "pinned ReqLLM reproduces the terminal seed-zero failure before transport" do
    owner = self()

    adapter = fn request ->
      send(owner, :transport_reached)
      {request, %Req.TransportError{reason: :provider_free_stop}}
    end

    lm =
      Imp.req_llm("openrouter:openai/gpt-5.4-mini",
        api_key: "local-provider-free-key",
        cache: false,
        max_tokens: 256,
        max_retries: 0,
        seed: 0,
        provider_options: [
          openrouter_provider: %{
            only: ["openai"],
            order: ["openai"],
            allow_fallbacks: false,
            require_parameters: true,
            data_collection: "deny",
            max_price: %{prompt: 0.75, completion: 4.5, request: 0}
          }
        ],
        req_http_options: [adapter: adapter, retry: false, max_retries: 0]
      )

    program =
      Imp.predict(
        Imp.signature("utterance -> evidence", "Summarize the banking request for routing."),
        adapter: Imp.Adapter.Chat,
        config: [cache: false, json_fallback: false]
      )

    assert {:error, reason} =
             Imp.context([lm: lm], fn ->
               Imp.call(program, %{utterance: "A transfer was rejected"})
             end)

    assert Exception.message(reason) =~
             "invalid value for :seed option: expected positive integer, got: 0"

    refute_received :transport_reached
  end
end
