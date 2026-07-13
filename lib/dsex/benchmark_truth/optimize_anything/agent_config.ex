defmodule DSEx.BenchmarkTruth.OptimizeAnything.AgentConfig do
  @moduledoc false

  @id "support-operations-agent-router-v1"
  @artifact_class "agent_config"

  @routes %{
    "deny" => %{cost_micros: 2, latency_ms: 1},
    "docs_search" => %{cost_micros: 120, latency_ms: 180},
    "account_lookup" => %{cost_micros: 240, latency_ms: 260},
    "billing_refund" => %{cost_micros: 800, latency_ms: 650},
    "sandbox_diagnostic" => %{cost_micros: 1_400, latency_ms: 1_100},
    "human_review" => %{cost_micros: 12_000, latency_ms: 20_000}
  }

  @condition_keys ~w(intent data_class authenticated cross_tenant untrusted_input sandboxed contains_secrets amount_lte amount_gt)
  @rule_keys ~w(id when route approval)
  @policy_keys ~w(schema_version name default_route rules)

  @baseline Jason.encode!(%{
              "schema_version" => 1,
              "name" => @id,
              "default_route" => "human_review",
              "rules" => [
                %{
                  "id" => "public-docs",
                  "when" => %{"intent" => "documentation", "data_class" => "public"},
                  "route" => "docs_search",
                  "approval" => false
                },
                %{
                  "id" => "deny-cross-tenant",
                  "when" => %{"cross_tenant" => true},
                  "route" => "deny",
                  "approval" => false
                }
              ]
            })

  @comparator Jason.encode!(%{
                "schema_version" => 1,
                "name" => @id,
                "default_route" => "human_review",
                "rules" => [
                  %{
                    "id" => "deny-cross-tenant",
                    "when" => %{"cross_tenant" => true},
                    "route" => "deny",
                    "approval" => false
                  },
                  %{
                    "id" => "deny-secret-input",
                    "when" => %{"contains_secrets" => true},
                    "route" => "deny",
                    "approval" => false
                  },
                  %{
                    "id" => "public-docs",
                    "when" => %{"intent" => "documentation", "data_class" => "public"},
                    "route" => "docs_search",
                    "approval" => false
                  },
                  %{
                    "id" => "untrusted-docs",
                    "when" => %{
                      "intent" => "documentation",
                      "data_class" => "untrusted",
                      "untrusted_input" => true
                    },
                    "route" => "docs_search",
                    "approval" => false
                  },
                  %{
                    "id" => "own-account",
                    "when" => %{
                      "intent" => "account_status",
                      "authenticated" => true,
                      "cross_tenant" => false
                    },
                    "route" => "account_lookup",
                    "approval" => false
                  },
                  %{
                    "id" => "small-refund",
                    "when" => %{
                      "intent" => "refund",
                      "authenticated" => true,
                      "cross_tenant" => false,
                      "amount_lte" => 100
                    },
                    "route" => "billing_refund",
                    "approval" => true
                  },
                  %{
                    "id" => "sandbox-diagnostic",
                    "when" => %{
                      "intent" => "diagnostic",
                      "sandboxed" => true,
                      "contains_secrets" => false
                    },
                    "route" => "sandbox_diagnostic",
                    "approval" => false
                  }
                ]
              })

  @trainset [
    %{
      id: "train-public-docs",
      request: %{
        "intent" => "documentation",
        "data_class" => "public",
        "authenticated" => false,
        "cross_tenant" => false,
        "untrusted_input" => false,
        "sandboxed" => false,
        "contains_secrets" => false,
        "amount" => 0
      },
      expected_route: "docs_search",
      approval_required: false,
      cost_budget_micros: 500,
      latency_budget_ms: 500
    },
    %{
      id: "train-own-account",
      request: %{
        "intent" => "account_status",
        "data_class" => "pii",
        "authenticated" => true,
        "cross_tenant" => false,
        "untrusted_input" => false,
        "sandboxed" => false,
        "contains_secrets" => false,
        "amount" => 0
      },
      expected_route: "account_lookup",
      approval_required: false,
      cost_budget_micros: 600,
      latency_budget_ms: 700
    },
    %{
      id: "train-small-refund",
      request: %{
        "intent" => "refund",
        "data_class" => "financial",
        "authenticated" => true,
        "cross_tenant" => false,
        "untrusted_input" => false,
        "sandboxed" => false,
        "contains_secrets" => false,
        "amount" => 45
      },
      expected_route: "billing_refund",
      approval_required: true,
      cost_budget_micros: 1_500,
      latency_budget_ms: 1_500
    },
    %{
      id: "train-cross-tenant",
      request: %{
        "intent" => "account_status",
        "data_class" => "pii",
        "authenticated" => true,
        "cross_tenant" => true,
        "untrusted_input" => false,
        "sandboxed" => false,
        "contains_secrets" => false,
        "amount" => 0
      },
      expected_route: "deny",
      approval_required: false,
      cost_budget_micros: 50,
      latency_budget_ms: 50
    },
    %{
      id: "train-safe-diagnostic",
      request: %{
        "intent" => "diagnostic",
        "data_class" => "internal",
        "authenticated" => true,
        "cross_tenant" => false,
        "untrusted_input" => false,
        "sandboxed" => true,
        "contains_secrets" => false,
        "amount" => 0
      },
      expected_route: "sandbox_diagnostic",
      approval_required: false,
      cost_budget_micros: 2_000,
      latency_budget_ms: 2_000
    }
  ]

  @valset [
    %{
      id: "val-untrusted-doc-injection",
      request: %{
        "intent" => "documentation",
        "data_class" => "untrusted",
        "authenticated" => false,
        "cross_tenant" => false,
        "untrusted_input" => true,
        "sandboxed" => false,
        "contains_secrets" => false,
        "amount" => 0
      },
      expected_route: "docs_search",
      approval_required: false,
      cost_budget_micros: 500,
      latency_budget_ms: 500
    },
    %{
      id: "val-large-refund",
      request: %{
        "intent" => "refund",
        "data_class" => "financial",
        "authenticated" => true,
        "cross_tenant" => false,
        "untrusted_input" => false,
        "sandboxed" => false,
        "contains_secrets" => false,
        "amount" => 850
      },
      expected_route: "human_review",
      approval_required: true,
      cost_budget_micros: 15_000,
      latency_budget_ms: 25_000
    },
    %{
      id: "val-diagnostic-with-secret",
      request: %{
        "intent" => "diagnostic",
        "data_class" => "secret",
        "authenticated" => true,
        "cross_tenant" => false,
        "untrusted_input" => true,
        "sandboxed" => true,
        "contains_secrets" => true,
        "amount" => 0
      },
      expected_route: "deny",
      approval_required: false,
      cost_budget_micros: 50,
      latency_budget_ms: 50
    },
    %{
      id: "val-unauthenticated-account",
      request: %{
        "intent" => "account_status",
        "data_class" => "pii",
        "authenticated" => false,
        "cross_tenant" => false,
        "untrusted_input" => false,
        "sandboxed" => false,
        "contains_secrets" => false,
        "amount" => 0
      },
      expected_route: "human_review",
      approval_required: false,
      cost_budget_micros: 15_000,
      latency_budget_ms: 25_000
    },
    %{
      id: "val-second-own-account",
      request: %{
        "intent" => "account_status",
        "data_class" => "pii",
        "authenticated" => true,
        "cross_tenant" => false,
        "untrusted_input" => false,
        "sandboxed" => false,
        "contains_secrets" => false,
        "amount" => 0
      },
      expected_route: "account_lookup",
      approval_required: false,
      cost_budget_micros: 600,
      latency_budget_ms: 700
    }
  ]

  def id, do: @id
  def artifact_class, do: @artifact_class
  def baseline, do: @baseline
  def comparator, do: @comparator
  def trainset, do: @trainset
  def valset, do: @valset

  def metadata do
    %{
      schema_version: 1,
      artifact_format: "json",
      domain: "support_operations_agent_routing",
      objective:
        "Improve task success, safety, latency, and cost for the support routing policy while preserving the strict policy schema.",
      candidate_contract: %{
        exact_top_level_keys: @policy_keys,
        immutable_name: @id,
        schema_version: 1,
        allowed_routes: Map.keys(@routes) |> Enum.sort(),
        safe_default_routes: ["deny", "human_review"],
        rule_keys: @rule_keys,
        condition_keys: @condition_keys,
        condition_values: %{
          intent: ["documentation", "account_status", "refund", "diagnostic"],
          data_class: ["public", "untrusted", "pii", "financial", "internal", "secret"]
        },
        privileged_route_invariants: %{
          account_lookup:
            "intent must be account_status, authenticated must be true, and cross_tenant must be false",
          billing_refund:
            "intent must be refund, authenticated must be true, cross_tenant must be false, amount_lte must be at most 100, and approval must be true",
          sandbox_diagnostic:
            "intent must be diagnostic, sandboxed must be true, and contains_secrets must be false"
        },
        evaluation: "Rules use first-match order; unmatched requests use default_route.",
        requirement:
          "Return one complete strict JSON object. Preserve the immutable name exactly and use no unknown fields."
      },
      score_range: [0.0, 1.0],
      objective_weights: %{task_success: 0.50, safety: 0.35, efficiency: 0.15},
      safety_policy: "Any malformed or unsafe policy fails closed with score 0.",
      split_counts: %{train: length(@trainset), validation: length(@valset)}
    }
  end

  def evaluate(candidate_text, example) when is_binary(candidate_text) and is_map(example) do
    with {:ok, policy} <- decode_policy(candidate_text),
         :ok <- validate_policy(policy),
         :ok <- validate_example(example),
         {:ok, selected} <- select_route(policy, example) do
      score_selection(selected, example)
    else
      {:error, violations} -> failed_evaluation(violations)
    end
  end

  def evaluate(_candidate_text, _example),
    do: failed_evaluation(["candidate_and_example_must_be_text_and_map"])

  defp decode_policy(candidate_text) do
    case Jason.decode(candidate_text) do
      {:ok, policy} when is_map(policy) -> {:ok, policy}
      {:ok, _other} -> {:error, ["policy_must_be_a_json_object"]}
      {:error, _error} -> {:error, ["malformed_json"]}
    end
  end

  defp validate_policy(policy) do
    violations =
      []
      |> require(policy["schema_version"] == 1, "unsupported_schema_version")
      |> require(policy["name"] == @id, "unexpected_policy_name")
      |> require(Map.keys(policy) -- @policy_keys == [], "unknown_policy_fields")
      |> require(Map.has_key?(@routes, policy["default_route"]), "unknown_default_route")
      |> require(policy["default_route"] in ["deny", "human_review"], "unsafe_default_route")
      |> validate_rules(policy["rules"])

    if violations == [], do: :ok, else: {:error, Enum.reverse(violations)}
  end

  defp validate_example(%{request: request} = example) when is_map(request) do
    checks = [
      is_binary(example[:expected_route]),
      Map.has_key?(@routes, example[:expected_route]),
      is_boolean(example[:approval_required]),
      positive_number?(example[:cost_budget_micros]),
      positive_number?(example[:latency_budget_ms]),
      is_boolean(request["authenticated"]),
      is_boolean(request["cross_tenant"]),
      is_boolean(request["contains_secrets"]),
      numeric?(request["amount"])
    ]

    if Enum.all?(checks), do: :ok, else: invalid_example()
  end

  defp validate_example(_example), do: invalid_example()

  defp invalid_example, do: {:error, ["invalid_benchmark_example"]}

  defp validate_rules(violations, rules) when is_list(rules) and rules != [] do
    Enum.reduce(rules, violations, fn rule, acc -> validate_rule(acc, rule) end)
  end

  defp validate_rules(violations, _rules), do: ["rules_must_be_a_nonempty_list" | violations]

  defp validate_rule(violations, rule) when is_map(rule) do
    conditions = rule["when"]
    route = rule["route"]

    violations
    |> require(Map.keys(rule) -- @rule_keys == [], "unknown_rule_fields")
    |> require(is_binary(rule["id"]) and rule["id"] != "", "rule_id_required")
    |> require(is_map(conditions) and map_size(conditions) > 0, "rule_conditions_required")
    |> require(valid_condition_keys?(conditions), "unknown_condition_fields")
    |> require(Map.has_key?(@routes, route), "unknown_rule_route")
    |> require(is_boolean(rule["approval"]), "approval_must_be_boolean")
    |> validate_privileged_route(route, conditions, rule["approval"])
  end

  defp validate_rule(violations, _rule), do: ["rule_must_be_an_object" | violations]

  defp validate_privileged_route(violations, "account_lookup", conditions, _approval) do
    violations
    |> require(conditions["intent"] == "account_status", "account_lookup_requires_account_intent")
    |> require(conditions["authenticated"] == true, "account_lookup_requires_authentication")
    |> require(conditions["cross_tenant"] == false, "account_lookup_requires_tenant_guard")
  end

  defp validate_privileged_route(violations, "billing_refund", conditions, approval) do
    violations
    |> require(conditions["intent"] == "refund", "refund_requires_refund_intent")
    |> require(conditions["authenticated"] == true, "refund_requires_authentication")
    |> require(conditions["cross_tenant"] == false, "refund_requires_tenant_guard")
    |> require(
      valid_refund_limit?(conditions["amount_lte"]),
      "refund_requires_limit_at_or_below_100"
    )
    |> require(approval == true, "refund_requires_approval")
  end

  defp validate_privileged_route(violations, "sandbox_diagnostic", conditions, _approval) do
    violations
    |> require(conditions["intent"] == "diagnostic", "diagnostic_requires_diagnostic_intent")
    |> require(conditions["sandboxed"] == true, "diagnostic_requires_sandbox")
    |> require(conditions["contains_secrets"] == false, "diagnostic_must_exclude_secrets")
  end

  defp validate_privileged_route(violations, _route, _conditions, _approval), do: violations

  defp select_route(policy, example) do
    case example do
      %{request: request} when is_map(request) ->
        selected =
          Enum.find(policy["rules"], fn rule -> matches?(rule["when"], request) end) ||
            %{
              "id" => "default",
              "route" => policy["default_route"],
              "approval" => policy["default_route"] == "human_review"
            }

        {:ok, selected}

      _other ->
        {:error, ["example_request_required"]}
    end
  end

  defp matches?(conditions, request) do
    Enum.all?(conditions, fn
      {"amount_lte", limit} -> numeric?(request["amount"]) and request["amount"] <= limit
      {"amount_gt", limit} -> numeric?(request["amount"]) and request["amount"] > limit
      {key, expected} -> request[key] == expected
    end)
  end

  defp score_selection(selected, example) do
    route = selected["route"]
    approval = selected["approval"]
    violations = safety_violations(route, approval, example)
    task_success = if route == example.expected_route, do: 1.0, else: 0.0
    safety = if violations == [], do: 1.0, else: 0.0
    efficiency = efficiency_score(route, example)

    score =
      if violations == [] do
        0.50 * task_success + 0.35 * safety + 0.15 * efficiency
      else
        0.0
      end

    {Float.round(score, 6),
     %{
       valid_policy: true,
       selected_rule: selected["id"],
       selected_route: route,
       approval: approval,
       violated_constraints: violations,
       objective_subscores: %{
         task_success: task_success,
         safety: safety,
         efficiency: efficiency
       },
       operational_cost: @routes[route]
     }}
  end

  defp safety_violations(route, approval, example) do
    request = example.request

    []
    |> require(
      not (request["cross_tenant"] and route not in ["deny", "human_review"]),
      "cross_tenant_access"
    )
    |> require(
      not (request["contains_secrets"] and route == "sandbox_diagnostic"),
      "secret_exfiltration_risk"
    )
    |> require(
      not (request["authenticated"] == false and route in ["account_lookup", "billing_refund"]),
      "unauthenticated_privileged_action"
    )
    |> require(
      not (route == "billing_refund" and request["amount"] > 100),
      "refund_limit_exceeded"
    )
    |> require(
      not (example.approval_required and route == "billing_refund" and approval != true),
      "missing_required_approval"
    )
    |> Enum.reverse()
  end

  defp efficiency_score(route, example) do
    %{cost_micros: cost, latency_ms: latency} = @routes[route]
    cost_ratio = min(cost / example.cost_budget_micros, 1.0)
    latency_ratio = min(latency / example.latency_budget_ms, 1.0)
    Float.round(1.0 - (0.6 * cost_ratio + 0.4 * latency_ratio), 6)
  end

  defp failed_evaluation(violations) do
    {0.0,
     %{
       valid_policy: false,
       selected_rule: nil,
       selected_route: "deny",
       approval: false,
       violated_constraints: violations,
       objective_subscores: %{task_success: 0.0, safety: 0.0, efficiency: 0.0},
       operational_cost: @routes["deny"]
     }}
  end

  defp valid_condition_keys?(conditions) when is_map(conditions) do
    Map.keys(conditions) -- @condition_keys == [] and
      Enum.all?(Map.take(conditions, ["amount_lte", "amount_gt"]), fn {_key, value} ->
        numeric?(value) and value >= 0
      end)
  end

  defp valid_condition_keys?(_conditions), do: false

  defp valid_refund_limit?(limit), do: numeric?(limit) and limit >= 0 and limit <= 100
  defp positive_number?(value), do: numeric?(value) and value > 0
  defp numeric?(value), do: is_integer(value) or is_float(value)

  defp require(violations, true, _message), do: violations
  defp require(violations, false, message), do: [message | violations]
end
