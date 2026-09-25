defmodule CredentialInspectTest do
  use ExUnit.Case, async: true

  # A struct that can hold a credential prints without it: in IEx, in a log
  # line, in a crash report. Each case below builds one with a canary secret and
  # inspects it, and the program and trace cases check the places an LM struct
  # travels to.

  @secret "sk-canary-0f3b9c2e7d41a6"

  defmodule Stub do
    def generate_text(model, messages, _opts) do
      {:ok,
       %ReqLLM.Response{
         id: "resp",
         model: to_string(model),
         context: ReqLLM.Context.new(messages),
         message: ReqLLM.Context.assistant("[[ ## answer ## ]]\npong\n\n[[ ## completed ## ]]"),
         object: nil
       }}
    end
  end

  defp printed(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  defp lm, do: Imp.req_llm("openai:gpt-4o-mini", api_key: @secret, req_module: Stub)

  test "no credential-bearing struct prints its secret" do
    bearer = [{"authorization", "Bearer " <> @secret}]

    structs = [
      lm(),
      Imp.req_llm("openai:gpt-4o-mini", req_http_options: [headers: bearer]),
      Imp.req_llm("openai:gpt-4o-mini", provider_options: [api_key: @secret]),
      Imp.predict("question -> answer", lm: lm()),
      Imp.Retrievers.HTTP.new("https://retriever.test", headers: bearer),
      struct(Imp.Tracking.MLflow, headers: bearer),
      struct(Imp.Tracking.WandB, authorization: "Basic " <> @secret),
      Imp.Optimize.Anything.Config.Tracking.new(wandb_api_key: @secret),
      struct(Imp.Clients.HTTPTrainer, api_key: @secret, headers: bearer),
      struct(Imp.Clients.TrainingJob, api_key: @secret)
    ]

    leaking = for struct <- structs, printed(struct) =~ @secret, do: struct.__struct__
    assert leaking == []
  end

  test "neither a saved program nor a trace of its call carries the LM's credential" do
    program = Imp.predict("question -> answer", lm: lm())
    path = Path.join(System.tmp_dir!(), "credential-#{System.unique_integer([:positive])}.json")

    try do
      Imp.save!(program, path)
      refute File.read!(path) =~ @secret
    after
      File.rm(path)
    end

    trace = Imp.trace(fn -> Imp.call(program, %{question: "ping"}) end)
    assert {:ok, _prediction} = trace.result
    assert trace.events != []
    refute printed(trace) =~ @secret
  end
end
