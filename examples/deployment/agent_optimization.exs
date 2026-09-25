defmodule ImpDeployment.AgentOptimization do
  @moduledoc "A ReActV2 program whose sandboxed action descriptions are optimizable components."
  @behaviour Imp.Module

  alias Imp.Optimizer.{Component, Parameter}

  @enforce_keys [:react]
  defstruct [:react]

  @impl true
  def call(%__MODULE__{react: react}, inputs), do: Imp.call(react, inputs)

  @impl true
  def optimizer_components(%__MODULE__{react: react}) do
    for name <- [:account_lookup, :billing_remediation, :security_response] do
      tool = Map.fetch!(react.tools, name)

      Parameter.new("tool/#{name}/description", :tool_description, tool.description)
      |> Component.new(
        description: "Provider-visible purpose of the #{name} support action",
        constraints: %{"type" => "string", "minLength" => 12, "maxLength" => 500}
      )
    end
  end

  @impl true
  def update_optimizer_components(%__MODULE__{} = agent, replacements) do
    react =
      Enum.reduce(replacements, agent.react, fn {id, description}, current ->
        ["tool", name, "description"] = String.split(id, "/")
        Imp.ProgramParameters.put_tool_description(current, name, description)
      end)

    %{agent | react: react}
  end

  def new(lm, descriptions \\ seed_descriptions()) do
    tools = [
      tool(:account_lookup, descriptions.account_lookup, "ACCOUNT_STATUS_OK"),
      tool(:billing_remediation, descriptions.billing_remediation, "REFUND_QUEUED"),
      tool(:security_response, descriptions.security_response, "SECURITY_CASE_OPENED")
    ]

    react =
      Imp.react_v2("request -> answer", tools,
        lm: lm,
        max_iters: 3,
        config: [max_tokens: 700]
      )

    %__MODULE__{react: react}
  end

  def seed_descriptions do
    %{
      account_lookup: "Read information related to a customer account.",
      billing_remediation: "Make a change when a customer needs help.",
      security_response: "Handle a situation that may require attention."
    }
  end

  defp tool(name, description, token) do
    Imp.tool(name, description, fn %{"account_id" => account_id} -> "#{token}:#{account_id}" end,
      schema: %{
        "type" => "object",
        "required" => ["account_id"],
        "properties" => %{"account_id" => %{"type" => "string"}}
      }
    )
  end
end

