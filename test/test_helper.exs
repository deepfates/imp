defmodule Imp.Test.EnvLoader do
  @moduledoc false

  def load(path \\ ".env") do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> Enum.each(&put_env/1)
    end

    :ok
  end

  defp put_env(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] when key != "" ->
        System.put_env(String.trim(key), clean(value))

      _ ->
        :ok
    end
  end

  defp clean(value) do
    value
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
  end
end

Imp.Test.EnvLoader.load()

external_excludes =
  [
    {"LIVE_PROVIDER", :live},
    # Maintainer-only evidence/reproduction-registry checks. They need full git
    # history, the pinned DSPy Python environments, and provider credentials.
    # Include them with EVIDENCE_INFRASTRUCTURE=1 mix test (or --include
    # evidence_infrastructure). See "Maintainer checks" in CONTRIBUTING.md.
    {"EVIDENCE_INFRASTRUCTURE", :evidence_infrastructure},
    # A second, independent gate WITHIN the evidence suite: tests that shell out
    # to the pinned DSPy 3.2.1 parity venv / source checkout under tmp/ (via
    # System.cmd or by reading tmp/dspy-3.2.1 source files). These are excluded
    # unless DSPY_CAPTURE=1, so a per-PR CI job can run EVIDENCE_INFRASTRUCTURE=1
    # WITHOUT DSPY_CAPTURE to exercise the venv-free structural/differential
    # validators, while the weekly capture job sets both. NB: this must NOT be
    # combined with `mix test --only evidence_infrastructure`, because an
    # `--only`/`--include` tag unconditionally overrides `exclude` — env-gating
    # here (removing the tag from the default exclude list) is what makes the
    # per-PR / capture split actually take effect.
    {"DSPY_CAPTURE", :requires_dspy_capture},
    # Machine-local corpus/index provisioning is not a clean-checkout product
    # invariant. Opt in only on a host that is preparing the HoVer campaign.
    {"GEPA_LOCAL_PROVISIONING", :local_provisioning},
    {"PROTOCOL_TRAINING", :protocol_training},
    {"PROTOCOL_RETRIEVER", :protocol_retriever},
    {"PROTOCOL_MCP", :protocol_mcp}
  ]
  |> Enum.reject(fn {env, _tag} -> System.get_env(env) in ["1", "true", "TRUE", "yes"] end)
  |> Enum.map(fn {_env, tag} -> {tag, true} end)

# The MuSiQue receipt-replay tests read the raw MuSiQue dataset (pinned
# checkout + data jsonl), distributed out-of-band; the old
# /tmp/musique-current-data-dir pointer convention was ephemeral and is now
# provisioned on no machine. This gate takes a PATH, not a "1" flag: set
# MUSIQUE_DATA_ROOT to the checkout to include them. The committed receipts
# stay validated by the other tests in that module.
external_excludes =
  case System.get_env("MUSIQUE_DATA_ROOT") do
    root when root in [nil, ""] -> [{:musique_data, true} | external_excludes]
    _root -> external_excludes
  end

ExUnit.configure(exclude: external_excludes)

Imp.Test.OwnLog.install()
ExUnit.start()
