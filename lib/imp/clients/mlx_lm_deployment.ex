defmodule Imp.Clients.MLXLMDeployment do
  @moduledoc """
  Supervised local serving for a verified fused `MLXLMTrainer` artifact.

  `start/2` revalidates the complete fused tree, launches the pinned
  `mlx_lm.server` command recorded by the training job, and succeeds only when
  `/v1/models` advertises the exact fused path. The returned ReqLLM is therefore
  bound to verified trained bytes rather than a model-name substitution.

  Every launch receives a new empty, deployment-owned Hugging Face,
  Transformers, and XDG cache environment. The server still receives the
  verified local artifact path explicitly; ambient model catalogs cannot add a
  second advertised identity. The owned cache is removed after startup failure,
  explicit stop, server exit, or application shutdown.

  Deployments are shared per fused artifact inside the Imp application and can
  be stopped explicitly with `stop/1`. Application shutdown also terminates the
  supervised external process group.
  """

  alias Imp.Clients.{MLXLMTrainer, TrainingJob}

  @enforce_keys [:artifact_path, :artifact_sha256, :base_url, :lm, :pid]
  defstruct [:artifact_path, :artifact_sha256, :base_url, :lm, :pid]

  @type t :: %__MODULE__{
          artifact_path: Path.t(),
          artifact_sha256: String.t(),
          base_url: String.t(),
          lm: Imp.Clients.ReqLLM.t(),
          pid: pid()
        }

  @doc "Starts or reuses the supervised server for a completed fused MLX job."
  @spec start(TrainingJob.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(%TrainingJob{} = job, opts \\ []) do
    with :ok <- validate_opts(opts),
         {:ok, manifest} <- MLXLMTrainer.verify_job(job),
         :ok <- require_fused_manifest(manifest),
         {:ok, config} <- deployment_config(job, manifest, opts) do
      start_config(config)
    end
  end

  @doc "Stops the supervised server for a deployment or completed MLX job."
  @spec stop(t() | TrainingJob.t()) :: :ok | {:error, term()}
  def stop(%__MODULE__{pid: pid}) when is_pid(pid), do: terminate(pid)

  def stop(%TrainingJob{result_model: path}) when is_binary(path) do
    case Registry.lookup(Imp.Clients.MLXLMDeployment.Registry, deployment_key(path)) do
      [{pid, _value}] -> terminate(pid)
      [] -> :ok
    end
  end

  def stop(_deployment), do: {:error, :invalid_mlx_lm_deployment}

  @doc "Returns the live deployment for a job, if one exists."
  @spec lookup(TrainingJob.t()) :: {:ok, t()} | :error
  def lookup(%TrainingJob{result_model: path}) when is_binary(path) do
    case Registry.lookup(Imp.Clients.MLXLMDeployment.Registry, deployment_key(path)) do
      [{pid, _value}] -> GenServer.call(pid, :deployment, 30_000)
      [] -> :error
    end
  catch
    :exit, _reason -> :error
  end

  def lookup(%TrainingJob{}), do: :error

  @doc false
  def child_spec(config) do
    %{
      id: {__MODULE__, config.key},
      start: {Imp.Clients.MLXLMDeployment.Worker, :start_link, [config]},
      restart: :temporary
    }
  end

  defp start_config(config) do
    case DynamicSupervisor.start_child(Imp.Clients.MLXLMDeployment.Supervisor, child_spec(config)) do
      {:ok, pid} -> GenServer.call(pid, :deployment, config.startup_timeout + 5_000)
      {:error, {:already_started, pid}} -> existing_deployment(pid, config)
      {:error, reason} -> {:error, {:mlx_lm_deployment_start_failed, reason}}
    end
  catch
    :exit, reason -> {:error, {:mlx_lm_deployment_start_failed, reason}}
  end

  defp existing_deployment(pid, config) do
    case GenServer.call(pid, {:deployment, config}, 30_000) do
      {:ok, %__MODULE__{} = deployment} -> {:ok, deployment}
      {:error, _reason} = error -> error
    end
  catch
    :exit, reason -> {:error, {:mlx_lm_deployment_lookup_failed, reason}}
  end

  defp terminate(pid) do
    case GenServer.call(pid, :stop, 15_000) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mlx_lm_deployment_stop_failed, reason}}
    end
  catch
    :exit, {:noproc, _details} -> :ok
    :exit, reason -> {:error, {:mlx_lm_deployment_stop_failed, reason}}
  end

  defp deployment_config(job, manifest, opts) do
    spec = manifest["spec"]["deployment"]
    artifact_path = Path.expand(job.result_model)
    artifact_sha256 = manifest["fused_tree"]["sha256"]
    port = Keyword.get(opts, :port, spec["port"])

    config = %{
      key: deployment_key(artifact_path),
      artifact_path: artifact_path,
      artifact_sha256: artifact_sha256,
      inventory: manifest["fused_tree"],
      executable: spec["executable"],
      args: spec["args"],
      host: spec["host"],
      port: port,
      max_tokens: spec["max_tokens"],
      startup_timeout: spec["startup_timeout"],
      kill_grace_ms: spec["kill_grace_ms"],
      max_output_bytes: spec["max_output_bytes"],
      lm_opts: Keyword.get(opts, :lm_opts, []),
      req_module: Keyword.get(opts, :req_module, ReqLLM)
    }

    if valid_config?(config), do: {:ok, config}, else: {:error, :invalid_mlx_lm_deployment_spec}
  end

  defp require_fused_manifest(%{"schema_version" => 2, "status" => "succeeded"}), do: :ok
  defp require_fused_manifest(_manifest), do: {:error, :mlx_lm_job_is_not_deployable}

  defp validate_opts(opts) when is_list(opts) do
    allowed = [:port, :lm_opts, :req_module]

    cond do
      not Keyword.keyword?(opts) -> {:error, :invalid_mlx_lm_deployment_options}
      Keyword.keys(opts) -- allowed != [] -> {:error, :invalid_mlx_lm_deployment_options}
      not valid_port?(Keyword.get(opts, :port, 0)) -> {:error, :invalid_mlx_lm_deployment_port}
      not Keyword.keyword?(Keyword.get(opts, :lm_opts, [])) -> {:error, :invalid_mlx_lm_lm_opts}
      not is_atom(Keyword.get(opts, :req_module, ReqLLM)) -> {:error, :invalid_mlx_lm_req_module}
      true -> :ok
    end
  end

  defp validate_opts(_opts), do: {:error, :invalid_mlx_lm_deployment_options}

  defp valid_config?(config) do
    is_binary(config.artifact_path) and is_binary(config.artifact_sha256) and
      is_binary(config.executable) and config.executable != "" and is_list(config.args) and
      Enum.all?(config.args, &is_binary/1) and
      config.host in ["127.0.0.1", "localhost", "::1"] and valid_port?(config.port) and
      positive_integer?(config.max_tokens) and positive_integer?(config.startup_timeout) and
      is_integer(config.kill_grace_ms) and config.kill_grace_ms >= 0 and
      positive_integer?(config.max_output_bytes) and Keyword.keyword?(config.lm_opts) and
      is_atom(config.req_module)
  end

  defp valid_port?(port), do: is_integer(port) and port >= 0 and port <= 65_535
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp deployment_key(path), do: {:fused_mlx_lm, Path.expand(path)}
end

