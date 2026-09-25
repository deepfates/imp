# Tutorial And Example Parity

The executable learning path is the notebooks in `livebooks/`, in order.
They use local repository dependencies, execute without provider credentials,
and turn on live-provider cells only when `OPENAI_API_KEY` and `OPENAI_MODEL`
are both available. This map keeps adjacent tutorial and real-world example
families attached to one current Imp surface instead of creating parallel
walkthroughs. Evidence commands in this source checkout document are maintainer
checks, not Mix tasks shipped in the Hex package.

| Tutorial or example family | Canonical Imp path | Executable evidence | Disposition |
| --- | --- | --- | --- |
| Getting started and typed programs | [01 Real LM Front Door](../../livebooks/01_real_lm_front_door.livemd) | `mix livebook.execute.check` | Supported tutorial |
| Email and entity extraction | [01 Real LM Front Door](../../livebooks/01_real_lm_front_door.livemd) uses a typed JSON email extraction program | `LIVE_PROVIDER=1 mix live.check` | Supported real-provider example |
| Classification | The [README](../../README.md) router uses enum-constrained JSON output | `mix test --only live test/documentation_contract_test.exs` | Supported real-provider example |
| Evaluation, few-shot optimization, instruction search, and artifact optimization | [03 Evaluate And Optimize](../../livebooks/03_evaluate_and_optimize.livemd) | `mix livebook.execute.check` | Supported tutorial |
| RAG and multi-hop RAG | `Imp.rag/3` with `hops:` and `Imp.Retrieve` | `mix test test/public_surface_test.exs test/integration/local_service_e2e_test.exs` | Supported local and integration example |
| Tools, ReAct, agents, and MCP | [04 Tools, Agents, MCP, And RLM](../../livebooks/04_tools_agents_mcp_rlm.livemd) | `mix integration.check` | Supported tutorial; external MCP endpoints stay host-owned |
| Program of Thought and CodeAct | `Imp.program_of_thought/2` and `Imp.code_act/3` | `mix test test/program_of_thought_fidelity_test.exs` | Supported sandboxed-code example |
| Recursive control | [04 Tools, Agents, MCP, And RLM](../../livebooks/04_tools_agents_mcp_rlm.livemd) | `mix benchmark.rlm.contract.check` | Supported bounded-control tutorial; paper-scale effectiveness is not claimed |
| Image and native document inputs | Typed multimodal input adapters | `mix test test/multimodal_adapter_test.exs` | Supported only at the documented typed-input and evidence boundary |
| Audio | Typed multimodal input adapters | `mix test test/multimodal_adapter_test.exs` | Intentional omission of a live-audio reasoning claim; encoding coverage is not a quality claim |
| Streaming and async work | `Imp.trace/2`, `Imp.Run`, and `Imp.Streaming` | `mix test test/runtime_async_stream_cache_test.exs test/req_llm_client_test.exs` | Supported runtime APIs |
| Privacy-conscious delegation | GEPA replication benchmark | `mix benchmark.gepa_replication.check` | Benchmark-only research lane; no application tutorial or production privacy claim |
| Financial analysis | Typed programs, schemas, tools, and evaluation in [Getting started](../../docs/getting-started/index.md) | `mix test test/schema_constraints_test.exs test/metric_contract_test.exs` | Intentional omission of domain-specific financial advice or decisioning |
| Games and code examples | the sandboxed `Imp.code_act/3` path | `mix test test/program_of_thought_fidelity_test.exs` | Supported code-control primitive; no game engine abstraction |
| Deployment | [OTP deployment reference](../../examples/deployment/README.md) and [Running Imp in production](../../docs/production.md) | `mix test test/deployment_reference_test.exs` | Canonical production path |

The deployment reference is deliberately the only production application
example. It loads a checksummed artifact at supervised startup, rebinds runtime
credentials from the environment, and bounds concurrent provider work. The
Livebooks teach the APIs that lead to it; they do not replace it with a second
deployment pattern.
