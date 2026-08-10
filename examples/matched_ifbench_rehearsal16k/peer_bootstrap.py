#!/usr/bin/env python3
"""Canonical peer command and environment ownership for shadow and live modes."""

from __future__ import annotations

import hashlib
import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping


SCHEMA_VERSION = 1
PROVIDER_CREDENTIAL_KEYS = (
    "OPENROUTER_API_KEY",
    "OPENAI_API_KEY",
    "ANTHROPIC_API_KEY",
)
MODE_SUBSTITUTION_KEYS = frozenset(
    {
        "OPENROUTER_API_KEY",
        "MATCHED_IFBENCH_R16K_API_BASE_URL",
        "MATCHED_IFBENCH_R16K_CATALOG_BASE_URL",
        "MATCHED_IFBENCH_R16K_HEALTH_URL",
        "MATCHED_IFBENCH_R16K_TLS_CA_CERT",
        "SSL_CERT_FILE",
    }
)


@dataclass(frozen=True)
class PeerMode:
    """The only mode-owned values: provider authority and endpoint transport."""

    provider_api_key: str
    api_base_url: str
    catalog_base_url: str
    health_url: str
    tls_ca_cert: str

    def substitutions(self) -> dict[str, str]:
        return {
            "OPENROUTER_API_KEY": self.provider_api_key,
            "MATCHED_IFBENCH_R16K_API_BASE_URL": self.api_base_url,
            "MATCHED_IFBENCH_R16K_CATALOG_BASE_URL": self.catalog_base_url,
            "MATCHED_IFBENCH_R16K_HEALTH_URL": self.health_url,
            "MATCHED_IFBENCH_R16K_TLS_CA_CERT": self.tls_ca_cert,
            "SSL_CERT_FILE": self.tls_ca_cert,
        }


def peer_commands(
    root: Path,
    here: Path,
    upstream_python: Path,
    dspy_root: Path,
    gepa_root: Path,
    gepa_artifact_root: Path,
    ifbench_site_packages: Path,
) -> dict[str, tuple[list[str], Path]]:
    """Return the one command/cwd definition used in every execution mode."""

    return {
        "imp": (["mix", "run", "run_imp.exs"], here),
        "upstream": (
            [
                str(upstream_python),
                str(here / "run_upstream.py"),
                "--dspy-root",
                str(dspy_root),
                "--gepa-root",
                str(gepa_root),
                "--gepa-artifact-root",
                str(gepa_artifact_root),
                "--ifbench-site-packages",
                str(ifbench_site_packages),
            ],
            root,
        ),
    }


def canonical_spec(
    root: Path,
    here: Path,
    launch_commit: str,
    commands: Mapping[str, tuple[list[str], Path]],
    tmp: Path,
    gepa_artifact_root: Path,
    ifbench_python: Path,
    ifbench_nltk_data: Path,
) -> dict[str, object]:
    """Materialize the nonsecret command/bootstrap contract shared by all modes."""

    common = {
        "ANTHROPIC_API_KEY": "",
        "IMP_GEPA_ARTIFACT_ROOT": str(gepa_artifact_root),
        "IMP_GEPA_PYTHON": str(ifbench_python),
        "IMP_IFBENCH_NLP_BRIDGE": str(root / "scripts" / "ifbench_nlp_check.py"),
        "IMP_IFBENCH_NLP_PYTHON": str(ifbench_python),
        "IMP_MATCHED_IFBENCH_R16K_OUTPUT": str(tmp / "imp-result.json"),
        "IMP_MATCHED_IFBENCH_R16K_UPSTREAM_SELECTION": str(
            tmp / "upstream-result.json.selection-sealed.json"
        ),
        "LITELLM_LOCAL_MODEL_COST_MAP": "True",
        "MATCHED_IFBENCH_R16K_EXPECTED_COMMIT": "$LAUNCH_COMMIT",
        "NLTK_DATA": str(ifbench_nltk_data),
        "OPENAI_API_KEY": "",
        "UPSTREAM_MATCHED_IFBENCH_R16K_IMP_SELECTION": str(
            tmp / "imp-result.json.selection-sealed.json"
        ),
        "UPSTREAM_MATCHED_IFBENCH_R16K_OUTPUT": str(tmp / "upstream-result.json"),
    }
    return {
        "schema_version": SCHEMA_VERSION,
        "commands": {
            runtime: {"argv": argv, "cwd": str(cwd)}
            for runtime, (argv, cwd) in sorted(commands.items())
        },
        "common_environment": common,
        "mode_substitutions": {
            "OPENROUTER_API_KEY": "provider_credential",
            "MATCHED_IFBENCH_R16K_API_BASE_URL": "endpoint_url",
            "MATCHED_IFBENCH_R16K_CATALOG_BASE_URL": "endpoint_url",
            "MATCHED_IFBENCH_R16K_HEALTH_URL": "endpoint_url",
            "MATCHED_IFBENCH_R16K_TLS_CA_CERT": "endpoint_trust",
            "SSL_CERT_FILE": "endpoint_trust",
        },
        "bootstrap_invariants": {
            "local_cost_map": True,
            "dotenv_provider_keys_blocked": list(PROVIDER_CREDENTIAL_KEYS[1:]),
            "provider_authority_owned_only_by_openrouter_substitution": True,
        },
    }


