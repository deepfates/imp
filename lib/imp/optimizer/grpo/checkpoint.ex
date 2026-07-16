defmodule Imp.Optimizer.GRPO.Checkpoint do
  @moduledoc false

  @type phase :: :dispatch_intent | :running | :terminating | :termination_failed

  def save!(path, phase, data) when is_binary(path) and is_atom(phase) and is_map(data) do
    payload = %{
      "type" => "imp_grpo_session_checkpoint",
      "schema_version" => 1,
      "phase" => Atom.to_string(phase),
      "data" => data |> Imp.Optimizer.Report.encode_term() |> Imp.Redaction.redact()
    }

    artifact = %{
      "payload" => payload,
      "payload_sha256" => checksum(payload)
    }

    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, Jason.encode!(artifact, pretty: true) <> "\n", [:sync])
      File.rename!(temporary, path)
      :ok
    after
      File.rm(temporary)
    end
  end

  def load!(path) when is_binary(path) do
    case path |> File.read!() |> Jason.decode!() do
      %{"payload" => payload, "payload_sha256" => digest} ->
        unless is_binary(digest) and :crypto.hash_equals(digest, checksum(payload)) do
          raise ArgumentError, "GRPO session checkpoint checksum mismatch"
        end

        case payload do
          %{
            "type" => "imp_grpo_session_checkpoint",
            "schema_version" => 1,
            "phase" => phase,
            "data" => data
          } ->
            %{phase: load_phase(phase), data: Imp.Optimizer.Report.decode_term(data)}

          _other ->
            raise ArgumentError, "invalid GRPO session checkpoint payload"
        end

      _other ->
        raise ArgumentError, "invalid GRPO session checkpoint artifact"
    end
  end

  def remove(path) when is_binary(path), do: File.rm(path)
  def remove(nil), do: :ok

  defp load_phase("dispatch_intent"), do: :dispatch_intent
  defp load_phase("running"), do: :running
  defp load_phase("terminating"), do: :terminating
  defp load_phase("termination_failed"), do: :termination_failed

  defp load_phase(phase),
    do: raise(ArgumentError, "invalid GRPO checkpoint phase #{inspect(phase)}")

  defp checksum(payload) do
    payload
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("sha256:" <> &1))
  end
end
