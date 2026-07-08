defmodule DSExDoctestTest do
  use ExUnit.Case, async: true

  doctest DSEx.Adapters.Types
  doctest DSEx.Adapter.JSON
  doctest DSEx.Cache
  doctest DSEx.Errors
  doctest DSEx.Evaluate
  doctest DSEx.Example
  doctest DSEx.Metrics
  doctest DSEx.Module
  doctest DSEx.Optimizer.RandomSearch
  doctest DSEx.Prediction
  doctest DSEx.Predict.Aggregation
  doctest DSEx.Predict.MultiChainComparison
  doctest DSEx.Predict.Parallel
  doctest DSEx.Predict.Predict
  doctest DSEx.Predict.RAG
  doctest DSEx.Redaction
  doctest DSEx.Retrieve
  doctest DSEx.Settings
  doctest DSEx.Signature
  doctest DSEx.Tasks
  doctest DSEx.Telemetry
  doctest DSEx.Tool
end
