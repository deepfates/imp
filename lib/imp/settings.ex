defmodule Imp.Settings do
  @moduledoc """
  OTP-backed global settings with process-local overrides.

  The Imp OTP application owns the global settings process in normal production use.
  Calling this module before the application is started attempts to start the
  application, which gives the settings process the same supervision semantics as
  a regular OTP application. The global settings are intentionally mutable and
  node-local; use `context/2` for process-local overrides around a request,
  task, or test.
  """

  use Agent

  @name __MODULE__
  @schema [
    lm: [
      type: :any,
      default: nil,
      doc: "The LM a program without its own `:lm` calls."
    ],
    adapter: [
      type: :any,
      default: Imp.Adapter.Chat,
      doc: "The adapter a program without its own `:adapter` uses."
    ],
    async_max_workers: [
      type: :pos_integer,
      default: 8,
      doc: "How many Imp tasks run at once."
    ],
    track_usage: [
      type: :boolean,
      default: false,
      doc: "Whether each prediction carries its LM usage (`Imp.Prediction.get_lm_usage/1`)."
    ],
    # DSPy `warn_on_type_mismatch` (settings.py, default True).
    warn_on_type_mismatch: [
      type: :boolean,
      default: true,
      doc: "Whether an input value that does not match its field's declared type logs a warning."
    ],
    two_step_extraction_lm: [
      type: :any,
      doc: "The LM `Imp.Adapter.TwoStep` extracts outputs with, when not given to the adapter."
    ]
  ]
  @defaults for {key, spec} <- @schema,
                Keyword.has_key?(spec, :default),
                into: %{},
                do: {key, spec[:default]}
  # Validation must not fill in defaults: `configure/1` merges only the keys
  # it is given.
  @validation_schema for {key, spec} <- @schema, do: {key, Keyword.delete(spec, :default)}
  # Keys that are not settings but look like one, with where each belongs.
  # `configure/1` and `context/2` refuse them rather than carry a value
  # nothing reads.
  @not_settings [
    callbacks: "attach handlers with :telemetry.attach/4 to Imp's [:imp, ...] events instead",
    max_errors:
      "pass :max_errors to BootstrapFewShot.new/2, RandomSearch.new/2, " <>
        "COPRO.compile/5 or Imp.Evaluate.new/3",
    retriever: "give the retriever to the program, as in Imp.rag(program, retriever)"
  ]
  @known_string_keys Map.new(@not_settings ++ @schema, fn {key, _spec} ->
                       {Atom.to_string(key), key}
                     end)
  @context_key :imp_context_stack
  @snapshot_key :imp_settings_snapshot
  @unset :imp_settings_unset

  def start_link(_opts), do: Agent.start_link(fn -> @defaults end, name: @name)

  @doc """
  Updates node-local Imp defaults.

  Use this for application-level defaults such as the LM client or adapter. For
  request, test, Livebook cell, or task-local overrides, prefer `context/2` so
  the override is restored automatically.

  Takes a keyword list or a map; a map may use string keys. An unknown setting
  raises `ArgumentError`. `context/2` also carries keys of the caller's own,
  such as a request id.

  ## Settings

  #{NimbleOptions.docs(@schema)}
  """
  def configure(opts) when is_list(opts) or is_map(opts) do
    updates = normalize_settings(opts, "Imp.configure/1")
    reject_unknown_settings!(updates, "Imp.configure/1")
    ensure_started()
    Agent.update(@name, &Map.merge(&1, updates))
    :ok
  end

  def configure(opts) do
    raise ArgumentError,
          "Imp.configure/1 expects a map or settings pair list; got: #{inspect(opts)}"
  end

  @doc """
  Returns the effective settings for the current process.

  Effective settings are the global defaults plus any nested `context/2`
  overrides in the current process.

      iex> Imp.Settings.context([lm: :local], fn -> Imp.Settings.get().lm end)
      :local

  """
  def get do
    base =
      case Process.get(@snapshot_key, @unset) do
        @unset ->
          ensure_started()
          Agent.get(@name, & &1)

        snapshot ->
          snapshot
      end

    @context_key
    |> Process.get([])
    |> Enum.reverse()
    |> Enum.reduce(base, &Map.merge(&2, &1))
  end

  @doc """
  Fetches one effective setting or raises when the key is absent.

      iex> Imp.Settings.context([request_id: "req-1"], fn -> Imp.Settings.fetch!(:request_id) end)
      "req-1"

  """
  def fetch!(key), do: get() |> Map.fetch!(key)

  @doc """
  Restores global settings to Imp defaults.

  Process-local `context/2` overrides are not global state and are restored by
  the context call itself.
  """
  def reset do
    ensure_started()
    Agent.update(@name, fn _settings -> @defaults end)
    :ok
  end

  @doc """
  Runs a zero-arity function with process-local settings overrides.

  Each context snapshots all effective settings at entry, applies its overrides,
  and restores the previous snapshot even if the function raises. Child processes
  do not inherit process-local settings automatically; Imp-owned task helpers
  capture one complete effective snapshot when supervised async work is submitted.

  Besides Imp's settings (listed under `configure/1`), a context carries keys of
  the caller's own, such as a request id, readable with `get/0` and `fetch!/1`.
  Imp's own settings are type-checked as `configure/1` checks them, and a key
  that is not a setting but reads like one (`:max_errors`, `:retriever`,
  `:callbacks`) raises `ArgumentError` rather than being carried unread.

      iex> Imp.Settings.context([lm: :outer], fn ->
      ...>   Imp.Settings.context([adapter: :inner], fn ->
      ...>     {Imp.Settings.get().lm, Imp.Settings.get().adapter}
      ...>   end)
      ...> end)
      {:outer, :inner}

      iex> parent = self()
      iex> Imp.Settings.context([lm: :parent_only], fn ->
      ...>   task = Task.async(fn -> send(parent, {:child_lm, Imp.Settings.get().lm}) end)
      ...>   Task.await(task)
      ...> end)
      iex> receive do
      ...>   {:child_lm, value} -> value
      ...> end
      nil

  """
  def context(opts, fun) when is_function(fun, 0) do
    settings =
      opts
      |> normalize_settings("Imp.context/2")
      |> then(&Map.merge(get(), &1))

    previous_snapshot = Process.get(@snapshot_key, @unset)
    previous_context = Process.get(@context_key, @unset)
    Process.put(@snapshot_key, settings)
    Process.put(@context_key, [])

    try do
      fun.()
    after
      restore_process_value(@snapshot_key, previous_snapshot)
      restore_process_value(@context_key, previous_context)
    end
  end

  def context(_opts, fun) when not is_function(fun, 0) do
    raise ArgumentError,
          "Imp.context/2 expects a zero-arity function; got: #{inspect(fun)}"
  end

  def context(opts, _fun) do
    raise ArgumentError,
          "Imp.context/2 expects settings as a map or settings pair list; got: #{inspect(opts)}"
  end

  @doc false
  # A NimbleOptions custom type for options that are handed to `context/2`
  # later, such as an optimizer's `:teacher_settings`, so that they are refused
  # when given rather than when first used.
  def validate_overrides(overrides) do
    if Keyword.keyword?(overrides) do
      normalize_settings(overrides, "settings overrides")
      {:ok, overrides}
    else
      {:error, "expected a keyword list of settings, got: #{inspect(overrides)}"}
    end
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  @doc false
  def context_stack, do: Process.get(@context_key, [])

  @doc false
  def snapshot, do: get()

  @doc false
  def with_snapshot(snapshot, fun) when is_map(snapshot) and is_function(fun, 0) do
    previous_snapshot = Process.get(@snapshot_key, @unset)
    previous_context = Process.get(@context_key, @unset)
    Process.put(@snapshot_key, snapshot)
    Process.put(@context_key, [])

    try do
      fun.()
    after
      restore_process_value(@snapshot_key, previous_snapshot)
      restore_process_value(@context_key, previous_context)
    end
  end

  @doc false
  def with_context_stack(stack, fun) when is_list(stack) and is_function(fun, 0) do
    previous = Process.get(@context_key, [])
    Process.put(@context_key, stack)

    try do
      fun.()
    after
      Process.put(@context_key, previous)
    end
  end

  defp ensure_started do
    case Process.whereis(@name) do
      nil -> start_application()
      _pid -> :ok
    end
  end

  # The settings Agent lives under the :imp supervision tree. If the
  # application cannot start we fail loudly instead of falling back to an
  # unsupervised Agent: a silent unsupervised fallback survives its first
  # crash as amnesia (settings reset to defaults with no restart report).
  defp start_application do
    case Application.ensure_all_started(:imp) do
      {:ok, _apps} ->
        :ok

      {:error, reason} ->
        raise """
        Imp.Settings requires the :imp application, and starting it failed: #{inspect(reason)}

        Imp's settings Agent runs under the :imp supervision tree. Add :imp
        to your application's dependencies (Mix starts it automatically), or
        start it explicitly with Application.ensure_all_started(:imp) before
        calling Imp.
        """
    end
  end

  defp normalize_settings(settings, context) when is_list(settings) or is_map(settings) do
    settings
    |> Enum.reduce({%{}, %{}}, fn
      {raw_key, value}, {normalized, seen} ->
        key = normalize_setting_key(raw_key)
        reject_colliding_key!(seen, key, raw_key, context)

        {put_validated_setting(normalized, key, value, context), Map.put(seen, key, raw_key)}

      invalid_entry, _acc ->
        raise ArgumentError,
              "#{context} expects settings as {key, value} pairs; got entry: #{inspect(invalid_entry)}"
    end)
    |> elem(0)
  end

  defp normalize_settings(settings, context) do
    raise ArgumentError,
          "#{context} expects settings as a map or settings pair list; got: #{inspect(settings)}"
  end

  defp normalize_setting_key(key) when is_binary(key), do: Map.get(@known_string_keys, key, key)
  defp normalize_setting_key(key), do: key

  defp reject_colliding_key!(seen, key, raw_key, context) do
    case Map.fetch(seen, key) do
      {:ok, previous_key} when previous_key != raw_key ->
        raise ArgumentError,
              "#{context} received colliding setting keys #{inspect(previous_key)} and #{inspect(raw_key)}"

      _other ->
        :ok
    end
  end

  defp put_validated_setting(normalized, key, value, context) when is_atom(key) do
    if instead = @not_settings[key] do
      raise ArgumentError,
            "#{context}: #{inspect(key)} is not a setting (got #{inspect(value)}); #{instead}"
    end

    if key in Keyword.keys(@schema) do
      Imp.Options.validate!([{key, value}], @validation_schema, context)
    end

    Map.put(normalized, key, value)
  end

  defp put_validated_setting(normalized, key, value, _context),
    do: Map.put(normalized, key, value)

  defp reject_unknown_settings!(settings, context) do
    case Map.keys(settings) -- Keyword.keys(@schema) do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "#{context}: unknown settings #{inspect(unknown)}, known settings are: " <>
                "#{inspect(Keyword.keys(@schema))}. Imp.context/2 carries settings of your own."
    end
  end

  defp restore_process_value(key, @unset), do: Process.delete(key)
  defp restore_process_value(key, value), do: Process.put(key, value)
end
