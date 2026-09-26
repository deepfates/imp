defmodule Imp.Predict.Options do
  @moduledoc false
  # `Imp.Predict.Predict.new/2`'s options, and the check every constructor
  # that builds a Predict shares. Predict and ChainOfThought read `schema/0`
  # while they compile, so this module must not depend on another Imp module
  # at compile time: in the compile cycle Predict belongs to, a module that
  # read the schema from Predict itself failed to compile under a parallel
  # compile with many schedulers.

  @schema [
    lm: [
      type: {:custom, Imp.LM, :validate_lm, []},
      doc: "The model the program calls. When absent, each call uses `Imp.Settings`' `:lm`."
    ],
    adapter: [
      type: {:custom, Imp.Adapter, :validate_adapter, []},
      doc:
        "The adapter that renders the request and parses the reply. When absent, " <>
          "each call uses `Imp.Settings`' `:adapter`."
    ],
    demos: [
      type: {:list, :any},
      default: [],
      doc: "Worked examples rendered before the inputs, as `Imp.Example` values or maps."
    ],
    config: [
      type: :keyword_list,
      default: [],
      doc:
        "Request options sent with every call: sampling (`:temperature`, " <>
          "`:max_tokens`, `:n`, ...) and the other options the LM client takes."
    ],
    adapter_opts: [
      type: :keyword_list,
      default: [],
      doc:
        "Options handed to the adapter's `format/3` on every call, beside `:demos`: " <>
          "how a program passes rendering data, and how a host injects renderers " <>
          "without writing a second adapter module."
    ],
    metadata: [
      type: {:map, :any, :any},
      default: %{},
      doc: "Free-form metadata kept on the program."
    ]
  ]

  # Request options callers reach for at the top level. They are refused like
  # any unknown key, with a message that names `config:` as their place.
  @request_keys [
    :temperature,
    :top_p,
    :top_k,
    :max_tokens,
    :max_completion_tokens,
    :n,
    :num_generations,
    :seed,
    :stop,
    :presence_penalty,
    :frequency_penalty,
    :reasoning_effort,
    :response_format,
    :prediction,
    :rollout_id,
    :json_fallback,
    :json_retries
  ]

  def schema, do: @schema

  # The options, among a wrapper's own validated options, that are Predict's.
  def take(opts), do: Keyword.take(opts, Keyword.keys(@schema))

  # Validates `opts` against `schema` for the entry point named by `context`,
  # refusing a top-level request option with a pointer to `config:`.
  def validate!(opts, schema, context) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Enum.filter(Keyword.keys(opts), &(&1 in @request_keys)) do
        [] ->
          :ok

        keys ->
          raise ArgumentError,
                "#{context}: request options go under config:, as in " <>
                  "config: #{inspect(Keyword.take(opts, keys))}; got them at the top level"
      end
    end

    Imp.Options.validate!(opts, schema, context)
  end

  def validate!(opts, schema, context), do: Imp.Options.validate!(opts, schema, context)
end
