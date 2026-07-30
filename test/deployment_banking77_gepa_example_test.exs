defmodule DeploymentBanking77GEPAExampleTest do
  use ExUnit.Case, async: true

  @script Path.expand("../examples/deployment/banking77_gepa.exs", __DIR__)
  @result Path.expand(
            "../examples/deployment/banking77-gepa-exercised-result.json",
            __DIR__
          )
  @artifact Path.expand(
              "../examples/deployment/banking77-gepa-selected-artifact.json",
              __DIR__
            )

  test "Banking77 example is an ordinary public workflow, not a private runner stack" do
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

    refute source =~ "defmodule Banking77GEPA.Ledger"
    refute source =~ "defmodule Banking77GEPA.GuardedLM"
    refute File.exists?(Path.rootname(@script) <> ".json")
  end

  test "the example's readable outer cap is 328 task and two optimizer transports" do
    source = File.read!(@script)
    assert source =~ "%{task: 2 * (64 + 8 + 8 + 40 + 40 + 4), optimizer: 2}"
    assert %{task: 328, optimizer: 2} == %{task: 2 * (64 + 8 + 8 + 40 + 40 + 4), optimizer: 2}
  end

  test "retained ordinary run records negative selection and a linked reusable artifact" do
    result = Imp.Experiment.Result.read!(@result)
    artifact = Imp.Optimizer.Artifact.read!(@artifact)

    assert result["payload"]["selected"] == "baseline"
    assert result["payload"]["selection"]["baseline"]["score"] == 0.25
    assert result["payload"]["selection"]["optimized"]["score"] == 0.125
    assert result["payload"]["test"] == %{
             "score" => 0.275,
             "row_count" => 40,
             "error_count" => 0
           }

    assert result["payload"]["artifact"] == artifact
    assert result["payload"]["provenance"]["git"]["commit"] ==
             "9ca0bccfe1f3fab682eba83f68a0c28e05091082"
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
