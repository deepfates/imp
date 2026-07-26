defmodule Imp.Optimizer.SignatureOptimizerTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.{InstructionSearch, Report, SignatureOptimizer}

  defp example(answer \\ "Paris") do
    Imp.example(question: "What is the capital of France?", answer: answer)
    |> Imp.with_inputs(:question)
  end

  defp instruction_sensitive_lm do
    Imp.LM.Static.new(
      handler: fn messages, _opts ->
        text = Enum.map_join(messages, "\n", &to_string(&1.content))
        %{answer: if(text =~ "Always answer Paris", do: "Paris", else: "London")}
      end
    )
  end

  test "configured proposal LM executes through the public optimizer and owns the report" do
    owner = self()

    proposer =
      Imp.LM.Static.new(
        handler: fn messages, opts ->
          send(owner, {:proposal, messages, opts})
          ~s(["Always answer Paris."])
        end
      )

    program = Imp.predict("question -> answer", lm: instruction_sensitive_lm())

    compiled =
      SignatureOptimizer.new(Imp.Metrics.exact_match(:answer),
        proposer_lm: proposer,
        num_candidates: 1,
        seed: 41,
        temperature: 0.25
      )
      |> SignatureOptimizer.compile(program, [example()], [example()])

    assert InstructionSearch.current_instruction(compiled) == "Always answer Paris."
    assert_receive {:proposal, [%{role: :system}, %{role: :user, content: payload}], opts}
    assert Jason.decode!(payload)["train_examples"] != []
    assert opts[:rollout_id] == 41
    assert opts[:temperature] == 0.25

    report = Report.fetch(compiled)
    assert report.optimizer == :signature_optimizer
    assert report.best_score == 1.0
    assert report.metadata.proposal_mode == :language_model
    assert report.metadata.proposal_status == :ok
    assert report.metadata.proposal_calls == 1
    assert report.metadata.selected_instruction == "Always answer Paris."
    assert report.metadata.search.optimizer == :instruction_search
  end

  test "manual and LM proposal ownership cannot be ambiguous" do
    proposer = Imp.LM.Static.new()

    assert_raise ArgumentError, ~r/either explicit :candidates or :proposer_lm/, fn ->
      SignatureOptimizer.new(Imp.Metrics.exact_match(:answer),
        candidates: ["manual"],
        proposer_lm: proposer
      )
    end

    assert_raise ArgumentError, ~r/temperature.*non-negative/s, fn ->
      SignatureOptimizer.new(Imp.Metrics.exact_match(:answer), temperature: -0.1)
    end
  end

  test "required proposal response format is honored and recorded" do
    owner = self()

    proposer =
      Imp.LM.Static.new(
        handler: fn _messages, opts ->
          send(owner, {:typed_proposal_opts, opts})
          %{"instructions" => ["Always answer Paris."]}
        end
      )

    compiled =
      SignatureOptimizer.new(Imp.Metrics.exact_match(:answer),
        proposer_lm: proposer,
        num_candidates: 1,
        proposal_response_format: :required
      )
      |> SignatureOptimizer.compile(
        Imp.predict("question -> answer", lm: instruction_sensitive_lm()),
        [example()],
        [example()]
      )

    assert_receive {:typed_proposal_opts, opts}
    assert opts[:response_format].json_schema.strict
    assert opts[:response_format].json_schema.schema["additionalProperties"] == false
    assert InstructionSearch.current_instruction(compiled) == "Always answer Paris."
    assert Report.fetch(compiled).metadata.proposal_response_format == :required
  end

  test "proposal failure is explicit while native fallbacks and baseline remain usable" do
    proposer =
      Imp.LM.Static.new(handler: fn _messages, _opts -> raise "proposal backend unavailable" end)

    program = Imp.predict("question -> answer", lm: Imp.LM.Static)

    compiled =
      SignatureOptimizer.new(Imp.Metrics.exact_match(:answer),
        proposer_lm: proposer,
        num_candidates: 1
      )
      |> SignatureOptimizer.compile(program, [example("ok")], [example("ok")])

    report = Report.fetch(compiled)
    assert report.optimizer == :signature_optimizer
    assert report.metadata.proposal_status == :with_fallbacks
    assert report.metadata.proposal_calls == 1
    assert report.metadata.proposal_errors != []
    assert Enum.any?(report.errors, &(&1.stage == :proposal))

    assert InstructionSearch.current_instruction(compiled) ==
             InstructionSearch.current_instruction(program)
  end

  test "equal-score instruction candidates cannot displace the original program" do
    program = Imp.predict("question -> answer", lm: Imp.LM.Static)
    baseline = InstructionSearch.current_instruction(program)

    compiled =
      SignatureOptimizer.new(Imp.Metrics.exact_match(:answer),
        candidates: ["Different but equally scoring instruction."]
      )
      |> SignatureOptimizer.compile(program, [example("ok")], [example("ok")])

    assert InstructionSearch.current_instruction(compiled) == baseline
    assert Report.fetch(compiled).metadata.baseline_score == 1.0
  end

  @tag :tmp_dir
  test "saved selected program and optimizer-owned report load in a fresh OS BEAM", %{
    tmp_dir: dir
  } do
    program = Imp.predict("question -> answer", lm: Imp.LM.Static)

    compiled =
      SignatureOptimizer.new(Imp.Metrics.exact_match(:answer),
        candidates: ["Different but equally scoring instruction."]
      )
      |> SignatureOptimizer.compile(program, [example("ok")], [example("ok")])

    portable = Imp.with_lm(compiled, Imp.req_llm("openai:gpt-5.4-mini"))
    path = Path.join(dir, "signature-optimized.imp")
    :ok = Imp.save!(portable, path)

    code = """
    program = Imp.load!(#{inspect(path)})
    report = Imp.Optimizer.Report.fetch(program)
    IO.puts(Jason.encode!(%{
      optimizer: report.optimizer,
      instruction: Imp.Optimizer.InstructionSearch.current_instruction(program)
    }))
    """

    {output, 0} =
      System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", code],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    decoded = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    assert decoded["optimizer"] == "signature_optimizer"
    assert decoded["instruction"] == InstructionSearch.current_instruction(program)
  end
end
