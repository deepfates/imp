defmodule Imp.Playbook.Policy do
  @moduledoc """
  Hard limits and admission rules for a `Imp.Playbook`.

  Limits cover normalized UTF-8 content and every retained semantic string.
  The defaults intentionally keep a playbook small enough to inspect and pass
  through model contexts.
  """

  @absolute_max_entries 1_024
  @absolute_max_tombstones 4_096
  @absolute_max_entry_bytes 262_144
  @absolute_max_playbook_bytes 1_048_576
  @absolute_max_operations 256
  @absolute_max_section_bytes 1_024
  @absolute_max_provenance_items 1_024
  @absolute_max_source_id_bytes 1_024
  @absolute_max_counter 9_223_372_036_854_775_807

  @policy_keys [
    :max_entries,
    :max_tombstones,
    :max_entry_bytes,
    :max_playbook_bytes,
    :max_operations,
    :max_section_bytes,
    :max_provenance_items,
    :max_source_id_bytes,
    :max_counter,
    :reject_secrets
  ]
  defstruct max_entries: 128,
            max_tombstones: 512,
            max_entry_bytes: 16_384,
            max_playbook_bytes: 262_144,
            max_operations: 64,
            max_section_bytes: 128,
            max_provenance_items: 64,
            max_source_id_bytes: 128,
            max_counter: 1_000_000,
            reject_secrets: true

  @type t :: %__MODULE__{
          max_entries: pos_integer(),
          max_tombstones: pos_integer(),
          max_entry_bytes: pos_integer(),
          max_playbook_bytes: pos_integer(),
          max_operations: pos_integer(),
          max_section_bytes: pos_integer(),
          max_provenance_items: pos_integer(),
          max_source_id_bytes: pos_integer(),
          max_counter: pos_integer(),
          reject_secrets: boolean()
        }

  @doc "Builds and validates a policy. Values cannot exceed the domain hard caps."
  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    attrs = if is_list(opts), do: Map.new(opts), else: opts

    unless is_map(attrs) do
      raise ArgumentError, "playbook policy options must be a keyword list or map"
    end

    unknown = Map.keys(attrs) -- @policy_keys

    if unknown != [],
      do: raise(ArgumentError, "unknown playbook policy options: #{inspect(unknown)}")

    policy = struct!(__MODULE__, attrs)
    validate_limit!(policy.max_entries, @absolute_max_entries, :max_entries)
    validate_limit!(policy.max_tombstones, @absolute_max_tombstones, :max_tombstones)
    validate_limit!(policy.max_entry_bytes, @absolute_max_entry_bytes, :max_entry_bytes)
    validate_limit!(policy.max_playbook_bytes, @absolute_max_playbook_bytes, :max_playbook_bytes)
    validate_limit!(policy.max_operations, @absolute_max_operations, :max_operations)
    validate_limit!(policy.max_section_bytes, @absolute_max_section_bytes, :max_section_bytes)

    validate_limit!(
      policy.max_provenance_items,
      @absolute_max_provenance_items,
      :max_provenance_items
    )

    validate_limit!(
      policy.max_source_id_bytes,
      @absolute_max_source_id_bytes,
      :max_source_id_bytes
    )

    validate_limit!(policy.max_counter, @absolute_max_counter, :max_counter)

    unless is_boolean(policy.reject_secrets) do
      raise ArgumentError, "playbook policy reject_secrets must be a boolean"
    end

    policy
  end

  @doc false
  @spec validate_content(String.t(), t()) :: :ok | {:error, term()}
  def validate_content(content, %__MODULE__{} = policy) when is_binary(content) do
    cond do
      content == "" ->
        {:error, :empty_content}

      not String.valid?(content) ->
        {:error, :invalid_utf8}

      byte_size(content) > policy.max_entry_bytes ->
        {:error, {:entry_too_large, byte_size(content)}}

      policy.reject_secrets and Imp.Redaction.redact(content) != content ->
        {:error, :secret_content}

      true ->
        :ok
    end
  end

  def validate_content(_content, _policy), do: {:error, :content_must_be_a_string}

  @doc false
  @spec validate_section(term(), t()) :: :ok | {:error, term()}
  def validate_section(section, %__MODULE__{} = policy) when is_binary(section) do
    cond do
      section == "" ->
        {:error, :empty_section}

      not String.valid?(section) ->
        {:error, :invalid_section_utf8}

      String.contains?(section, "\n") ->
        {:error, :invalid_section}

      byte_size(section) > policy.max_section_bytes ->
        {:error, {:section_too_large, byte_size(section)}}

      policy.reject_secrets and Imp.Redaction.redact(section) != section ->
        {:error, :secret_section}

      true ->
        :ok
    end
  end

  def validate_section(_section, _policy), do: {:error, :section_must_be_a_string}

  @doc false
  @spec validate_counter(term(), t()) :: :ok | {:error, term()}
  def validate_counter(counter, %__MODULE__{} = policy)
      when is_integer(counter) and counter >= 0 and counter <= policy.max_counter,
      do: :ok

  def validate_counter(counter, %__MODULE__{} = policy),
    do: {:error, {:invalid_counter, counter, policy.max_counter}}

  defp validate_limit!(value, maximum, _name)
       when is_integer(value) and value > 0 and value <= maximum,
       do: :ok

  defp validate_limit!(value, maximum, name) do
    raise ArgumentError,
          "playbook policy #{name} must be an integer from 1 through #{maximum}, got: #{inspect(value)}"
  end
end
