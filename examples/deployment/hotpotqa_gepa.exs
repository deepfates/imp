Application.ensure_all_started(:imp)

defmodule HotPotQAGEPA do
  alias Imp.Experiment.{Data, Result}
  alias Imp.Optimizer.{Artifact, GEPA}
  alias ImpDeployment.{HotPotQAPipeline, ProgramServer}

  @data_dir Path.expand("data/hotpotqa-gepa", __DIR__)
  @receipt_sha "3ca2955ec517fa070b4f43e54c1f340b2c7cd3a54b52afc5c3d23daf75e04032"
  @seeds [2_026_080_101, 2_026_080_102, 2_026_080_103]
  @task_model "openrouter:openai/gpt-5.4-mini"
  @optimizer_model "openrouter:anthropic/claude-sonnet-4.6"
  @task_envelope %{input: 8_192, output: 512}
  @optimizer_envelope %{input: 32_768, output: 1_024}
  @task_input_max_bytes 8_192
  @optimizer_input_max_bytes 131_072

  def run(args) do
    args = Enum.reject(args, &(&1 == "--"))

    case args do
      ["--provider-disabled"] -> provider_disabled!()
      ["--live", seed] -> live!(parse_seed!(seed))
      ["--fresh"] -> fresh!()
      _ -> raise "usage: mix run hotpotqa_gepa.exs -- --provider-disabled | --live SEED"
    end
  end

  def transport_caps do
    # Each program evaluation calls four predictors. Outer selection/test uses
    # three fixed repetitions; the optimizer-internal objective is single-pass.
    %{
      task_expected: 4 * (24 + 32 + 24 + 72 + 72 + 4),
      task_legal: 4 * (24 + 44 + 24 + 72 + 72 + 4),
      optimizer_legal: 12
    }
  end

  def reservation_usd do
    caps = transport_caps()
    task = (@task_envelope.input * 0.75 + @task_envelope.output * 4.5) / 1_000_000

    optimizer =
      (@optimizer_envelope.input * 3.0 + @optimizer_envelope.output * 15.0) / 1_000_000

    3 * (caps.task_legal * task + caps.optimizer_legal * optimizer)
  end

  defp provider_disabled! do
    root = Path.join(System.tmp_dir!(), "imp-hotpotqa-gepa-provider-disabled")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    data = data!()
    answers = answer_map(data)

    {:ok, observer} =
      Agent.start_link(fn ->
        %{
          task: %{calls: 0, longest_prompt: ""},
          optimizer: %{calls: 0, longest_prompt: ""}
        }
      end)

    task_lm = provider_disabled_lm(:task, hd(@seeds), observer, answers)
    reflection_lm = provider_disabled_lm(:optimizer, hd(@seeds), observer, answers)

    result = check!(hd(@seeds), data, task_lm, reflection_lm)
    paths = persist!(result, root)
    selected = Artifact.apply(Artifact.read!(paths.artifact), HotPotQAPipeline.new())

    baseline_instructions = instructions(HotPotQAPipeline.new())
    selected_instructions = instructions(selected)

    unless Enum.all?(Map.keys(baseline_instructions), fn name ->
             baseline_instructions[name] != selected_instructions[name]
           end) do
      raise "provider-disabled GEPA did not mutate every named predictor"
    end

    fresh_process!(hd(@seeds), paths, true)
    observations = Agent.get(observer, & &1)
    prompts = Map.new(observations, fn {role, value} -> {role, value.longest_prompt} end)
    optimizer_metric_calls = div(observations.task.calls, 4) - (24 + 24 + 72 + 72)

    if path = System.get_env("IMP_HOTPOTQA_PROMPT_CAPTURE") do
      File.write!(path, Jason.encode!(prompts))
    end

    IO.puts(
      Jason.encode!(%{
        mode: "provider_disabled",
        selected: result.selected,
        named_predictors: Map.keys(selected_instructions),
        prompt_bytes: Map.new(prompts, fn {role, prompt} -> {role, byte_size(prompt)} end),
        observed_calls: %{
          task: observations.task.calls,
          optimizer: observations.optimizer.calls,
          optimizer_metric_examples: optimizer_metric_calls
        },
        transport_caps: transport_caps(),
        reservation_usd: reservation_usd(),
        fresh_service: "passed"
      })
    )
  after
    if Process.whereis(ImpDeployment.ProgramServer),
      do: GenServer.stop(ImpDeployment.ProgramServer)
  end

  defp live!(seed) do
    data = data!()
    catalog!()
    task_lm = provider_lm(:task, seed)
    reflection_lm = provider_lm(:optimizer, seed)
    result = check!(seed, data, task_lm, reflection_lm)
    root = output_root!(seed)
    paths = persist!(result, root)
    fresh_process!(seed, paths, false)

    IO.inspect(
      %{
        seed: seed,
        selected: result.selected,
        selection: [result.baseline_selection.score, result.optimized_selection.score],
        held_out: [result.baseline_test.score, result.test.score],
        result: paths.result,
        artifact: paths.artifact,
        transport_caps: transport_caps()
      },
      label: "HotPotQA GEPA"
    )
  end

  defp check!(seed, data, task_lm, reflection_lm) do
    optimizer =
      GEPA.new(&metric/2,
        execution_profile: :beam_native,
        reflection_lm: reflection_lm,
        module_selector: :all,
        generations: 6,
        minibatch_size: 4,
        max_metric_calls: 32,
        max_reflection_calls: 12,
        seed: seed,
        use_merge: false,
        max_concurrency: 1,
        timeout: 120_000
      )

    true =
      GEPA.v014_budget_envelope(8, 4, 32) == %{
        max_metric_calls: 44,
        max_reflection_calls: 12,
        max_iterations: 6
      }

    result =
      Imp.context([lm: task_lm], fn ->
        Imp.Experiment.check(
          HotPotQAPipeline.new(),
          optimizer,
          data,
          &metric/2,
          artifact_id: "hotpotqa-gepa-#{seed}",
          metric_identity: %{"kind" => "hotpotqa_f1", "version" => 1},
          compare_baseline_on_test: true,
          config: %{
            "condition" => "imp-88sn-hotpotqa-gepa-v1",
            "seed" => seed,
            "task_model" => @task_model,
            "optimizer_model" => @optimizer_model,
            "task_envelope" => @task_envelope,
            "optimizer_envelope" => @optimizer_envelope,
            "task_input_max_bytes" => @task_input_max_bytes,
            "optimizer_input_max_bytes" => @optimizer_input_max_bytes,
            "module_selector" => "beam_native_all",
            "transport_caps" => transport_caps()
          },
          evaluation_options: [
            repetitions: 3,
            aggregation: :mean,
            max_concurrency: 1,
            max_errors: 10,
            failure_score: 0.0,
            timeout: 120_000
          ]
        )
      end)

    case result do
      {:ok, completed} -> completed
      {:error, failure} -> raise "Experiment.check stopped: #{inspect(failure)}"
    end
  end

  defp metric(example, prediction) do
    predicted = Imp.get(prediction, :answer, "")
    gold = Imp.get(example, :answer)
    f1 = Imp.Metrics.hotpot_f1(predicted, gold)
    exact = Imp.Metrics.em(predicted, gold)

    %Imp.Metrics.Result{
      score: f1,
      passed?: exact,
      feedback: "HotPotQA F1=#{Float.round(f1, 4)} exact_match=#{exact}",
      metadata: %{"f1" => f1, "exact_match" => exact}
    }
  end

  defp data! do
    receipt_path = Path.join(@data_dir, "receipt.json")
    true = sha256(receipt_path) == @receipt_sha
    receipt = receipt_path |> File.read!() |> Jason.decode!()

    examples = fn split ->
      path = Path.join(@data_dir, "#{split}.jsonl")
      true = sha256(path) == receipt["splits"][split]["sha256"]
      Imp.Datasets.jsonl(path, [:question, :context])
    end

    Data.new(
      train: examples.("train"),
      selection: examples.("selection"),
      test: examples.("test"),
      id: :source_id
    )
  end

  defp persist!(result, root) do
    result_path = Path.join(root, "experiment-result.json")
    artifact_path = Path.join(root, "selected-artifact.json")
    :ok = Result.write!(result, result_path, include_rows: true)
    :ok = Artifact.write!(result.artifact, artifact_path)
    true = Result.read!(result_path)["payload"]["artifact"] == Artifact.read!(artifact_path)
    %{result: result_path, artifact: artifact_path}
  end

  defp fresh_process!(seed, paths, provider_disabled?) do
    env = [
      {"IMP_HOTPOTQA_GEPA_SEED", Integer.to_string(seed)},
      {"IMP_HOTPOTQA_GEPA_RESULT", paths.result},
      {"IMP_HOTPOTQA_GEPA_ARTIFACT", paths.artifact},
      {"IMP_HOTPOTQA_GEPA_PROVIDER_DISABLED", if(provider_disabled?, do: "1", else: "0")},
      {"OPENROUTER_API_KEY", System.get_env("OPENROUTER_API_KEY", "provider-disabled")}
    ]

    {output, status} =
      System.cmd("mix", ["run", "--no-start", __ENV__.file, "--", "--fresh"],
        cd: __DIR__,
        env: env,
        stderr_to_stdout: true
      )

    if status != 0, do: raise("fresh OS service failed: #{output}")
  end

  defp fresh! do
    seed = System.fetch_env!("IMP_HOTPOTQA_GEPA_SEED") |> String.to_integer()
    stored = Result.read!(System.fetch_env!("IMP_HOTPOTQA_GEPA_RESULT"))
    artifact_path = System.fetch_env!("IMP_HOTPOTQA_GEPA_ARTIFACT")
    artifact = Artifact.read!(artifact_path)
    true = stored["payload"]["artifact"] == artifact
    provider_disabled? = System.fetch_env!("IMP_HOTPOTQA_GEPA_PROVIDER_DISABLED") == "1"

    task_lm =
      if provider_disabled?,
        do: provider_disabled_lm(:task, seed, nil, %{}),
        else: provider_lm(:task, seed)

    {:ok, tasks} = Task.Supervisor.start_link()

    try do
      {:ok, server} =
        ProgramServer.start_link(
          name: nil,
          program: HotPotQAPipeline.new(),
          lm: task_lm,
          task_supervisor: tasks
        )

      :ok = ProgramServer.reload_parameters(server, artifact_path)

      results =
        fresh_probes()
        |> Task.async_stream(&ProgramServer.call(server, &1, 120_000),
          ordered: true,
          max_concurrency: 4,
          timeout: 120_000
        )
        |> Enum.map(fn {:ok, value} -> value end)

      true = Enum.all?(results, &match?({:ok, _}, &1))
      IO.puts("fresh OS service passed with four concurrent four-stage calls")
    after
      Supervisor.stop(tasks)
    end
  end

  defp fresh_probes do
    context = %{
      "title" => ["Ada Lovelace", "Analytical Engine"],
      "sentences" => [
        ["Ada Lovelace wrote notes about the Analytical Engine."],
        ["The Analytical Engine was designed by Charles Babbage."]
      ]
    }

    for question <- [
          "Who wrote notes about the Analytical Engine?",
          "Who designed the Analytical Engine?",
          "What machine did Ada Lovelace write about?",
          "Whose engine was discussed in Ada Lovelace's notes?"
        ],
        do: %{question: question, context: context}
  end

  defp provider_lm(role, seed) do
    {model, opts} = provider_lm_options(role, seed)

    Imp.req_llm(model, Keyword.put(opts, :api_key, System.fetch_env!("OPENROUTER_API_KEY")))
  end

  defp provider_disabled_lm(role, seed, observer, answers) do
    {model, opts} = provider_lm_options(role, seed)
    adapter = local_req_adapter(role, observer, answers)

    Imp.req_llm(
      model,
      opts
      |> Keyword.put(:api_key, "provider-disabled")
      |> Keyword.put(:req_http_options,
        adapter: adapter,
        retry: false,
        max_retries: 0
      )
    )
  end

  defp provider_lm_options(role, seed) do
    {model, provider, envelope, max_bytes, max_price, extra} =
      case role do
        :task ->
          {@task_model, "openai", @task_envelope, @task_input_max_bytes,
           %{prompt: 0.75, completion: 4.5, request: 0}, [seed: seed]}

        :optimizer ->
          {@optimizer_model, "anthropic", @optimizer_envelope, @optimizer_input_max_bytes,
           %{prompt: 3, completion: 15, request: 0}, [temperature: 1]}
      end

    {model,
     [
       cache: false,
       input_envelope: [max_bytes: max_bytes, reservation_tokens: envelope.input],
       max_tokens: envelope.output,
       max_retries: 0,
       timeout: 120_000,
       provider_options: [
         openrouter_provider: %{
           only: [provider],
           order: [provider],
           allow_fallbacks: false,
           require_parameters: true,
           data_collection: "deny",
           max_price: max_price
         },
         openrouter_usage: %{include: true}
       ],
       req_http_options: [retry: false, max_retries: 0]
     ] ++ extra}
  end

  defp local_req_adapter(role, observer, answers) do
    fn request ->
      body = request.body |> IO.iodata_to_binary() |> Jason.decode!()
      rendered = render(body["messages"])
      if observer, do: observe_rendered(observer, role, rendered)

      content =
        case role do
          :optimizer ->
            chat_output(
              "instruction",
              "Use the supplied evidence and named entities. Return the requested field precisely."
            )

          :task ->
            output = output_field(rendered)

            answer =
              Enum.find_value(answers, "unknown", fn {question, gold} ->
                if String.contains?(rendered, question), do: gold
              end)

            improved? = String.contains?(rendered, "Use the supplied evidence and named entities")

            value =
              case output do
                "summary_1" -> "first-hop evidence"
                "query_2" -> "second-hop entity"
                "summary_2" -> "combined evidence"
                "answer" -> if(improved?, do: answer, else: "unknown")
              end

            chat_output(output, value)
        end

      response = %{
        "id" => "provider-disabled-#{role}",
        "object" => "chat.completion",
        "model" => body["model"],
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => content},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
      }

      {request, Req.Response.new(status: 200, body: response)}
    end
  end

  defp output_field(rendered) do
    case Regex.run(~r/Your output fields are:\s*\n1\. `([^`]+)`/, rendered) do
      [_, field] when field in ~w(summary_1 query_2 summary_2 answer) -> field
      _ -> raise "provider-disabled task request omitted a known output field"
    end
  end

  defp chat_output(field, value),
    do: "[[ ## #{field} ## ]]\n#{value}\n\n[[ ## completed ## ]]"

  defp catalog! do
    for {model, provider, prompt, completion} <- [
          {"openai/gpt-5.4-mini", "OpenAI", 0.00000075, 0.0000045},
          {"anthropic/claude-sonnet-4.6", "Anthropic", 0.000003, 0.000015}
        ] do
      body = Req.get!("https://openrouter.ai/api/v1/models/#{model}/endpoints", retry: false).body

      unless Enum.any?(body["data"]["endpoints"], fn endpoint ->
               endpoint["provider_name"] == provider and
                 String.to_float(endpoint["pricing"]["prompt"]) == prompt and
                 String.to_float(endpoint["pricing"]["completion"]) == completion
             end),
             do: raise("exact route or price unavailable for #{model}")
    end
  end

  defp answer_map(%Data{} = data) do
    (data.train ++ data.selection ++ data.test)
    |> Map.new(fn example -> {Imp.get(example, :question), Imp.get(example, :answer)} end)
  end

  defp instructions(program) do
    program
    |> Imp.ProgramParameters.predictors()
    |> Map.new(&{&1.name, &1.predictor.signature.instructions})
  end

  defp observe_rendered(agent, role, prompt) do
    Agent.update(agent, fn state ->
      current = state[role]

      value = %{
        calls: current.calls + 1,
        longest_prompt:
          if(byte_size(prompt) > byte_size(current.longest_prompt),
            do: prompt,
            else: current.longest_prompt
          )
      }

      Map.put(state, role, value)
    end)
  end

  defp render(messages) do
    Enum.map_join(messages, "\n", fn
      %{content: content} -> render_content(content)
      %{"content" => content} -> render_content(content)
    end)
  end

  defp render_content(content) when is_binary(content), do: content

  defp render_content(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"text" => text} -> text
      %{text: text} -> text
      value -> inspect(value)
    end)
  end

  defp render_content(content), do: inspect(content)

  defp output_root!(seed) do
    root = System.fetch_env!("IMP_HOTPOTQA_GEPA_OUTPUT")
    path = Path.join(root, Integer.to_string(seed))
    File.mkdir_p!(path)
    path
  end

  defp parse_seed!(value) do
    seed = String.to_integer(value)
    if seed in @seeds, do: seed, else: raise("seed must be one of #{inspect(@seeds)}")
  end

  defp sha256(path),
    do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
end

HotPotQAGEPA.run(System.argv())
