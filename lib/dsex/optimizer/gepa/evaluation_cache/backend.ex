defmodule DSEx.Optimizer.GEPA.EvaluationCache.Backend do
  @moduledoc """
  Storage contract for per-example GEPA evaluation caches.

  Backends preserve the semantics of `DSEx.Optimizer.GEPA.EvaluationCache`:
  `lookup/3` returns entries indexed by batch position plus ordered missing
  positions, `put/4` returns the updated backend state, and `assemble/4`
  reconstructs a `DSEx.Optimizer.GEPA.Result`.

  Engine integration can remain serial and state-threaded by replacing direct
  calls to `EvaluationCache` with a configured backend module:

      {hits, misses} = backend.lookup(cache, candidate, examples)
      cache = backend.put(cache, candidate, missing_examples, missing_result)
      result = backend.assemble(examples, hits, misses, missing_result)

  `Memory` is an immutable wrapper around the existing map cache. `Disk` keeps
  only its root path in memory and can therefore be reopened in later runs.
  """

  alias DSEx.Optimizer.GEPA.{Candidate, Result}

  @type state :: struct()
  @type hits :: %{optional(non_neg_integer()) => map()}

  @callback lookup(state(), Candidate.t(), [term()]) ::
              {hits(), [non_neg_integer()]}
  @callback put(state(), Candidate.t(), [term()], Result.t()) :: state()
  @callback assemble([term()], hits(), [non_neg_integer()], Result.t() | nil) :: Result.t()
end
