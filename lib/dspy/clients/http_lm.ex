defmodule DSPy.Clients.HTTPLM do
  @moduledoc "OpenAI-compatible chat-completions client used by OpenAI, LiteLLM, local, and Databricks wrappers."

  @behaviour DSPy.LM

  defstruct [
    :model,
    :api_key,
    :base_url,
    provider: :openai,
    path: "/chat/completions",
    transport: DSPy.HTTP.Hackneyless,
    headers: [],
    opts: []
  ]

  @type t :: %__MODULE__{}

  def new(model, opts \\ []) do
    %__MODULE__{
      model: model,
      api_key: Keyword.get(opts, :api_key) || env_key(Keyword.get(opts, :provider, :openai)),
      base_url:
        Keyword.get(opts, :base_url, default_base_url(Keyword.get(opts, :provider, :openai))),
      provider: Keyword.get(opts, :provider, :openai),
      path: Keyword.get(opts, :path, "/chat/completions"),
      transport: Keyword.get(opts, :transport, DSPy.HTTP.Hackneyless),
      headers: Keyword.get(opts, :headers, []),
      opts: Keyword.get(opts, :opts, [])
    }
  end

  @impl true
  def generate(messages, opts),
    do: generate(new(Keyword.fetch!(opts, :model), opts), messages, opts)

  def generate(%__MODULE__{} = lm, messages, opts) do
    payload =
      lm.opts
      |> Keyword.merge(opts)
      |> Keyword.drop([:api_key, :base_url, :transport, :headers, :provider, :path])
      |> Map.new()
      |> Map.merge(%{model: lm.model, messages: Enum.map(messages, &encode_message/1)})

    body = Jason.encode!(payload)

    headers =
      [{"content-type", "application/json"}] ++
        auth_headers(lm) ++
        Enum.map(lm.headers, fn {k, v} -> {to_string(k), to_string(v)} end)

    with {:ok, %{status: status, body: response}} when status in 200..299 <-
           DSPy.HTTP.post(lm.transport, endpoint(lm), headers, body, []),
         {:ok, decoded} <- Jason.decode(response) do
      {:ok, extract_content(decoded)}
    else
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  def dump(%__MODULE__{} = lm) do
    %{provider: lm.provider, model: lm.model, base_url: lm.base_url, path: lm.path, opts: lm.opts}
  end

  defp endpoint(%__MODULE__{} = lm), do: String.trim_trailing(lm.base_url, "/") <> lm.path

  defp encode_message(%{role: role, content: content}),
    do: %{role: role_name(role), content: content}

  defp role_name(role) when is_atom(role), do: Atom.to_string(role)
  defp role_name(role), do: to_string(role)

  defp extract_content(%{"choices" => [%{"message" => %{"content" => content}} | _]}), do: content
  defp extract_content(%{"choices" => [%{"text" => text} | _]}), do: text
  defp extract_content(%{"output" => output}), do: output
  defp extract_content(other), do: other

  defp auth_headers(%__MODULE__{api_key: nil}), do: []
  defp auth_headers(%__MODULE__{api_key: key}), do: [{"authorization", "Bearer #{key}"}]

  defp default_base_url(:openai),
    do: System.get_env("OPENAI_BASE_URL") || "https://api.openai.com/v1"

  defp default_base_url(:litellm),
    do: System.get_env("LITELLM_BASE_URL") || "http://localhost:4000/v1"

  defp default_base_url(:local),
    do: System.get_env("LOCAL_LM_BASE_URL") || "http://localhost:8000/v1"

  defp default_base_url(:databricks),
    do:
      System.get_env("DATABRICKS_BASE_URL") ||
        "https://example.cloud.databricks.com/serving-endpoints"

  defp default_base_url(_provider), do: "http://localhost:8000/v1"

  defp env_key(:openai), do: System.get_env("OPENAI_API_KEY")
  defp env_key(:databricks), do: System.get_env("DATABRICKS_TOKEN")
  defp env_key(_provider), do: nil
end
