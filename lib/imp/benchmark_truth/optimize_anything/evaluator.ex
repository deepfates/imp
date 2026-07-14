defmodule Imp.BenchmarkTruth.OptimizeAnything.Evaluator do
  @moduledoc false

  @type score :: number()
  @type diagnostics :: %{optional(String.t()) => Jason.Encoder.value()}

  @callback id() :: String.t()
  @callback artifact_class() :: String.t()
  @callback baseline() :: String.t()
  @callback comparator() :: String.t()
  @callback trainset() :: list()
  @callback valset() :: list()
  @callback evaluate(artifact :: String.t(), example :: map()) :: {score(), diagnostics()}
  @callback metadata() :: %{optional(String.t()) => Jason.Encoder.value()}
end
