defmodule ImpDoctestTest do
  use ExUnit.Case, async: true

  doctest Imp.Adapter.Types
  doctest Imp.Adapter.JSON
  doctest Imp.Cache
  doctest Imp.Errors
  doctest Imp.Evaluate
  doctest Imp.Example
  doctest Imp.Metrics
  doctest Imp.Module
  doctest Imp.Observability.Inspection
  doctest Imp.Optimizer.RandomSearch
  doctest Imp.Prediction
  doctest Imp.Predict.Aggregation
  doctest Imp.Predict.MultiChainComparison
  doctest Imp.Predict.Parallel
  doctest Imp.Predict.Predict
  doctest Imp.Predict.RAG
  doctest Imp.Redaction
  doctest Imp.Retrieve
  doctest Imp.Settings
  doctest Imp.Signature
  doctest Imp.Tasks
  doctest Imp.Telemetry
  doctest Imp.Tool
end
