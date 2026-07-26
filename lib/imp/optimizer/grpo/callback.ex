defmodule Imp.Optimizer.GRPO.Callback do
  @moduledoc """
  Stable, data-only callback identity for resumable GRPO jobs.

  A callback binds a trusted, already-loaded module and function to a
  consumer-owned versioned id and JSON-safe configuration. Imp persists only
  that identity and the configuration digest; it never serializes executable
  code or reconstructs atoms from saved data.

  Reward callbacks receive `(example, prediction, config)`. Validation
  callbacks receive `(program, dataset, context, config)`.
  """

  alias Imp.Clients.TRLProtocol

  @enforce_keys [:kind, :module, :function, :id, :config, :config_sha256]
  defstruct [:kind, :module, :function, :id, :config, :config_sha256]

  @type kind :: :reward | :validation
  @type t :: %__MODULE__{
          kind: kind(),
          module: module(),
          function: atom(),
          id: String.t(),
          config: term(),
          config_sha256: String.t()
        }

  def reward(module, function, opts \\ []), do: new(:reward, module, function, opts)
  def validation(module, function, opts \\ []), do: new(:validation, module, function, opts)

  def new(kind, module, function, opts)
      when kind in [:reward, :validation] and is_atom(module) and is_atom(function) and
             is_list(opts) do
    id = Keyword.fetch!(opts, :id)
    config = Keyword.get(opts, :config, %{})
    arity = arity(kind)

    unless is_binary(id) and id != "" do
      raise ArgumentError, "GRPO callback id must be a non-empty versioned string"
    end

    unless Code.ensure_loaded?(module) and function_exported?(module, function, arity) do
      raise ArgumentError,
            "GRPO #{kind} callback must export #{inspect(module)}.#{function}/#{arity}"
    end

    projected = Imp.Optimizer.Report.json_projection(config)

    unless projected == config do
      raise ArgumentError, "GRPO callback config must already be JSON-safe data"
    end

    callback = %__MODULE__{
      kind: kind,
      module: module,
      function: function,
      id: id,
      config: config,
      config_sha256: TRLProtocol.digest(config)
    }

    :ok = validate(callback, kind)
    callback
  end

  def validate(%__MODULE__{} = callback, expected_kind)
      when expected_kind in [:reward, :validation] do
    expected_arity = arity(expected_kind)

    cond do
      callback.kind != expected_kind ->
        {:error, :grpo_callback_kind_mismatch}

      not is_atom(callback.module) ->
        {:error, :grpo_callback_module_required}

      not is_atom(callback.function) ->
        {:error, :grpo_callback_function_required}

      not is_binary(callback.id) or callback.id == "" ->
        {:error, :grpo_callback_id_required}

      not Code.ensure_loaded?(callback.module) ->
        {:error, :grpo_callback_module_unavailable}

      not function_exported?(callback.module, callback.function, expected_arity) ->
        {:error, :grpo_callback_function_unavailable}

      Imp.Optimizer.Report.json_projection(callback.config) != callback.config ->
        {:error, :grpo_callback_config_not_json_safe}

      TRLProtocol.digest(callback.config) != callback.config_sha256 ->
        {:error, :grpo_callback_config_digest_mismatch}

      true ->
        :ok
    end
  end

  def identity(%__MODULE__{} = callback) do
    :ok = validate(callback, callback.kind)

    %{
      contract: "imp_grpo_callback_v1",
      kind: callback.kind,
      module: Atom.to_string(callback.module),
      function: Atom.to_string(callback.function),
      id: callback.id,
      config_sha256: callback.config_sha256
    }
  end

  def invoke(%__MODULE__{kind: :reward} = callback, example, prediction) do
    :ok = validate(callback, :reward)
    apply(callback.module, callback.function, [example, prediction, callback.config])
  end

  def invoke(%__MODULE__{kind: :validation} = callback, program, dataset, context) do
    :ok = validate(callback, :validation)
    apply(callback.module, callback.function, [program, dataset, context, callback.config])
  end

  defp arity(:reward), do: 3
  defp arity(:validation), do: 4
end
