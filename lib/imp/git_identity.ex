defmodule Imp.GitIdentity do
  @moduledoc false

  @full_sha ~r/\A[0-9a-f]{40}\z/
  @sha_prefix ~r/\A[0-9a-f]{7,39}\z/

  @type verification :: %{
          approved: String.t(),
          canonical: String.t(),
          mode: :full | :unambiguous_prefix
        }

  @doc false
  @spec verify_head(Path.t(), String.t()) :: {:ok, verification()} | {:error, term()}
  def verify_head(repo, approved) when is_binary(repo) and is_binary(approved) do
    with {:ok, actual} <- git(repo, ["rev-parse", "--verify", "HEAD^{commit}"]) do
      verify(approved, actual, fn prefix ->
        git(repo, ["rev-parse", "--verify", "--end-of-options", prefix <> "^{commit}"])
      end)
    end
  end

  @doc false
  @spec verify(String.t(), String.t(), (String.t() -> {:ok, String.t()} | {:error, term()})) ::
          {:ok, verification()} | {:error, term()}
  def verify(approved, actual, resolve_prefix)
      when is_binary(approved) and is_binary(actual) and is_function(resolve_prefix, 1) do
    approved = String.downcase(approved)
    actual = String.downcase(actual)

    cond do
      not Regex.match?(@full_sha, actual) ->
        {:error, {:invalid_actual_git_identity, actual}}

      Regex.match?(@full_sha, approved) ->
        exact_identity(approved, actual, :full)

      Regex.match?(@sha_prefix, approved) ->
        with {:ok, resolved} <- resolve_prefix.(approved),
             resolved = String.downcase(resolved),
             true <- Regex.match?(@full_sha, resolved),
             true <- resolved == actual do
          {:ok, %{approved: approved, canonical: actual, mode: :unambiguous_prefix}}
        else
          {:error, reason} -> {:error, {:git_prefix_not_unambiguous, approved, reason}}
          false -> {:error, {:git_identity_mismatch, approved, actual}}
        end

      true ->
        {:error, {:invalid_approved_git_identity, approved}}
    end
  end

  def verify(approved, actual, _resolve_prefix),
    do: {:error, {:invalid_git_identity_arguments, approved, actual}}

  defp exact_identity(actual, actual, mode),
    do: {:ok, %{approved: actual, canonical: actual, mode: mode}}

  defp exact_identity(approved, actual, _mode),
    do: {:error, {:git_identity_mismatch, approved, actual}}

  defp git(repo, argv) do
    case System.cmd("git", argv, cd: repo, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:git_command_failed, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:git_command_failed, Exception.message(error)}}
  end
end
