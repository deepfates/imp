defmodule Imp.LM.Capability do
  @moduledoc false

  # Per-LM response-format capability, the analog of the two DSPy `BaseLM`
  # properties the JSON adapter gates on:
  #
  #   * `response_format` — does the model accept a `response_format` request
  #     param at all? DSPy checks `"response_format" in lm.supported_params`
  #     (`dspy/clients/lm.py`: `litellm.get_supported_openai_params(...)`).
  #   * `response_schema` — does the model support structured JSON-schema
  #     output (OpenAI Structured Outputs)? DSPy checks
  #     `lm.supports_response_schema` (`litellm.supports_response_schema(...)`).
  #
  # DSPy reads both from litellm's model registry; Imp reads them from the
  # ReqLLM/LLMDB registry (`Imp.Clients.ReqLLM.response_format_capability/1`),
  # except where a native ReqLLM provider owns a stronger documented transport
  # guarantee (currently Ollama JSON-schema generation). The decision logic over
  # the two booleans lives in `Imp.Adapter.JSON`; the source of the booleans is
  # the registry, not a hardcoded model list.
  #
  # The default is both false: send no `response_format`. An LM that cannot be
  # introspected (a bare callback, an unknown module) resolves to it, matching
  # DSPy's treatment of an LM that does not declare `supported_params`.

  @type t :: %__MODULE__{
          response_format: boolean(),
          response_schema: boolean(),
          choice_values: boolean()
        }

  defstruct response_format: false, response_schema: false, choice_values: false

  @doc "DSPy `BaseLM` default: no declared capability (send no response_format)."
  @spec none() :: t()
  def none, do: %__MODULE__{response_format: false, response_schema: false}

  @doc "response_format accepted, but not structured json_schema (-> json_object)."
  @spec response_format_only() :: t()
  def response_format_only, do: %__MODULE__{response_format: true, response_schema: false}

  @doc "structured JSON schema supported (-> pydantic-shaped json_schema)."
  @spec json_schema() :: t()
  def json_schema, do: %__MODULE__{response_format: true, response_schema: true}

  @doc """
  Builds a capability from an explicit tier name.

  Tiers are `:none`, `:response_format` (also `"json_object"`) and
  `:json_schema` (also `"response_schema"`), as atoms or strings; `nil` is
  `:none`. Any other value raises `ArgumentError`. Callers that already know
  the tier, such as the provider-free golden-trace fixtures, use this so both
  sides of a differential declare the same tier.
  """
  @spec from_tier(atom() | String.t() | nil) :: t()
  def from_tier(tier) when tier in [:none, "none", nil], do: none()

  def from_tier(tier) when tier in [:response_format, "response_format", "json_object"],
    do: response_format_only()

  def from_tier(tier) when tier in [:json_schema, "json_schema", "response_schema"],
    do: json_schema()

  def from_tier(other),
    do: raise(ArgumentError, "unknown response-format capability tier: #{inspect(other)}")
end