defmodule Imp.Clients.MLXLMDeployment.Worker do
  @moduledoc false

  use GenServer

  alias Imp.Clients.{MLXLMArtifact, MLXLMDeployment, ReqLLM}

  def start_link(config) do
    GenServer.start_link(__MODULE__, config,
      name: {:via, Registry, {Imp.Clients.MLXLMDeployment.Registry, config.key}}
    )
  end

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)

    case launch(config) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:deployment, _from, state) do
    case verify_live(state) do
      :ok -> {:reply, {:ok, state.deployment}, state}
      {:error, reason} -> {:stop, reason, {:error, reason}, state}
    end
  end

  def handle_call({:deployment, config}, _from, state) do
    config = if config.port == 0, do: Map.put(config, :port, state.config.port), else: config

    cond do
      comparable_config(state.config) != comparable_config(config) ->
        {:reply, {:error, :mlx_lm_deployment_config_conflict}, state}

      true ->
        case verify_live(state) do
          :ok -> {:reply, {:ok, state.deployment}, state}
          {:error, reason} -> {:stop, reason, {:error, reason}, state}
        end
    end
  end

  def handle_call(:stop, _from, state) do
    case Imp.ExternalCommand.stop(state.handle, 10_000) do
      :ok ->
        :ok = cleanup_cache(state.cache_root)
        {:stop, :normal, :ok, %{state | handle: nil, cache_root: nil}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{monitor: ref} = state) do
    {:stop, {:mlx_lm_server_exited, reason}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state[:handle], do: _ = Imp.ExternalCommand.stop(state.handle, 10_000)
    _ = cleanup_cache(state[:cache_root])
    :ok
  end

  defp launch(config) do
    with :ok <- MLXLMArtifact.validate(config.artifact_path, config.inventory),
         {:ok, port} <- reserve_port(config.host, config.port),
         {:ok, cache_root} <- create_isolated_cache() do
      launch_server(config, port, cache_root)
    end
  end

  defp launch_server(config, port, cache_root) do
    case start_server(config, port, cache_root) do
      {:ok, handle} ->
        case await_exact_model(handle, config, port) do
          {:ok, base_url} ->
            lm = deployment_lm(config, base_url)

            deployment = %MLXLMDeployment{
              artifact_path: config.artifact_path,
              artifact_sha256: config.artifact_sha256,
              base_url: base_url,
              lm: lm,
              pid: self()
            }

            {:ok,
             %{
               config: Map.put(config, :port, port),
               deployment: deployment,
               handle: handle,
               monitor: Process.monitor(handle.owner),
               cache_root: cache_root
             }}

          {:error, reason} ->
            reason = stop_with_readiness_capture(handle, reason)
            :ok = cleanup_cache(cache_root)
            {:error, reason}
        end

      {:error, reason} ->
        :ok = cleanup_cache(cache_root)
        {:error, reason}
    end
  end

  defp start_server(config, port, cache_root) do
    argv =
      config.args ++
        [
          "--model",
          config.artifact_path,
          "--host",
          config.host,
          "--port",
          Integer.to_string(port),
          "--max-tokens",
          Integer.to_string(config.max_tokens)
        ]

    Imp.ExternalCommand.start(config.executable, argv,
      timeout: :infinity,
      kill_grace_ms: config.kill_grace_ms,
      max_output_bytes: config.max_output_bytes,
      env: isolated_cache_env(cache_root)
    )
  end

  defp create_isolated_cache do
    parent = Path.join(System.tmp_dir!(), "imp-mlx-deployments")
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    root = Path.join(parent, "deployment-#{suffix}")

    with :ok <- File.mkdir_p(parent),
         :ok <- File.mkdir(root),
         :ok <- create_cache_children(root) do
      {:ok, root}
    else
      {:error, reason} ->
        _ = File.rm_rf(root)
        {:error, {:mlx_lm_isolated_cache_creation_failed, reason}}
    end
  rescue
    error -> {:error, {:mlx_lm_isolated_cache_creation_failed, Exception.message(error)}}
  end

  defp create_cache_children(root) do
    Enum.reduce_while(~w(huggingface transformers datasets), :ok, fn child, :ok ->
      case File.mkdir(Path.join(root, child)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp isolated_cache_env(root) do
    huggingface = Path.join(root, "huggingface")

    [
      {"HF_HOME", huggingface},
      {"HF_HUB_CACHE", Path.join(huggingface, "hub")},
      {"HUGGINGFACE_HUB_CACHE", Path.join(huggingface, "hub")},
      {"TRANSFORMERS_CACHE", Path.join(root, "transformers")},
      {"HF_DATASETS_CACHE", Path.join(root, "datasets")},
      {"HF_HUB_OFFLINE", "1"},
      {"TRANSFORMERS_OFFLINE", "1"}
    ]
  end

  defp cleanup_cache(nil), do: :ok

  defp cleanup_cache(root) when is_binary(root) do
    parent = Path.join(System.tmp_dir!(), "imp-mlx-deployments")
    expanded = Path.expand(root)

    if Path.dirname(expanded) == Path.expand(parent) and
         String.starts_with?(Path.basename(expanded), "deployment-") do
      case File.rm_rf(expanded) do
        {:ok, _entries} -> :ok
        {:error, reason, path} -> {:error, {:mlx_lm_isolated_cache_cleanup_failed, path, reason}}
      end
    else
      {:error, {:mlx_lm_isolated_cache_cleanup_refused, root}}
    end
  end

  defp stop_with_readiness_capture(handle, {:mlx_lm_server_readiness_timeout, artifact_path}) do
    case Imp.ExternalCommand.stop_with_capture(handle, 10_000) do
      {:ok, capture} ->
        {:mlx_lm_server_readiness_timeout, %{artifact_path: artifact_path, process: capture}}

      {:error, stop_reason} ->
        {:mlx_lm_server_readiness_timeout,
         %{artifact_path: artifact_path, capture_error: stop_reason}}
    end
  end

  defp stop_with_readiness_capture(handle, reason) do
    _ = Imp.ExternalCommand.stop(handle, 10_000)
    reason
  end

  defp await_exact_model(handle, config, port) do
    base_url = "http://#{config.host}:#{port}/v1"
    deadline = System.monotonic_time(:millisecond) + config.startup_timeout
    await_models(handle, config.artifact_path, base_url, deadline)
  end

  defp await_models(handle, artifact_path, base_url, deadline) do
    cond do
      not Process.alive?(handle.owner) ->
        {:error, :mlx_lm_server_exited_before_readiness}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, {:mlx_lm_server_readiness_timeout, artifact_path}}

      true ->
        case Req.get(base_url <> "/models", receive_timeout: 1_000, retry: false) do
          {:ok, %{status: 200, body: %{"data" => data}}} when is_list(data) ->
            ids = Enum.map(data, & &1["id"])

            if ids == [artifact_path] do
              {:ok, base_url}
            else
              {:error, {:mlx_lm_server_model_identity_mismatch, artifact_path, ids}}
            end

          _response ->
            Process.sleep(50)
            await_models(handle, artifact_path, base_url, deadline)
        end
    end
  rescue
    _error ->
      Process.sleep(50)
      await_models(handle, artifact_path, base_url, deadline)
  end

  defp deployment_lm(config, base_url) do
    model = %{
      provider: :openai,
      id: config.artifact_path,
      model: config.artifact_path,
      base_url: base_url,
      extra: %{openai_compatible_backend: :mlx_lm}
    }

    defaults = [api_key: "local", cache: false, temperature: 0, max_tokens: 256, timeout: 120_000]

    ReqLLM.new(model,
      opts: Keyword.merge(defaults, config.lm_opts),
      req_module: config.req_module
    )
  end

  defp reserve_port(host, 0) do
    with {:ok, ip} <- parse_host(host),
         {:ok, socket} <-
           :gen_tcp.listen(0, [:binary, ip: ip, active: false, reuseaddr: true]),
         {:ok, {_ip, port}} <- :inet.sockname(socket),
         :ok <- :gen_tcp.close(socket) do
      {:ok, port}
    end
  end

  defp reserve_port(host, port) do
    with {:ok, ip} <- parse_host(host),
         {:ok, socket} <-
           :gen_tcp.listen(port, [:binary, ip: ip, active: false, reuseaddr: true]),
         :ok <- :gen_tcp.close(socket) do
      {:ok, port}
    else
      {:error, reason} -> {:error, {:mlx_lm_server_port_unavailable, host, port, reason}}
    end
  end

  defp parse_host("127.0.0.1"), do: {:ok, {127, 0, 0, 1}}
  defp parse_host("localhost"), do: {:ok, {127, 0, 0, 1}}
  defp parse_host("::1"), do: {:ok, {0, 0, 0, 0, 0, 0, 0, 1}}

  defp verify_live(state) do
    with true <- Process.alive?(state.handle.owner),
         :ok <- MLXLMArtifact.validate(state.config.artifact_path, state.config.inventory) do
      :ok
    else
      false -> {:error, :mlx_lm_server_not_running}
      {:error, _reason} = error -> error
    end
  end

  defp comparable_config(config) do
    Map.take(config, [
      :artifact_path,
      :artifact_sha256,
      :executable,
      :args,
      :host,
      :port,
      :max_tokens,
      :startup_timeout,
      :kill_grace_ms,
      :max_output_bytes,
      :lm_opts,
      :req_module
    ])
  end
end
