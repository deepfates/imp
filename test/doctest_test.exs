defmodule DSExDoctestTest do
  use ExUnit.Case, async: true

  doctest DSEx.Adapter.JSON
  doctest DSEx.Evaluate
  doctest DSEx.Example
  doctest DSEx.Metrics
  doctest DSEx.Optimizer.RandomSearch
  doctest DSEx.Prediction
  doctest DSEx.Predict.MultiChainComparison
  doctest DSEx.Predict.Predict
  doctest DSEx.Signature
  doctest DSEx.Tool
end