defmodule ImpDeployment.AgentOptimization.Runner do
  alias Imp.Optimize.Anything
  alias Imp.Optimize.Anything.Config
  alias ImpDeployment.AgentOptimization, as: Agent

  @task_model "openrouter:openai/gpt-5.4-mini"
  @optimizer_model "openrouter:anthropic/claude-sonnet-4.6"
  @default_output "/tmp/imp-agent-optimization-live.json"

  def main do
    api_key = System.fetch_env!("OPENROUTER_API_KEY")
    {task_lm, task_budget} = task_lm(api_key)
    {optimizer_lm, optimizer_budget} = optimizer_lm(api_key)
    program = Agent.new(task_lm)

    result =
      Anything.run(Imp.ProgramParameters.values(program), evaluator(program),
        dataset: train(),
        valset: selection(),
        objective:
          "Make each support action description precise enough that the agent chooses exactly the correct sandboxed action, avoids forbidden actions, and returns the action result token.",
        background:
          "The program is a ReActV2 support agent. Each candidate is the complete map of three tool descriptions. Do not change tool names or invent capabilities. Account lookup is read-only, billing remediation queues a refund only for explicit billing disputes, and security response opens a security case only for suspicious access or compromise.",
        config:
          Config.new(
            engine: [
              max_candidate_proposals: 3,
              seed: 17,
              parallel: false,
              max_workers: 1,
              cache_evaluation: false,
              acceptance_criterion: :strict_improvement,
              raise_on_exception: false
            ],
            reflection: [
              reflection_lm: optimizer_lm,
              module_selector: :round_robin,
              structured_response_format: :required
            ]
          ),
        timeout: 90_000
      )

    artifact =
      Anything.to_program_artifact(result, program,
        provenance: %{
          "story" => "sandboxed-react-v2-support-actions",
          "task_model" => @task_model,
          "optimizer_model" => @optimizer_model
        }
      )

    selected = Imp.Optimizer.Artifact.apply(artifact, program)
    baseline_test = evaluate_rows(program, test())
    selected_test = evaluate_rows(selected, test())
    fresh = fresh_process!(artifact)

    record = %{
      "schema_version" => 1,
      "story" => "sandboxed-react-v2-support-actions",
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "models" => %{"task" => @task_model, "optimizer" => @optimizer_model},
      "data" => %{"train" => ids(train()), "selection" => ids(selection()), "test" => ids(test())},
      "optimizer" => %{
        "candidates" => result.candidates,
        "validation_scores" => result.validation_scores,
        "best_candidate" => Anything.best_candidate(result),
        "stop_reason" => inspect(result.stop_reason),
        "metric_calls" => result.total_metric_calls,
        "reflection_calls" => result.reflection_calls,
        "rejected" => result.rejected,
        "history" => result.history
      },
      "held_out" => %{"baseline" => baseline_test, "selected" => selected_test},
      "fresh_process" => fresh,
      "budgets" => %{
        "task" => Imp.Optimizer.Budget.snapshot(task_budget),
        "optimizer" => Imp.Optimizer.Budget.snapshot(optimizer_budget)
      },
      "scope" => %{
        "claimed" =>
          "one bounded live ReActV2 component-optimization lifecycle with sandboxed tools, disjoint rows, action-aware scoring, Artifact reload, and fresh execution",
        "not_claimed" => [
          "general agent effectiveness",
          "external side-effect safety",
          "multi-seed optimizer effectiveness",
          "DSPy or Ax parity"
        ]
      }
    }

    path = System.get_env("IMP_AGENT_OPT_OUTPUT", @default_output)
    artifact_path = System.get_env("IMP_AGENT_OPT_ARTIFACT_OUTPUT", path <> ".artifact.json")
    :ok = Imp.Optimizer.Artifact.write!(artifact, artifact_path)

    record =
      Map.put(record, "artifact", %{
        "path" => Path.basename(artifact_path),
        "sha256" => "sha256:" <> file_sha256(artifact_path)
      })

    File.write!(path, Jason.encode!(record, pretty: true) <> "\n")
    IO.puts(Jason.encode!(summary(record), pretty: true))

    unless selected_test["mean_score"] > baseline_test["mean_score"] and
             selected_test["mean_score"] >= 0.8 and fresh["score"] >= 0.8 do
      raise "live agent treatment did not clear its bounded usefulness criteria"
    end
  end

  def fresh do
    api_key = System.fetch_env!("OPENROUTER_API_KEY")
    artifact_path = System.fetch_env!("IMP_AGENT_OPT_ARTIFACT")
    receipt_path = System.fetch_env!("IMP_AGENT_OPT_RECEIPT")
    {lm, _budget} = task_lm(api_key, requests: 6, usd: 0.20)

    program =
      artifact_path
      |> Imp.Optimizer.Artifact.read!()
      |> Imp.Optimizer.Artifact.apply(Agent.new(lm))

    File.write!(receipt_path, Jason.encode!(evaluate_row(program, hd(test()))))
  end

  def probe do
    api_key = System.fetch_env!("OPENROUTER_API_KEY")
    {lm, budget} = task_lm(api_key, requests: 6, usd: 0.20)

    IO.puts(
      Jason.encode!(
        %{
          "receipt" => evaluate_row(Agent.new(lm), hd(train())),
          "budget" => Imp.Optimizer.Budget.snapshot(budget)
        },
        pretty: true
      )
    )
  end

  defp evaluator(program) do
    fn values, row ->
      program
      |> Imp.ProgramParameters.apply_values!(values)
      |> evaluate_row(row)
      |> then(fn result ->
        %Imp.Metrics.Result{
          score: result["score"],
          passed?: result["score"] == 1.0,
          feedback: result["feedback"],
          metadata: %{
            actions: result["actions"],
            completed: result["completed"],
            errors: result["errors"]
          }
        }
      end)
    end
  end

  defp evaluate_rows(program, rows) do
    results = Enum.map(rows, &evaluate_row(program, &1))

    %{
      "mean_score" => Enum.sum(Enum.map(results, & &1["score"])) / length(results),
      "rows" => results
    }
  end

  defp evaluate_row(program, row) do
    parent = self()
    tag = make_ref()

    {:ok, run} =
      Imp.start_run(program, %{request: row.request},
        event_sink: fn event -> send(parent, {tag, event}) end
      )

    result = Task.await(run.task, 90_000)
    :ok = Imp.Run.barrier(run, parent, tag)
    events = receive_events(tag, [])
    :ok = Imp.Run.stop(run)

    actions =
      events
      |> Enum.filter(&(&1.kind == :tool_call))
      |> Enum.map(&to_string(&1.tool_name))

    errors = Enum.filter(events, &(&1.kind == :run_failed or not is_nil(&1.error)))

    {completed, answer, termination_reason, termination_error} =
      case result do
        {:ok, prediction} ->
          {
            true,
            Imp.get(prediction, :answer, "") |> to_string(),
            prediction.metadata[:termination_reason],
            prediction.metadata[:termination_error]
          }

        {:error, reason} ->
          {false, inspect(reason), nil, reason}
      end

    expected? = row.expected_action in actions
    forbidden = Enum.filter(actions, &(&1 in row.forbidden_actions))

    expected_result? =
      Enum.any?(events, fn event ->
        event.kind == :tool_result and to_string(event.tool_name) == row.expected_action and
          is_binary(event.output) and String.contains?(event.output, row.expected_token)
      end)

    grounded? = expected_result? and String.contains?(answer, row.account_id)
    clean? = errors == []
    valid_final? = completed and answer != "" and termination_reason == :answered

    score =
      if expected? do
        0.55 +
          if(forbidden == [], do: 0.2, else: 0.0) +
          if(expected_result?, do: 0.15, else: 0.0) +
          if(valid_final? and clean? and grounded?, do: 0.1, else: 0.0)
      else
        0.0
      end

    feedback =
      [
        if(expected?, do: nil, else: "missing expected action #{row.expected_action}"),
        if(forbidden == [],
          do: nil,
          else: "used forbidden actions #{Enum.join(forbidden, ", ")}"
        ),
        if(expected_result?, do: nil, else: "expected action did not return its sandbox result"),
        if(valid_final? and clean? and grounded?,
          do: nil,
          else: "run did not answer cleanly, grounded in account #{row.account_id}"
        )
      ]
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> "correct action, no forbidden action, and grounded final answer"
        failures -> Enum.join(failures, "; ")
      end

    %{
      "id" => row.id,
      "score" => Float.round(score, 6),
      "feedback" => feedback,
      "actions" => actions,
      "returned_prediction" => completed,
      "completed" => valid_final?,
      "errors" => length(errors),
      "answer" => Imp.Redaction.redact(answer),
      "termination_reason" => termination_reason && to_string(termination_reason),
      "termination_error" =>
        if(is_nil(termination_error),
          do: nil,
          else: termination_error |> Imp.Redaction.redact() |> inspect()
        ),
      "events" =>
        Enum.map(events, fn event ->
          %{
            "sequence" => event.sequence,
            "kind" => to_string(event.kind),
            "tool_name" => event.tool_name && to_string(event.tool_name),
            "tool_call_id" => event.tool_call_id,
            "output" =>
              if(event.kind == :tool_result, do: Imp.Redaction.redact(event.output), else: nil),
            "error" => if(is_nil(event.error), do: nil, else: inspect(event.error))
          }
        end)
    }
  end

  defp receive_events(tag, events) do
    receive do
      {^tag, event} -> receive_events(tag, events ++ [event])
      {:imp_run_barrier, ^tag} -> events
    after
      5_000 -> raise "timed out waiting for ordered Imp.Run event barrier"
    end
  end

  defp fresh_process!(artifact) do
    root = Path.join(System.tmp_dir!(), "imp-agent-fresh-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    artifact_path = Path.join(root, "artifact.json")
    receipt_path = Path.join(root, "receipt.json")
    :ok = Imp.Optimizer.Artifact.write!(artifact, artifact_path)

    {output, status} =
      System.cmd("mix", ["run", "--no-compile", "--no-deps-check", __ENV__.file],
        cd: File.cwd!(),
        env: [
          {"IMP_AGENT_OPT_MODE", "fresh"},
          {"IMP_AGENT_OPT_ARTIFACT", artifact_path},
          {"IMP_AGENT_OPT_RECEIPT", receipt_path}
        ],
        stderr_to_stdout: true
      )

    if status != 0, do: raise("fresh agent process failed: #{output}")
    receipt = receipt_path |> File.read!() |> Jason.decode!()
    File.rm_rf!(root)
    receipt
  end

  defp task_lm(api_key, overrides \\ []) do
    {:ok, budget} =
      Imp.start_optimizer_budget(
        limits: %{
          requests: Keyword.get(overrides, :requests, 120),
          input_tokens: 1_000_000,
          output_tokens: 60_000,
          usd: Keyword.get(overrides, :usd, 1.00)
        },
        pricing: %{
          "input_per_million" => 0.75,
          "output_per_million" => 4.50,
          "source_url" => "https://openai.com/api/pricing/"
        },
        default_max_output_tokens: 700
      )

    lm =
      @task_model
      |> Imp.req_llm(
        api_key: api_key,
        cache: false,
        max_tokens: 700,
        max_retries: 0,
        timeout: 90_000,
        provider_options: provider_options("openai", 0.75, 4.50),
        req_http_options: [retry: false, max_retries: 0]
      )
      |> Imp.budgeted_lm(budget, max_output_tokens: 700)

    {lm, budget}
  end

  defp optimizer_lm(api_key) do
    {:ok, budget} =
      Imp.start_optimizer_budget(
        limits: %{requests: 6, input_tokens: 100_000, output_tokens: 10_000, usd: 1.00},
        pricing: %{
          "input_per_million" => 3.0,
          "output_per_million" => 15.0,
          "source_url" => "https://www.anthropic.com/pricing"
        },
        default_max_output_tokens: 1_200
      )

    lm =
      @optimizer_model
      |> Imp.req_llm(
        api_key: api_key,
        cache: false,
        temperature: 1,
        max_tokens: 1_200,
        max_retries: 0,
        timeout: 90_000,
        provider_options: provider_options("anthropic", 3.0, 15.0),
        req_http_options: [retry: false, max_retries: 0]
      )
      |> Imp.budgeted_lm(budget, max_output_tokens: 1_200)

    {lm, budget}
  end

  defp provider_options(provider, prompt_price, completion_price) do
    [
      openrouter_provider: %{
        only: [provider],
        order: [provider],
        allow_fallbacks: false,
        require_parameters: true,
        data_collection: "deny",
        max_price: %{prompt: prompt_price, completion: completion_price, request: 0}
      },
      openrouter_usage: %{include: true}
    ]
  end

  defp train do
    [
      row(
        "train-refund",
        "Refund the duplicate charge on account A-104.",
        :billing_remediation,
        "REFUND_QUEUED",
        [:account_lookup, :security_response]
      ),
      row(
        "train-security",
        "An unknown administrator accessed account B-209 overnight.",
        :security_response,
        "SECURITY_CASE_OPENED",
        [:account_lookup, :billing_remediation]
      ),
      row(
        "train-lookup",
        "What is the current status of account C-317? Do not change it.",
        :account_lookup,
        "ACCOUNT_STATUS_OK",
        [:billing_remediation, :security_response]
      )
    ]
  end

  defp selection do
    [
      row(
        "select-refund",
        "Queue a refund for the double billing on account D-411.",
        :billing_remediation,
        "REFUND_QUEUED",
        [:account_lookup, :security_response]
      ),
      row(
        "select-security",
        "Account E-522 shows a suspicious login from a former employee.",
        :security_response,
        "SECURITY_CASE_OPENED",
        [:account_lookup, :billing_remediation]
      ),
      row(
        "select-lookup",
        "Read the service status for account F-638 without making changes.",
        :account_lookup,
        "ACCOUNT_STATUS_OK",
        [:billing_remediation, :security_response]
      )
    ]
  end

  defp test do
    [
      row(
        "test-refund",
        "The same invoice was charged twice on account G-744; please refund it.",
        :billing_remediation,
        "REFUND_QUEUED",
        [:account_lookup, :security_response]
      ),
      row(
        "test-security",
        "A stolen credential was used to enter account H-851.",
        :security_response,
        "SECURITY_CASE_OPENED",
        [:account_lookup, :billing_remediation]
      ),
      row(
        "test-lookup",
        "Tell me whether account J-963 is active. This is read-only.",
        :account_lookup,
        "ACCOUNT_STATUS_OK",
        [:billing_remediation, :security_response]
      ),
      row(
        "test-security-2",
        "Open a security case for suspected compromise of account K-107.",
        :security_response,
        "SECURITY_CASE_OPENED",
        [:account_lookup, :billing_remediation]
      )
    ]
  end

  defp row(id, request, expected_action, expected_token, forbidden_actions) do
    [_, account_id] = Regex.run(~r/account ([A-Z]-\d+)/i, request)

    %{
      id: id,
      request: request,
      account_id: account_id,
      expected_action: Atom.to_string(expected_action),
      expected_token: expected_token,
      forbidden_actions: Enum.map(forbidden_actions, &Atom.to_string/1)
    }
  end

  defp ids(rows), do: Enum.map(rows, & &1.id)

  defp file_sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp summary(record) do
    %{
      "baseline_test" => get_in(record, ["held_out", "baseline", "mean_score"]),
      "selected_test" => get_in(record, ["held_out", "selected", "mean_score"]),
      "fresh_score" => get_in(record, ["fresh_process", "score"]),
      "reflection_calls" => get_in(record, ["optimizer", "reflection_calls"]),
      "task_budget" => get_in(record, ["budgets", "task"]),
      "optimizer_budget" => get_in(record, ["budgets", "optimizer"])
    }
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _other -> "unknown"
    end
  end
end

unless System.get_env("IMP_AGENT_OPT_NO_RUN") == "1" do
  case System.get_env("IMP_AGENT_OPT_MODE", "main") do
    "main" -> ImpDeployment.AgentOptimization.Runner.main()
    "fresh" -> ImpDeployment.AgentOptimization.Runner.fresh()
    "probe" -> ImpDeployment.AgentOptimization.Runner.probe()
    mode -> raise "unknown IMP_AGENT_OPT_MODE #{inspect(mode)}"
  end
end