def canonical_digest(spec: Mapping[str, object]) -> str:
    materialized = canonical_json(spec).encode()
    return hashlib.sha256(materialized).hexdigest()


def canonical_json(spec: Mapping[str, object]) -> str:
    return json.dumps(spec, sort_keys=True, separators=(",", ":"))


def build_environment(
    inherited: Mapping[str, str],
    spec: Mapping[str, object],
    mode: PeerMode,
    launch_commit: str,
) -> dict[str, str]:
    """Apply the canonical fixed environment and one explicit mode substitution."""

    env = dict(inherited)
    for key in PROVIDER_CREDENTIAL_KEYS:
        env.pop(key, None)
    env.update(spec["common_environment"])  # type: ignore[arg-type]
    if len(launch_commit) != 40:
        raise RuntimeError("peer launch commit must be full-length")
    env["MATCHED_IFBENCH_R16K_EXPECTED_COMMIT"] = launch_commit
    substitutions = mode.substitutions()
    if set(substitutions) != MODE_SUBSTITUTION_KEYS:
        raise RuntimeError("peer mode substitution surface drift")
    env.update(substitutions)
    env["MATCHED_IFBENCH_R16K_BOOTSTRAP_SPEC"] = canonical_json(spec)
    env["MATCHED_IFBENCH_R16K_BOOTSTRAP_DIGEST"] = canonical_digest(spec)
    return env


def environment_differences(
    first: Mapping[str, str], second: Mapping[str, str]
) -> dict[str, tuple[str | None, str | None]]:
    return {
        key: (first.get(key), second.get(key))
        for key in sorted(set(first) | set(second))
        if first.get(key) != second.get(key)
    }


def require_mode_equivalence(
    shadow: Mapping[str, str], live: Mapping[str, str]
) -> dict[str, tuple[str | None, str | None]]:
    differences = environment_differences(shadow, live)
    if set(differences) != MODE_SUBSTITUTION_KEYS:
        raise RuntimeError(
            "shadow/live peer environment differs outside declared substitutions: "
            + ", ".join(sorted(set(differences) ^ MODE_SUBSTITUTION_KEYS))
        )
    for key in set(shadow) - MODE_SUBSTITUTION_KEYS:
        if shadow[key] != live.get(key):
            raise RuntimeError(f"fixed peer bootstrap value drift: {key}")
    return differences


def require_runtime_environment(
    environment: Mapping[str, str], expected_spec: Mapping[str, object]
) -> str:
    """Authenticate fixed bootstrap values before optional peer imports."""

    expected_digest = canonical_digest(expected_spec)
    if environment.get("MATCHED_IFBENCH_R16K_BOOTSTRAP_DIGEST") != expected_digest:
        raise RuntimeError("peer bootstrap digest mismatch")
    if environment.get("MATCHED_IFBENCH_R16K_BOOTSTRAP_SPEC") != canonical_json(
        expected_spec
    ):
        raise RuntimeError("peer canonical bootstrap specification mismatch")
    common = expected_spec["common_environment"]
    assert isinstance(common, dict)
    for key, value in common.items():
        if key == "MATCHED_IFBENCH_R16K_EXPECTED_COMMIT":
            actual = environment.get(key, "")
            if len(actual) != 40:
                raise RuntimeError("peer launch commit binding is absent")
            continue
        if environment.get(key) != value:
            raise RuntimeError(f"peer fixed bootstrap environment drift: {key}")
    if environment.get("LITELLM_LOCAL_MODEL_COST_MAP") != "True":
        raise RuntimeError("peer bootstrap may reach the remote LiteLLM cost map")
    if environment.get("OPENAI_API_KEY") != "" or environment.get("ANTHROPIC_API_KEY") != "":
        raise RuntimeError("ambient provider credentials escaped canonical bootstrap")
    return expected_digest


def live_mode(inherited: Mapping[str, str], system_ca: str) -> PeerMode:
    key = inherited.get("OPENROUTER_API_KEY", "")
    if key.strip() == "":
        raise RuntimeError("OPENROUTER_API_KEY is absent")
    return PeerMode(
        provider_api_key=key,
        api_base_url="https://openrouter.ai/api/v1",
        catalog_base_url="https://openrouter.ai/api/v1",
        health_url="https://openrouter.ai/api/v1/models",
        tls_ca_cert=system_ca,
    )


def shadow_mode(base_url: str, ca_cert: str) -> PeerMode:
    return PeerMode(
        provider_api_key="",
        api_base_url=base_url + "/v1",
        catalog_base_url=base_url + "/api/v1",
        health_url=base_url + "/health",
        tls_ca_cert=ca_cert,
    )
