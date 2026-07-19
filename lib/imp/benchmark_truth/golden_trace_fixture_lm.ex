defmodule Imp.BenchmarkTruth.GoldenTraceFixtureLM do
  @moduledoc false

  # Provider-free golden-trace LM used by `mix imp.benchmark.trace`.
  #
  # It replays queued fixture responses and records each call's messages +
  # request envelope, and — crucially for dee-ps19 — declares an
  # `Imp.LM.Capability` so the JSON adapter gates `response_format` on the SAME
  # tier the Python DSPy `FixtureLM` declares (`supported_params` /
  # `supports_response_schema`). This is the Imp-side analog of a
  # capability-varied DSPy LM, letting one fixture prove each of DSPy's three
  # response_format tiers (none / json_object / json_schema).
  #
  # It is a struct LM: `Imp.LM` dispatches `%GoldenTraceFixtureLM{}` to
  # `generate/3` and resolves capability via the `response_format_capability/1`
  # hook.

  defstruct [:queue, :calls, capability: %Imp.LM.Capability{}]

  @doc "Capability tier this fixture LM declares (Imp.LM introspection hook)."
  def response_format_capability(%__MODULE__{capability: capability}), do: capability

  @doc false
  def generate(%__MODULE__{queue: queue, calls: calls}, messages, opts) do
    Agent.update(calls, &(&1 ++ [%{messages: messages, opts: opts}]))

    Agent.get_and_update(queue, fn
      [response | rest] -> {{:ok, response}, rest}
      [] -> {{:error, :fixture_response_queue_exhausted}, []}
    end)
  end
end
