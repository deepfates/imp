defmodule DSEx.Tracking.WandB do
  @moduledoc """
  Isolated client for the W&B 0.21.x run protocol.

  The public API is transport-independent and keeps run state immutable. Pass
  the returned client from each successful operation into the next operation.

  ## Version sensitivity

  W&B's GraphQL and `file_stream` interfaces are internal protocols, not stable
  public APIs. This implementation is pinned to wire behavior from the official
  W&B SDK v0.21.3 in an isolated internal module. A W&B SDK or server upgrade
  requires recording and comparing the requests before changing that module.

  `:gepa_v0_1_1` finish semantics reproduce GEPA v0.1.1, whose context manager
  calls `wandb.finish()` without propagating exception status. `:accurate`
  semantics convert failed outcomes to a nonzero W&B exit code.
  """

  alias DSEx.Tracking.WandB.V0_21_3, as: Protocol

  @default_base_url "https://api.wandb.ai"
  @init_keys [:entity, :project, :id, :name, :group, :job_type, :tags, :notes, :resume, :base_url]
  @constructor_keys [:transport, :api_key, :bearer_token, :status_mode, :request_opts]
  @resume_values [
    nil,
    false,
    true,
    :allow,
    :must,
    :never,
    :auto,
    "allow",
    "must",
    "never",
    "auto"
  ]
  @status_modes [:gepa_v0_1_1, :accurate]

  defstruct transport: nil,
            authorization: nil,
            request_opts: [],
            status_mode: :accurate,
            base_url: @default_base_url,
            entity: nil,
            project: nil,
            id: nil,
            storage_id: nil,
            name: nil,
            group: nil,
            job_type: nil,
            tags: [],
            notes: nil,
            resume: nil,
            history_offset: 0,
            last_step: -1,
            summary: %{},
            finished?: false

  @type status_mode :: :gepa_v0_1_1 | :accurate
  @type outcome ::
          :success
          | :finished
          | :failed
          | :failure
          | :killed
          | :cancelled
          | :error
          | {:failed, non_neg_integer()}
  @type t :: %__MODULE__{}

  @doc "Creates a client without making a network request."
  @spec new(keyword()) :: t()
  def new(opts) do
    opts = validate_keyword!(opts, "new/1")
    reject_unknown!(opts, @constructor_keys, "new/1")

    transport = Keyword.get(opts, :transport)

    unless is_atom(transport) or is_function(transport, 5) do
      raise ArgumentError, "#{inspect(__MODULE__)}.new/1 requires :transport"
    end

    status_mode = Keyword.get(opts, :status_mode, :accurate)

    unless status_mode in @status_modes do
      raise ArgumentError,
            "#{inspect(__MODULE__)}.new/1 :status_mode must be one of #{inspect(@status_modes)}"
    end

    request_opts = Keyword.get(opts, :request_opts, [])

    unless Keyword.keyword?(request_opts) do
      raise ArgumentError, "#{inspect(__MODULE__)}.new/1 :request_opts must be a keyword list"
    end

    %__MODULE__{
      transport: transport,
      authorization: authorization!(opts),
      request_opts: request_opts,
      status_mode: status_mode
    }
  end

  @doc "Verifies credentials, resolves the entity, and creates or resumes a run."
  @spec init(t(), keyword() | map()) :: {:ok, t()} | {:error, term()}
  def init(%__MODULE__{} = client, opts) do
    opts = normalize_init_opts!(opts)
    reject_unknown!(opts, @init_keys, "init/2")
    validate_init_values!(opts)

    candidate = apply_init_options(client, opts)

    with {:ok, viewer} <- Protocol.verify(candidate),
         {:ok, candidate} <- resolve_entity(candidate, viewer),
         :ok <- require_project(candidate),
         {:ok, upserted} <- Protocol.upsert_bucket(candidate, upsert_variables(candidate)) do
      apply_upsert(candidate, upserted)
    end
  end

  @doc "Appends one history row and enforces strictly increasing steps."
  @spec log(t(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def log(client, metrics, opts \\ [])

  def log(%__MODULE__{} = client, metrics, opts) when is_map(metrics) do
    opts = validate_keyword!(opts, "log/3")
    reject_unknown!(opts, [:step], "log/3")

    with :ok <- active(client),
         {:ok, step} <- next_step(client, Keyword.get(opts, :step)),
         row = metrics |> stringify_keys() |> Map.put("_step", step),
         :ok <- Protocol.stream(client, Protocol.history_payload(client.history_offset, row)) do
      {:ok, %{client | history_offset: client.history_offset + 1, last_step: step}}
    end
  end

  def log(%__MODULE__{}, metrics, _opts),
    do: {:error, {:invalid_wandb_metrics, metrics}}

  @doc "Replaces the complete W&B summary document at file-stream offset zero."
  @spec replace_summary(t(), map()) :: {:ok, t()} | {:error, term()}
  def replace_summary(%__MODULE__{} = client, summary) when is_map(summary) do
    summary = stringify_keys(summary)

    with :ok <- active(client),
         :ok <- Protocol.stream(client, Protocol.summary_payload(summary)) do
      {:ok, %{client | summary: summary}}
    end
  end

  def replace_summary(%__MODULE__{}, summary),
    do: {:error, {:invalid_wandb_summary, summary}}

  @doc "Merges values into the local summary and sends a full replacement."
  @spec merge_summary(t(), map()) :: {:ok, t()} | {:error, term()}
  def merge_summary(%__MODULE__{} = client, values) when is_map(values) do
    replace_summary(client, Map.merge(client.summary, stringify_keys(values)))
  end

  def merge_summary(%__MODULE__{}, values),
    do: {:error, {:invalid_wandb_summary, values}}

  @doc "Uploads a W&B table file and logs its media reference as a history row."
  @spec log_table(t(), String.t(), [String.t()], [list()], keyword()) ::
          {:ok, t()} | {:error, term()}
  def log_table(%__MODULE__{} = client, key, columns, rows, opts \\ []) do
    with :ok <- active(client),
         :ok <- validate_table(key, columns, rows),
         {:ok, step} <- media_step(client, opts, "log_table/5") do
      do_log_table(client, key, columns, rows, step)
    end
  end

  @doc "Uploads HTML and logs it to history; by default it also replaces that summary key."
  @spec log_html(t(), String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def log_html(client, key, html, opts \\ [])

  def log_html(%__MODULE__{} = client, key, html, opts)
      when is_binary(key) and is_binary(html) do
    opts = validate_keyword!(opts, "log_html/4")
    reject_unknown!(opts, [:step, :summary, :inject], "log_html/4")
    summary? = Keyword.get(opts, :summary, true)
    contents = if Keyword.get(opts, :inject, true), do: inject_html(html), else: html

    with :ok <- active(client),
         true <- is_boolean(summary?) || {:error, {:invalid_wandb_option, :summary, summary?}},
         {:ok, step} <- next_step(client, Keyword.get(opts, :step)) do
      do_log_html(client, key, contents, step, summary?)
    end
  end

  def log_html(%__MODULE__{}, key, html, _opts),
    do: {:error, {:invalid_wandb_html, key, html}}

  @doc "Sends the terminal W&B file-stream payload."
  @spec finish(t(), outcome()) :: {:ok, t()} | {:error, term()}
  def finish(%__MODULE__{} = client, outcome \\ :success) do
    with :ok <- active(client),
         {:ok, exit_code} <- exit_code(client.status_mode, outcome),
         :ok <- Protocol.stream(client, Protocol.finish_payload(exit_code)) do
      {:ok, %{client | finished?: true}}
    end
  end

  defp authorization!(opts) do
    api_key = Keyword.get(opts, :api_key)
    bearer_token = Keyword.get(opts, :bearer_token)

    case {api_key, bearer_token} do
      {key, nil} when is_binary(key) and key != "" ->
        "Basic " <> Base.encode64("api:" <> key)

      {nil, token} when is_binary(token) and token != "" ->
        "Bearer " <> token

      {nil, nil} ->
        raise ArgumentError,
              "#{inspect(__MODULE__)}.new/1 requires exactly one of :api_key or :bearer_token"

      _ ->
        raise ArgumentError,
              "#{inspect(__MODULE__)}.new/1 requires exactly one non-empty :api_key or :bearer_token"
    end
  end

  defp normalize_init_opts!(opts) when is_map(opts) do
    Enum.map(opts, fn
      {key, value} when is_atom(key) ->
        {key, value}

      {key, value} when is_binary(key) ->
        {known_init_key!(key), value}

      {key, _value} ->
        raise ArgumentError,
              "#{inspect(__MODULE__)}.init/2 option keys must be atoms or strings, got: #{inspect(key)}"
    end)
  end

  defp normalize_init_opts!(opts), do: validate_keyword!(opts, "init/2")

  defp known_init_key!(key) do
    case Enum.find(@init_keys, &(Atom.to_string(&1) == key)) do
      nil ->
        raise ArgumentError, "#{inspect(__MODULE__)}.init/2 unsupported option: #{inspect(key)}"

      atom ->
        atom
    end
  end

  defp validate_init_values!(opts) do
    validate_string_options!(opts)
    validate_tags!(Keyword.fetch(opts, :tags))
    validate_resume!(Keyword.get(opts, :resume))
    validate_optional_base_url!(Keyword.fetch(opts, :base_url))
  end

  defp validate_string_options!(opts) do
    Enum.each([:entity, :project, :id, :name, :group, :job_type, :notes, :base_url], fn key ->
      case Keyword.fetch(opts, key) do
        {:ok, value} when not (is_binary(value) and value != "") ->
          raise ArgumentError,
                "#{inspect(__MODULE__)}.init/2 :#{key} must be a non-empty string"

        _ ->
          :ok
      end
    end)
  end

  defp validate_tags!(:error), do: :ok

  defp validate_tags!({:ok, tags}) when is_list(tags) do
    unless Enum.all?(tags, &is_binary/1) do
      raise ArgumentError, "#{inspect(__MODULE__)}.init/2 :tags must be a list of strings"
    end
  end

  defp validate_tags!({:ok, _tags}) do
    raise ArgumentError, "#{inspect(__MODULE__)}.init/2 :tags must be a list of strings"
  end

  defp validate_resume!(resume) when resume in @resume_values, do: :ok

  defp validate_resume!(_resume) do
    raise ArgumentError,
          "#{inspect(__MODULE__)}.init/2 :resume must be allow, must, never, auto, true, false, or nil"
  end

  defp validate_optional_base_url!(:error), do: :ok
  defp validate_optional_base_url!({:ok, base_url}), do: validate_base_url!(base_url)

  defp validate_base_url!(base_url) do
    parsed = URI.parse(base_url)

    unless parsed.scheme in ["http", "https"] and is_binary(parsed.host) do
      raise ArgumentError,
            "#{inspect(__MODULE__)}.init/2 :base_url must be an HTTP(S) origin"
    end
  end

  defp apply_init_options(client, opts) do
    base_url = opts |> Keyword.get(:base_url, @default_base_url) |> String.trim_trailing("/")

    %{
      client
      | base_url: base_url,
        entity: Keyword.get(opts, :entity),
        project: Keyword.get(opts, :project),
        id: Keyword.get(opts, :id, generate_id()),
        name: Keyword.get(opts, :name),
        group: Keyword.get(opts, :group),
        job_type: Keyword.get(opts, :job_type),
        tags: Keyword.get(opts, :tags, []),
        notes: Keyword.get(opts, :notes),
        resume: Keyword.get(opts, :resume)
    }
  end

  defp resolve_entity(%{entity: entity} = client, _viewer) when is_binary(entity),
    do: {:ok, client}

  defp resolve_entity(client, %{"entity" => entity}) when is_binary(entity) and entity != "",
    do: {:ok, %{client | entity: entity}}

  defp resolve_entity(_client, viewer),
    do: {:error, {:wandb_protocol_error, :viewer_entity_missing, viewer}}

  defp require_project(%{project: project}) when is_binary(project) and project != "", do: :ok
  defp require_project(_client), do: {:error, {:wandb_init_option_required, :project}}

  defp upsert_variables(client) do
    %{
      "id" => nil,
      "name" => client.id,
      "project" => client.project,
      "entity" => client.entity,
      "groupName" => client.group,
      "displayName" => client.name,
      "notes" => client.notes,
      "jobType" => client.job_type,
      "state" => "running",
      "tags" => client.tags
    }
  end

  defp apply_upsert(client, %{"bucket" => bucket, "inserted" => inserted})
       when is_map(bucket) and is_boolean(inserted) do
    with :ok <- enforce_resume(client.resume, inserted),
         {:ok, storage_id} <- fetch_binary(bucket, "id"),
         {:ok, run_id} <- fetch_binary(bucket, "name") do
      offset = Map.get(bucket, "historyLineCount", 0) || 0

      if is_integer(offset) and offset >= 0 do
        {:ok,
         %{
           client
           | storage_id: storage_id,
             id: run_id,
             history_offset: offset,
             last_step: offset - 1
         }}
      else
        {:error, {:wandb_protocol_error, :invalid_history_line_count, offset}}
      end
    end
  end

  defp apply_upsert(_client, response),
    do: {:error, {:wandb_protocol_error, :invalid_upsert_bucket, response}}

  defp enforce_resume(resume, true) when resume in [:must, "must"],
    do: {:error, {:wandb_resume_error, :run_did_not_exist}}

  defp enforce_resume(resume, true) when resume in [:never, "never"], do: :ok

  defp enforce_resume(resume, false) when resume in [:must, "must", true], do: :ok

  defp enforce_resume(resume, false) when resume in [:never, "never"],
    do: {:error, {:wandb_resume_error, :run_already_exists}}

  defp enforce_resume(_resume, _inserted), do: :ok

  defp fetch_binary(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value -> {:error, {:wandb_protocol_error, {:invalid_field, key}, value}}
    end
  end

  defp next_step(client, nil), do: {:ok, client.last_step + 1}

  defp next_step(client, step) when is_integer(step) and step > client.last_step,
    do: {:ok, step}

  defp next_step(client, step) when is_integer(step),
    do: {:error, {:wandb_non_monotonic_step, step, client.last_step}}

  defp next_step(_client, step), do: {:error, {:invalid_wandb_step, step}}

  defp media_step(client, opts, context) do
    opts = validate_keyword!(opts, context)
    reject_unknown!(opts, [:step], context)
    next_step(client, Keyword.get(opts, :step))
  end

  defp validate_table(key, columns, rows)
       when is_binary(key) and key != "" and is_list(columns) and is_list(rows) do
    cond do
      not Enum.all?(columns, &is_binary/1) ->
        {:error, {:invalid_wandb_table_columns, columns}}

      not Enum.all?(rows, &(is_list(&1) and length(&1) == length(columns))) ->
        {:error, {:invalid_wandb_table_rows, rows}}

      true ->
        :ok
    end
  end

  defp validate_table(key, columns, rows),
    do: {:error, {:invalid_wandb_table, key, columns, rows}}

  defp do_log_table(client, key, columns, rows, step) do
    contents = Jason.encode!(%{"columns" => columns, "data" => rows})
    path = Protocol.media_path(:table, key, step, contents)

    reference =
      Protocol.media_ref(:table, path, contents,
        ncols: length(columns),
        nrows: length(rows),
        log_mode: "IMMUTABLE"
      )

    case Protocol.upload_media(client, path, contents) do
      :ok -> log(client, %{key => reference}, step: step)
      {:error, _reason} = error -> error
    end
  end

  defp do_log_html(client, key, contents, step, summary?) do
    path = Protocol.media_path(:html, key, step, contents)
    reference = Protocol.media_ref(:html, path, contents)

    case Protocol.upload_media(client, path, contents) do
      :ok -> log_and_maybe_summarize_html(client, key, reference, step, summary?)
      {:error, _reason} = error -> error
    end
  end

  defp log_and_maybe_summarize_html(client, key, reference, step, summary?) do
    case log(client, %{key => reference}, step: step) do
      {:ok, logged} -> maybe_summarize_html(logged, key, reference, summary?)
      {:error, _reason} = error -> error
    end
  end

  defp maybe_summarize_html(client, _key, _reference, false), do: {:ok, client}

  defp maybe_summarize_html(client, key, reference, true),
    do: merge_summary(client, %{key => reference})

  defp inject_html(html) do
    injection =
      ~s(<base target="_blank"><link rel="stylesheet" type="text/css" href="https://app.wandb.ai/normalize.css" />)

    cond do
      String.contains?(html, "<head>") ->
        String.replace(html, "<head>", "<head>" <> injection, global: false)

      String.contains?(html, "<html>") ->
        String.replace(html, "<html>", "<html><head>#{injection}</head>", global: false)

      true ->
        injection <> html
    end
    |> String.trim()
  end

  defp exit_code(:gepa_v0_1_1, outcome) do
    case valid_outcome(outcome) do
      :ok -> {:ok, 0}
      error -> error
    end
  end

  defp exit_code(:accurate, outcome) when outcome in [:success, :finished], do: {:ok, 0}

  defp exit_code(:accurate, outcome)
       when outcome in [:failed, :failure, :killed, :cancelled, :error],
       do: {:ok, 1}

  defp exit_code(:accurate, {:failed, code}) when is_integer(code) and code > 0,
    do: {:ok, code}

  defp exit_code(_mode, outcome), do: {:error, {:invalid_wandb_outcome, outcome}}

  defp valid_outcome(outcome)
       when outcome in [:success, :finished, :failed, :failure, :killed, :cancelled, :error],
       do: :ok

  defp valid_outcome({:failed, code}) when is_integer(code) and code > 0, do: :ok
  defp valid_outcome(outcome), do: {:error, {:invalid_wandb_outcome, outcome}}

  defp active(%{finished?: true}), do: {:error, :wandb_run_finished}
  defp active(%{id: nil}), do: {:error, :wandb_run_not_initialized}
  defp active(_client), do: :ok

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp generate_id do
    :crypto.strong_rand_bytes(6)
    |> Base.url_encode64(padding: false)
  end

  defp validate_keyword!(opts, context) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
    else
      raise ArgumentError, "#{inspect(__MODULE__)}.#{context} expects keyword options"
    end
  end

  defp validate_keyword!(_opts, context),
    do: raise(ArgumentError, "#{inspect(__MODULE__)}.#{context} expects keyword options")

  defp reject_unknown!(opts, allowed, context) do
    case Keyword.keys(opts) -- allowed do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "#{inspect(__MODULE__)}.#{context} unsupported options: #{inspect(unknown)}"
    end
  end
end
