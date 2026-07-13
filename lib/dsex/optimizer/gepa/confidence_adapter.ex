defmodule DSEx.Optimizer.GEPA.ConfidenceAdapter do
  @moduledoc """
  GEPA integration for confidence-aware structured classification.

  This adapter is intentionally limited to one optimizable component and one
  enum-constrained JSON classification field, matching the upstream confidence
  adapter's reflection model. It requests OpenAI Chat token logprobs through
  ReqLLM, but accepts capability only when the returned response proves support.

  Missing or unsupported logprobs fail evaluation by default. Set
  `fallback: :accuracy` explicitly to omit `:raw_confidence`, retain only the
  `:accuracy` objective, and record why confidence was unavailable.
  """

  @behaviour DSEx.Optimizer.GEPA.Adapter

  alias DSEx.Optimizer.GEPA.{Candidate, ProgramAdapter}

  @enforce_keys [:program_adapter]
  defstruct [:program_adapter]

  @doc "Builds a one-component confidence-aware program adapter."
  def new(program, opts) when is_list(opts) do
    predictors = DSEx.ProgramParameters.predictors(program)

    unless length(predictors) == 1 do
      raise ArgumentError,
            "GEPA confidence adapter requires exactly one optimizable component, got: #{length(predictors)}"
    end

    Keyword.fetch!(opts, :field)
    Keyword.fetch!(opts, :enum)
    top_logprobs = Keyword.get(opts, :top_logprobs, 5)

    unless is_integer(top_logprobs) and top_logprobs in 1..20 do
      raise ArgumentError, "top_logprobs must be an integer from 1 through 20"
    end

    program = request_logprobs(program, hd(predictors).name, top_logprobs)
    metric_opts = Keyword.take(opts, confidence_option_keys())

    metric = fn example, prediction, _trace ->
      DSEx.Confidence.evaluate(example, prediction, metric_opts)
    end

    adapter_opts =
      Keyword.take(opts, [:max_concurrency, :timeout])

    %__MODULE__{program_adapter: ProgramAdapter.new(program, metric, adapter_opts)}
  end

  @impl true
  def evaluate(%__MODULE__{program_adapter: adapter}, batch, candidate, opts) do
    Candidate.validate!(candidate)

    unless map_size(candidate) == 1 do
      raise ArgumentError,
            "GEPA confidence adapter requires exactly one candidate component, got: #{map_size(candidate)}"
    end

    ProgramAdapter.evaluate(adapter, batch, candidate, opts)
  end

  @impl true
  def make_reflective_dataset(
        %__MODULE__{program_adapter: adapter},
        candidate,
        result,
        components_to_update
      ) do
    unless length(components_to_update) == 1 do
      raise ArgumentError,
            "GEPA confidence adapter reflection requires exactly one component to update"
    end

    ProgramAdapter.make_reflective_dataset(adapter, candidate, result, components_to_update)
  end

  defp request_logprobs(program, component, top_logprobs) do
    DSEx.ProgramParameters.update_predictor(program, component, fn predictor ->
      provider_options =
        predictor.config
        |> Keyword.get(:provider_options, [])
        |> Keyword.merge(openai_logprobs: true, openai_top_logprobs: top_logprobs)

      config = Keyword.put(predictor.config, :provider_options, provider_options)
      %{predictor | config: config}
    end)
  end

  defp confidence_option_keys do
    [
      :field,
      :expected_field,
      :enum,
      :scoring,
      :high_confidence_threshold,
      :low_confidence_threshold,
      :fallback,
      :additional_context
    ]
  end
end
