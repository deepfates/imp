#!/usr/bin/env python3
"""Pinned, local-only Imp↔TRL v1 worker.

The process has one framed-JSON control channel. It does not accept Python
module names, callbacks, shell commands, URLs, or arbitrary output paths.
Mutation is possible only through a sealed imp_trl_grpo_update envelope.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import pathlib
import shutil
import struct
import sys
import tempfile
from typing import Any


SCHEMA_VERSION = 1
ENGINE = {
    "name": "trl",
    "version": "1.6.0",
    "revision": "0dac440542c2ef9b575f56534f29f6fca1febe4a",
}


class WorkerError(Exception):
    def __init__(self, code: str, message: str, *, accepted: bool = False):
        super().__init__(message)
        self.code = code
        self.accepted = accepted


def canonical(value: Any) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, allow_nan=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def digest(value: Any) -> str:
    return "sha256:" + hashlib.sha256(canonical(value)).hexdigest()


def file_digest(path: pathlib.Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            hasher.update(chunk)
    return "sha256:" + hasher.hexdigest()


def envelope(kind: str, attrs: dict[str, Any]) -> dict[str, Any]:
    value = dict(attrs)
    value.update({"type": kind, "schema_version": SCHEMA_VERSION})
    value["payload_sha256"] = digest(value)
    return value


def validate_envelope(value: Any, kind: str) -> None:
    if not isinstance(value, dict):
        raise WorkerError("invalid_envelope", "protocol envelope must be an object")
    if value.get("type") != kind or value.get("schema_version") != SCHEMA_VERSION:
        raise WorkerError("invalid_envelope_header", f"expected {kind} schema v1")
    claimed = value.get("payload_sha256")
    actual = digest({k: v for k, v in value.items() if k != "payload_sha256"})
    if claimed != actual:
        raise WorkerError("envelope_digest_mismatch", "protocol payload digest mismatch")


def atomic_write(path: pathlib.Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def write_json(path: pathlib.Path, value: Any) -> None:
    atomic_write(path, json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2).encode() + b"\n")


def safe_tree_inventory(root: pathlib.Path) -> list[dict[str, Any]]:
    result = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise WorkerError("unsafe_symlink", f"symlink refused: {path}")
        if path.is_file():
            result.append(
                {
                    "path": path.relative_to(root).as_posix(),
                    "size": path.stat().st_size,
                    "sha256": file_digest(path),
                }
            )
        elif not path.is_dir():
            raise WorkerError("unsafe_artifact_entry", f"unsupported file type: {path}")
    return result


class Worker:
    def __init__(self, root: pathlib.Path, model_path: pathlib.Path, contract_path: pathlib.Path):
        self.root = root.resolve()
        self.model_path = model_path.resolve()
        self.contract_path = contract_path.resolve()
        self.contract = json.loads(self.contract_path.read_text())
        self._validate_contract()
        self.protocol: dict[str, Any] | None = None
        self.prepared: dict[str, Any] | None = None
        self.model = None
        self.tokenizer = None
        self.torch = None
        self.trainer = None
        self.step = 0
        self.receipt: dict[str, Any] | None = None
        self.checkpoint: dict[str, Any] | None = None
        self.artifact: dict[str, Any] | None = None
        self.accepted_batch_ids: list[str] = []
        self.deployed_artifact: dict[str, str] | None = None
        self.base_identity: dict[str, Any] | None = None
        self.root.mkdir(parents=True, exist_ok=True)

    @property
    def protocol_path(self) -> pathlib.Path:
        return self.root / "session.json"

    @property
    def intent_path(self) -> pathlib.Path:
        return self.root / f"accepted-intent-{self.step + 1}.json"

    @property
    def artifact_path(self) -> pathlib.Path:
        step = max(self.step, 1)
        return self.root / "artifacts" / f"step-{step}"

    def next_artifact_path(self) -> pathlib.Path:
        return self.root / "artifacts" / f"step-{self.step + 1}"

    def initialize(self) -> dict[str, Any]:
        self._verify_environment()
        model_identity = self._verify_model_tree()

        import peft
        import torch
        import transformers
        import trl
        from transformers import AutoModelForCausalLM, AutoTokenizer

        expected = self.contract["dependencies"]
        actual = {
            "trl": trl.__version__,
            "transformers": transformers.__version__,
            "peft": peft.__version__,
            "torch": torch.__version__.split("+", 1)[0],
        }
        if actual != expected:
            raise WorkerError("dependency_identity_mismatch", f"expected {expected}, got {actual}")
        if not torch.backends.mps.is_available():
            raise WorkerError("mps_unavailable", "PyTorch MPS is unavailable")
        if os.environ.get("PYTORCH_ENABLE_MPS_FALLBACK") != "0":
            raise WorkerError("cpu_fallback_not_disabled", "MPS CPU fallback must equal 0")

        tokenizer = AutoTokenizer.from_pretrained(
            str(self.model_path), local_files_only=True, trust_remote_code=False
        )
        model = AutoModelForCausalLM.from_pretrained(
            str(self.model_path),
            local_files_only=True,
            trust_remote_code=False,
            use_safetensors=True,
            torch_dtype=torch.float32,
        )
        model.to("mps")
        self._assert_model_device(model, "mps")
        if tokenizer.pad_token_id is None:
            tokenizer.pad_token = tokenizer.eos_token

        self.torch = torch
        self.model = model
        self.tokenizer = tokenizer
        tokenizer_identity = digest(
            [
                entry
                for entry in model_identity["inventory"]
                if entry["path"] in {"tokenizer.json", "tokenizer_config.json", "merges.txt", "vocab.json"}
            ]
        )
        self.base_identity = {
            "model": self.contract["model"]["repository"]
            + "@"
            + self.contract["model"]["revision"],
            "model_path": str(self.model_path),
            "base_model_sha256": model_identity["sha256"],
            "tokenizer_sha256": tokenizer_identity,
            "device": "mps",
            "dependencies": actual,
        }
        return dict(self.base_identity)

    def bind_session(self, protocol: dict[str, Any]) -> dict[str, Any]:
        validate_envelope(protocol, "imp_trl_grpo_session")
        if protocol.get("engine") != ENGINE:
            raise WorkerError("engine_identity_mismatch", "session engine is not pinned TRL")
        if self.model is None:
            raise WorkerError("worker_not_initialized", "initialize must precede session binding")
        runtime_kwargs = self.contract.get("imp_runtime", {}).get("train_kwargs", {})
        if protocol.get("optimizer", {}).get("config_sha256") != digest(runtime_kwargs):
            raise WorkerError(
                "optimizer_config_identity_mismatch",
                "session optimizer identity differs from the runtime contract",
            )
        steps = protocol.get("prompt_schedule", {}).get("steps", [])
        if len(steps) != self.contract["optimizer"]["max_steps"]:
            raise WorkerError(
                "unsupported_step_budget",
                "session schedule differs from the pinned optimizer step budget",
            )
        if self.protocol_path.exists():
            previous = json.loads(self.protocol_path.read_text())
            if previous.get("payload_sha256") != protocol.get("payload_sha256"):
                raise WorkerError("session_rebind_mismatch", "session already has different content")
        else:
            write_json(self.protocol_path, protocol)
        self.protocol = protocol
        return self._status()

    def reconcile(self) -> dict[str, Any]:
        if not self.protocol_path.is_file():
            raise WorkerError("session_not_found", "durable session does not exist")
        self.protocol = json.loads(self.protocol_path.read_text())
        validate_envelope(self.protocol, "imp_trl_grpo_session")
        self.initialize()
        self._load_durable_result()
        if self.step > 0:
            self._load_latest_adapter()
        result = self._status()
        result["protocol"] = self.protocol
        result["model"] = self.protocol["behavior_policy"]["model"]
        return result

    def prepare_update(self, request: dict[str, Any]) -> dict[str, Any]:
        if self.protocol is None or self.model is None or self.tokenizer is None:
            raise WorkerError("worker_not_bound", "initialized session is required")
        if self.step >= self.contract["optimizer"]["max_steps"]:
            raise WorkerError("update_budget_exhausted", "local TRL worker step budget is exhausted")
        groups = request.get("groups")
        if not isinstance(groups, list) or not groups:
            raise WorkerError(
                "group_count_mismatch",
                "the all-generated-groups batch must contain at least one prompt group",
            )

        encoded_groups = [self._encode_group(group, position) for position, group in enumerate(groups)]
        self._validate_group_sources(encoded_groups)
        self._persist_prepared_group(encoded_groups)
        self._validate_controlled_groups(encoded_groups)
        self._validate_acceptance_assertions(encoded_groups)

        optimizer_state, rng_state = self._current_training_state()
        attrs = {
            "session_id": self.protocol["session_id"],
            "session_payload_sha256": self.protocol["payload_sha256"],
            "step_id": request["step_id"],
            "idempotency_key": request["idempotency_key"],
            "trainer_step": self.step,
            "behavior_policy": self._current_behavior_policy(),
            "optimizer": optimizer_state,
            "rng": rng_state,
            "groups": encoded_groups,
        }
        self.prepared = attrs
        return attrs

    def generate(self, request: dict[str, Any]) -> dict[str, Any]:
        if self.model is None or self.tokenizer is None:
            raise WorkerError("worker_not_initialized", "initialized model is required")
        if self.protocol is None and self.deployed_artifact is None:
            raise WorkerError("worker_not_bound", "training session or deployed artifact is required")
        rollout_id = request.get("rollout_id")
        if not isinstance(rollout_id, int) or rollout_id < 0:
            raise WorkerError("invalid_rollout_id", "rollout_id must be a non-negative integer")
        generation_mode = request.get("generation_mode")
        if generation_mode not in ("sample", "greedy"):
            raise WorkerError(
                "invalid_generation_mode",
                "generation mode must be sample or greedy",
            )
        messages = self._messages(request.get("messages"))
        allowed_values = request.get("allowed_values")
        allowed_values_sha256 = request.get("allowed_values_sha256")
        if allowed_values is not None:
            if generation_mode != "greedy":
                raise WorkerError(
                    "sampled_allowed_values_unsupported",
                    "allowed-value generation is supported only for greedy deployment",
                )
            if (
                not isinstance(allowed_values, list)
                or not 1 <= len(allowed_values) <= 128
                or not all(isinstance(value, str) and 0 < len(value.encode()) <= 256 for value in allowed_values)
                or len(set(allowed_values)) != len(allowed_values)
            ):
                raise WorkerError("invalid_allowed_values", "allowed values are invalid")
            expected_choices = digest({"allowed_values": allowed_values})
            if allowed_values_sha256 != expected_choices:
                raise WorkerError("allowed_values_identity_mismatch", "allowed values digest changed")
        cfg = self.contract["optimizer"]
        seed = cfg["seed"] + rollout_id
        self.torch.manual_seed(seed)
        self.torch.mps.manual_seed(seed)
        prompt = self.tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True
        )
        inputs = self.tokenizer(prompt, add_special_tokens=False, return_tensors="pt").to("mps")
        with self.torch.no_grad():
            if allowed_values is None:
                generation_options = {
                    "do_sample": generation_mode == "sample",
                    "max_new_tokens": cfg["max_completion_length"],
                    "pad_token_id": self.tokenizer.pad_token_id,
                    "eos_token_id": self.tokenizer.eos_token_id,
                    "use_cache": True,
                }
                if generation_mode == "sample":
                    generation_options["temperature"] = cfg["temperature"]
                output = self.model.generate(**inputs, **generation_options)
                completion_ids = output[0, inputs["input_ids"].shape[1] :]
                completion = self.tokenizer.decode(completion_ids, skip_special_tokens=True)
            else:
                completion, completion_ids = self._select_allowed_value(
                    inputs["input_ids"], allowed_values
                )
        result = {
            "completion": completion,
            "completion_token_ids": completion_ids.detach().cpu().tolist(),
            "rollout_id": rollout_id,
            "seed": seed,
            "rollout_source": "model_generated",
            "generation_mode": generation_mode,
            "generation_constraint": "free_text" if allowed_values is None else "allowed_values",
        }
        if allowed_values is not None:
            result["allowed_values_sha256"] = allowed_values_sha256
        if self.deployed_artifact is not None:
            result.update(self.deployed_artifact)
        else:
            result["model"] = self.protocol["behavior_policy"]["model"]
        return result

    def _select_allowed_value(
        self,
        prompt_ids,
        allowed_values: list[str],
    ):
        scores = []
        token_sequences = []
        prompt_length = prompt_ids.shape[1]
        if prompt_length < 1:
            raise WorkerError("empty_choice_prompt", "choice generation requires a prompt token")

        for value in allowed_values:
            choice_ids = self.tokenizer(value, add_special_tokens=False)["input_ids"]
            if not choice_ids:
                raise WorkerError("empty_choice_tokens", "allowed value token sequence is empty")
            choice_tensor = self.torch.tensor([choice_ids], dtype=self.torch.long, device="mps")
            combined = self.torch.cat([prompt_ids, choice_tensor], dim=1)
            logits = self.model(input_ids=combined).logits
            logprobs = self.torch.log_softmax(logits, dim=-1)
            start = prompt_length - 1
            positions = logprobs[:, start : start + len(choice_ids), :]
            selected = positions.gather(2, choice_tensor.unsqueeze(-1)).squeeze(-1)
            scores.append(selected.sum())
            token_sequences.append(choice_ids)

        score_tensor = self.torch.stack(scores)
        choice_index = int(self.torch.argmax(score_tensor).item())

        selected_ids = self.torch.tensor(
            token_sequences[choice_index], dtype=self.torch.long, device="mps"
        )
        return allowed_values[choice_index], selected_ids

    def deploy_artifact(self, request: dict[str, Any]) -> dict[str, Any]:
        if self.model is None or self.tokenizer is None:
            raise WorkerError("worker_not_initialized", "initialize must precede artifact deployment")
        if self.protocol is not None or self.trainer is not None:
            raise WorkerError("training_worker_not_deployable", "training sessions cannot become deployments")

        raw_path = request.get("artifact_path")
        expected_sha256 = request.get("artifact_sha256")
        if not isinstance(raw_path, str) or not pathlib.Path(raw_path).is_absolute():
            raise WorkerError("invalid_deployment_artifact_path", "artifact path must be absolute")
        if not isinstance(expected_sha256, str) or not expected_sha256.startswith("sha256:"):
            raise WorkerError("invalid_deployment_artifact_identity", "artifact identity is required")

        artifact_path = pathlib.Path(raw_path).resolve()
        manifest_path = artifact_path / "imp-trl-artifact.json"
        if not artifact_path.is_dir() or not manifest_path.is_file():
            raise WorkerError("deployment_artifact_missing", "verified TRL artifact is missing")
        manifest = json.loads(manifest_path.read_text())
        validate_envelope(manifest, "imp_trl_grpo_artifact")
        if manifest["payload_sha256"] != expected_sha256:
            raise WorkerError("deployment_artifact_identity_mismatch", "artifact identity changed")
        expected_files = sorted(
            manifest["files"]
            + [{
                "path": "imp-trl-artifact.json",
                "size": manifest_path.stat().st_size,
                "sha256": file_digest(manifest_path),
            }],
            key=lambda entry: entry["path"],
        )
        actual_files = sorted(safe_tree_inventory(artifact_path), key=lambda entry: entry["path"])
        if actual_files != expected_files:
            raise WorkerError("deployment_artifact_inventory_mismatch", "artifact bytes changed")

        observation_path = artifact_path / "trl-observation.json"
        observation = json.loads(observation_path.read_text())
        expected_adapter_sha256 = observation.get("trainable_after_sha256")
        if not isinstance(expected_adapter_sha256, str):
            raise WorkerError("deployment_adapter_identity_missing", "trained adapter digest is missing")

        from peft import PeftModel

        self.model = PeftModel.from_pretrained(
            self.model,
            str(artifact_path / "adapter"),
            is_trainable=True,
        )
        self.model.to("mps")
        self.model.eval()
        self._assert_model_device(self.model, "mps")
        adapter_sha256 = self._trainable_digest(self.model)
        if adapter_sha256 != expected_adapter_sha256:
            raise WorkerError("deployment_adapter_identity_mismatch", "loaded LoRA tensors differ")

        self.deployed_artifact = {
            "model": str(artifact_path),
            "artifact_sha256": expected_sha256,
            "adapter_sha256": adapter_sha256,
        }
        return dict(self.deployed_artifact)

    def deploy_base(self, request: dict[str, Any]) -> dict[str, Any]:
        if self.model is None or self.tokenizer is None or self.base_identity is None:
            raise WorkerError("worker_not_initialized", "initialize must precede base deployment")
        if self.protocol is not None or self.trainer is not None or self.deployed_artifact is not None:
            raise WorkerError("worker_not_deployable", "worker already owns another lifecycle")
        if request.get("model") != self.base_identity["model"]:
            raise WorkerError("base_deployment_model_mismatch", "base model identity changed")
        if request.get("artifact_sha256") != self.base_identity["base_model_sha256"]:
            raise WorkerError("base_deployment_artifact_mismatch", "base artifact identity changed")
        self.deployed_artifact = {
            "model": self.base_identity["model"],
            "artifact_sha256": self.base_identity["base_model_sha256"],
            "adapter_sha256": None,
        }
        self.model.eval()
        return dict(self.deployed_artifact)

    def controlled_completion(self, request: dict[str, Any]) -> dict[str, Any]:
        if self.protocol is None or self.model is None or self.tokenizer is None:
            raise WorkerError("worker_not_bound", "initialized session is required")
        rollout_id = request.get("rollout_id")
        controlled = self.contract.get("controlled_rollouts")
        if not isinstance(rollout_id, int) or not isinstance(controlled, list):
            raise WorkerError("controlled_rollout_unavailable", "controlled rollout contract is absent")
        if rollout_id < 0 or rollout_id >= len(controlled):
            raise WorkerError("controlled_rollout_order_mismatch", "controlled rollout id is out of order")
        self._messages(request.get("messages"))
        completion = controlled[rollout_id]
        if not isinstance(completion, str) or not completion:
            raise WorkerError("invalid_controlled_completion", "controlled completion must be non-empty text")
        return {
            "completion": completion,
            "rollout_id": rollout_id,
            "model": self.protocol["behavior_policy"]["model"],
            "rollout_source": "controlled_external",
        }

    def apply_update(self, update: dict[str, Any]) -> dict[str, Any]:
        validate_envelope(update, "imp_trl_grpo_update")
        if self.protocol is None or self.model is None:
            raise WorkerError("worker_not_bound", "initialized session is required")
        if update["session_id"] != self.protocol["session_id"]:
            raise WorkerError("session_identity_mismatch", "update session mismatch")
        if update["session_payload_sha256"] != self.protocol["payload_sha256"]:
            raise WorkerError("session_payload_mismatch", "update session digest mismatch")
        if self.prepared is None:
            raise WorkerError("update_not_prepared", "sealed update has no local preparation")
        expected = dict(self.prepared)
        for key in ("type", "schema_version", "payload_sha256"):
            expected.pop(key, None)
        actual = {
            key: value
            for key, value in update.items()
            if key not in {"type", "schema_version", "payload_sha256"}
        }
        if canonical(expected) != canonical(actual):
            raise WorkerError("prepared_update_mismatch", "sealed update differs from prepared values")

        if self.receipt is not None and self.receipt["trainer_step"] == update["trainer_step"] + 1:
            if self.receipt["accepted_update_sha256"] == update["payload_sha256"]:
                return self._mutation_result()
            raise WorkerError("replay_payload_mismatch", "idempotency key already has different content")
        if self.intent_path.exists():
            previous = json.loads(self.intent_path.read_text())
            if previous.get("payload_sha256") != update["payload_sha256"]:
                raise WorkerError("replay_payload_mismatch", "sealed intent has different content")
            raise WorkerError(
                "ambiguous_prior_acceptance",
                "sealed update exists without a durable receipt; replay refused",
                accepted=True,
            )

        # Acceptance boundary: sync exact intent before model mutation.
        write_json(self.intent_path, update)
        return self._train_once(update)

    def terminate(self) -> dict[str, Any]:
        if self.step != self.contract["optimizer"]["max_steps"] or self.artifact is None:
            raise WorkerError("incomplete_training", "the pinned optimizer step budget did not complete")
        result = self._status()
        result["status"] = "succeeded"
        return result

    def _train_once(self, update: dict[str, Any]) -> dict[str, Any]:
        torch = self.torch
        assert torch is not None and self.model is not None and self.tokenizer is not None
        from datasets import Dataset
        from peft import LoraConfig, TaskType
        from transformers import TrainerCallback
        from trl import GRPOConfig, GRPOTrainer

        groups = update["groups"]
        samples = [sample for group in groups for sample in group["samples"]]
        frozen_prompts = [group["prompt"] for group in groups for _ in group["samples"]]

        def rollout_func(prompts, _trainer):
            if canonical(prompts) != canonical(frozen_prompts):
                raise RuntimeError("TRL prompt order differs from sealed update")
            return {
                "prompt_ids": [sample["prompt_token_ids"] for sample in samples],
                "completion_ids": [sample["completion_token_ids"] for sample in samples],
                "logprobs": [sample["behavior_logprobs"] for sample in samples],
                "external_rewards": [sample["reward"] for sample in samples],
            }

        def external_reward(completions, external_rewards, **_kwargs):
            if len(completions) != len(external_rewards):
                raise RuntimeError("TRL reward order mismatch")
            return external_rewards

        class ObservedGRPOTrainer(GRPOTrainer):
            imp_advantages = None

            def _generate_and_score_completions(self, inputs):
                result = super()._generate_and_score_completions(inputs)
                self.imp_advantages = result["advantages"].detach().cpu().tolist()
                return result

        target_step = self.step + 1

        class StopAfterAcceptedStep(TrainerCallback):
            def on_step_end(self, _args, state, control, **_kwargs):
                if state.global_step >= target_step:
                    control.should_training_stop = True
                return control

        class RestoreMPSRNG(TrainerCallback):
            def on_train_begin(callback_self, _args, _state, control, **_kwargs):
                if self.step > 0:
                    rng_path = self.artifact_path / "mps-rng.pt"
                    state = torch.load(rng_path, map_location="cpu", weights_only=True)
                    torch.mps.set_rng_state(state)
                return control

        cfg = self.contract["optimizer"]
        output = self.root / "trainer-output"
        args = GRPOConfig(
            output_dir=str(output),
            max_steps=self.contract["optimizer"]["max_steps"],
            per_device_train_batch_size=len(groups) * cfg["num_generations"],
            gradient_accumulation_steps=1,
            generation_batch_size=len(groups) * cfg["num_generations"],
            num_generations=cfg["num_generations"],
            max_completion_length=cfg["max_completion_length"],
            temperature=cfg["temperature"],
            learning_rate=cfg["learning_rate"],
            loss_type=cfg["loss_type"],
            scale_rewards=cfg["scale_rewards"],
            beta=cfg["beta"],
            use_vllm=False,
            fp16=False,
            bf16=False,
            seed=cfg["seed"],
            data_seed=cfg["seed"],
            shuffle_dataset=False,
            save_strategy="steps",
            save_steps=1,
            save_total_limit=None,
            logging_strategy="steps",
            logging_steps=1,
            report_to=[],
            disable_tqdm=True,
            remove_unused_columns=False,
        )
        lora = cfg["lora"]
        peft_config = None
        if self.step == 0:
            peft_config = LoraConfig(
                task_type=TaskType.CAUSAL_LM,
                r=lora["rank"],
                lora_alpha=lora["alpha"],
                lora_dropout=lora["dropout"],
                target_modules=lora["target_modules"],
                bias="none",
            )
        trainer = ObservedGRPOTrainer(
            model=self.model,
            args=args,
            reward_funcs=external_reward,
            train_dataset=Dataset.from_list([{"prompt": group["prompt"]} for group in groups]),
            processing_class=self.tokenizer,
            peft_config=peft_config,
            rollout_func=rollout_func,
            callbacks=[StopAfterAcceptedStep(), RestoreMPSRNG()],
        )
        self.trainer = trainer
        self.model = trainer.model
        self._assert_trainable_device(self.model, "mps")
        before_digest = self._trainable_digest(self.model)
        resume_checkpoint = str(self.artifact_path / "trainer-checkpoint") if self.step > 0 else None
        train_result = trainer.train(resume_from_checkpoint=resume_checkpoint)
        self._assert_trainable_device(self.model, "mps")
        after_digest = self._trainable_digest(self.model)
        if trainer.state.global_step != target_step:
            raise WorkerError(
                "optimizer_step_mismatch",
                f"expected step {target_step}, got {trainer.state.global_step}",
                accepted=True,
            )
        acceptance = self._acceptance()
        if acceptance["require_weight_change"] and before_digest == after_digest:
            raise WorkerError("trainable_tensor_unchanged", "LoRA tensors did not change", accepted=True)
        advantages = trainer.imp_advantages
        if not isinstance(advantages, list) or len(advantages) != len(samples):
            raise WorkerError("advantages_missing", "TRL did not expose the grouped advantages", accepted=True)
        grouped_advantages = []
        offset = 0
        for group in groups:
            count = len(group["samples"])
            values = advantages[offset : offset + count]
            grouped_advantages.append(values)
            offset += count
            if acceptance["require_non_uniform_advantages"] and len(
                {round(float(value), 8) for value in values}
            ) < 2:
                raise WorkerError(
                    "advantages_uniform",
                    "TRL relative advantages are uniform within a prompt group",
                    accepted=True,
                )

        staging = self.root / f".artifact-step-{target_step}.tmp"
        if staging.exists():
            raise WorkerError("artifact_staging_exists", "prior partial artifact requires inspection", accepted=True)
        staging.mkdir()
        adapter_dir = staging / "adapter"
        trainer.save_model(str(adapter_dir))
        trainer.save_state()
        checkpoint_source = output / f"checkpoint-{target_step}"
        if not checkpoint_source.is_dir():
            raise WorkerError(
                "trainer_checkpoint_missing",
                f"official Trainer checkpoint-{target_step} is missing",
                accepted=True,
            )
        shutil.copytree(checkpoint_source, staging / "trainer-checkpoint")
        trainer_state_source = output / "trainer_state.json"
        if trainer_state_source.is_file():
            atomic_write(staging / "trainer-state.json", trainer_state_source.read_bytes())
        torch.save(trainer.optimizer.state_dict(), staging / "optimizer.pt")
        torch.save(torch.mps.get_rng_state(), staging / "mps-rng.pt")
        self._copy_prior_envelopes(staging, target_step)
        rng_record = {
            "torch_cpu_sha256": "sha256:" + hashlib.sha256(torch.get_rng_state().numpy().tobytes()).hexdigest(),
            "torch_mps_sha256": self._mps_rng_digest(torch),
            "seed": cfg["seed"],
        }
        write_json(staging / "rng-state.json", rng_record)
        write_json(staging / f"update-{target_step}.json", update)

        optimizer_after = {
            "global_step": target_step,
            "state_sha256": file_digest(staging / "optimizer.pt"),
        }
        rng_after = {
            "algorithm": self.protocol["rng"]["algorithm"],
            "state_sha256": digest(rng_record),
        }
        checkpoint = envelope(
            "imp_trl_grpo_checkpoint",
            {
                "session_id": self.protocol["session_id"],
                "trainer_step": target_step,
                "accepted_update_sha256s": self._accepted_update_sha256s() + [update["payload_sha256"]],
                "artifact_sha256": after_digest,
                "optimizer": optimizer_after,
                "rng": rng_after,
            },
        )
        write_json(staging / "trainer-checkpoint.json", checkpoint)
        receipt = envelope(
            "imp_trl_grpo_receipt",
            {
                "session_id": self.protocol["session_id"],
                "idempotency_key": update["idempotency_key"],
                "accepted_update_sha256": update["payload_sha256"],
                "trainer_step": target_step,
                "artifact": {
                    "before_sha256": update["behavior_policy"]["artifact_sha256"],
                    "after_sha256": after_digest,
                },
                "optimizer": {
                    "before_sha256": update["optimizer"]["state_sha256"],
                    "after_sha256": optimizer_after["state_sha256"],
                },
                "rng": {
                    "before_sha256": update["rng"]["state_sha256"],
                    "after_sha256": rng_after["state_sha256"],
                },
                "checkpoint": {
                    "path": "trainer-checkpoint.json",
                    "payload_sha256": checkpoint["payload_sha256"],
                },
            },
        )
        write_json(staging / f"receipt-{target_step}.json", receipt)
        write_json(
            staging / "trl-observation.json",
            {
                "advantages": advantages,
                "group_advantages": grouped_advantages,
                "rewards": [sample["reward"] for sample in samples],
                "group_rewards": [
                    [sample["reward"] for sample in group["samples"]] for group in groups
                ],
                "trainable_before_sha256": before_digest,
                "trainable_after_sha256": after_digest,
                "global_step_before": self.step,
                "global_step_after": trainer.state.global_step,
                "training_loss": float(train_result.training_loss),
                "trainable_tensors_changed": before_digest != after_digest,
                "device": "mps",
            },
        )

        files = safe_tree_inventory(staging)
        artifact = envelope(
            "imp_trl_grpo_artifact",
            {
                "session_id": self.protocol["session_id"],
                "base_model": self.protocol["behavior_policy"]["model"],
                "base_model_sha256": self.protocol["behavior_policy"]["artifact_sha256"],
                "trainer_step": target_step,
                "checkpoint_sha256": checkpoint["payload_sha256"],
                "receipt_sha256s": self._receipt_sha256s() + [receipt["payload_sha256"]],
                "files": files,
            },
        )
        write_json(staging / "imp-trl-artifact.json", artifact)
        target = self.next_artifact_path()
        target.parent.mkdir(parents=True, exist_ok=True)
        os.replace(staging, target)
        directory = os.open(self.root, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)

        self.step = target_step
        self.accepted_batch_ids += [group["batch_id"] for group in groups]
        self.receipt = receipt
        self.checkpoint = checkpoint
        self.artifact = artifact
        return self._mutation_result()

    def _encode_group(self, group: dict[str, Any], group_position: int) -> dict[str, Any]:
        samples = group.get("group")
        if not isinstance(samples, list) or len(samples) != self.contract["optimizer"]["num_generations"]:
            raise WorkerError("generation_count_mismatch", "group sample count differs from frozen contract")
        messages = self._messages(samples[0]["messages"])
        prompt_sha = digest({"messages": messages})
        prompt_text = self.tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True
        )
        prompt_ids = self.tokenizer(prompt_text, add_special_tokens=False)["input_ids"]
        encoded_samples = []
        for position, sample in enumerate(samples):
            sample_messages = self._messages(sample["messages"])
            if digest({"messages": sample_messages}) != prompt_sha:
                raise WorkerError("prompt_identity_mismatch", "group contains multiple prompts")
            completion = sample["completion"]["content"]
            completion_ids = self.tokenizer(completion, add_special_tokens=False)["input_ids"]
            if not completion_ids:
                raise WorkerError("empty_completion_tokens", "completion token sequence is empty")
            reward = float(sample["reward"])
            if not math.isfinite(reward):
                raise WorkerError("non_finite_reward", "reward must be finite")
            encoded_samples.append(
                {
                    "position": position,
                    "prompt_sha256": prompt_sha,
                    "prompt_token_ids": prompt_ids,
                    "prompt_mask": [1] * len(prompt_ids),
                    "completion": completion,
                    "completion_sha256": digest({"completion": completion}),
                    "completion_token_ids": completion_ids,
                    "completion_mask": [1] * len(completion_ids),
                    "behavior_logprobs": self._completion_logprobs(prompt_ids, completion_ids),
                    "reward": reward,
                }
            )
        return {
            "batch_id": str(group["batch_id"]),
            "group_id": repr(group["group_id"]),
            "group_position": group_position,
            "predictor": str(group["predictor"]),
            "selection_step": group.get("selection_step"),
            "source_position": group.get("source_position"),
            "source_row_sha256": group.get("source_row_sha256"),
            "prompt": messages,
            "prompt_sha256": prompt_sha,
            "samples": encoded_samples,
        }

    def _validate_group_sources(self, encoded_groups: list[dict[str, Any]]) -> None:
        assert self.protocol is not None
        schedule = self.protocol["prompt_schedule"]["steps"]

        for group in encoded_groups:
            selection_step = group.get("selection_step")
            source_position = group.get("source_position")
            source_sha256 = group.get("source_row_sha256")
            if not isinstance(selection_step, int) or selection_step < 0:
                raise WorkerError(
                    "group_source_identity_missing",
                    "selection step must bind every group to its source schedule",
                )
            if selection_step != self.step:
                raise WorkerError(
                    "group_selection_step_mismatch",
                    "group belongs to a different optimizer step",
                )
            if selection_step >= len(schedule):
                raise WorkerError(
                    "group_selection_step_mismatch",
                    "group selection step is outside the durable schedule",
                )
            ordered = schedule[selection_step]["ordered_row_sha256s"]
            if not isinstance(source_position, int) or source_position < 0 or source_position >= len(ordered):
                raise WorkerError(
                    "group_source_position_mismatch",
                    "group source position is outside its selected row schedule",
                )
            if source_sha256 != ordered[source_position]:
                raise WorkerError(
                    "group_source_identity_mismatch",
                    "group source row differs from the durable selected row schedule",
                )

    def _persist_prepared_group(self, encoded_groups: list[dict[str, Any]]) -> None:
        write_json(
            self.root / "prepared-controlled-group.json",
            {
                "rollout_source": "controlled_external"
                if self.contract.get("controlled_rollouts") is not None
                else "model_generated",
                "groups": encoded_groups,
            },
        )

    def _validate_controlled_groups(self, encoded_groups: list[dict[str, Any]]) -> None:
        controlled = self.contract.get("controlled_rollouts")
        if controlled is None:
            return
        if len(encoded_groups) != 1:
            raise WorkerError(
                "controlled_rollout_group_count_mismatch",
                "controlled external-rollout contracts support exactly one prompt group",
            )
        samples = encoded_groups[0]["samples"]
        if not isinstance(controlled, list) or len(controlled) != len(samples):
            raise WorkerError("controlled_rollout_count_mismatch", "controlled rollout count differs from samples")
        for position, sample in enumerate(samples):
            source = controlled[position]
            rendered = f"[[ ## route ## ]]\n{source}\n\n[[ ## completed ## ]]\n"
            if sample["completion"] not in (source, rendered):
                raise WorkerError(
                    "controlled_rollout_order_mismatch",
                    "controlled completion differs from its canonical adapter rendering",
                )

    def _acceptance(self) -> dict[str, bool]:
        # Older retained feasibility contracts predate the explicit acceptance
        # object. Their semantic_group was an experiment assertion, so preserve
        # its strict behavior without imposing it on ordinary trainer contracts.
        legacy_strict = "semantic_group" in self.contract
        configured = self.contract.get("acceptance", {})
        return {
            "require_non_uniform_rewards": configured.get(
                "require_non_uniform_rewards", legacy_strict
            ),
            "require_non_uniform_advantages": configured.get(
                "require_non_uniform_advantages", legacy_strict
            ),
            "require_weight_change": configured.get("require_weight_change", legacy_strict),
        }

    def _validate_acceptance_assertions(self, encoded_groups: list[dict[str, Any]]) -> None:
        semantic = self.contract.get("semantic_group")
        if semantic is not None:
            prompt_text = "\n".join(
                message["content"] for message in encoded_groups[0]["prompt"]
            )
            if semantic["utterance"] not in prompt_text:
                raise WorkerError("semantic_prompt_mismatch", "frozen semantic utterance is absent")
            if not all(value in prompt_text for value in semantic["allowed_routes"]):
                raise WorkerError("route_contract_mismatch", "frozen semantic labels are absent")
            rewards = [sample["reward"] for sample in encoded_groups[0]["samples"]]
            if any(reward not in (0.0, 1.0) for reward in rewards):
                raise WorkerError("reward_contract_mismatch", "frozen semantic rewards must be binary")

        for group in encoded_groups:
            rewards = [sample["reward"] for sample in group["samples"]]
            if self._acceptance()["require_non_uniform_rewards"] and len(set(rewards)) < 2:
                raise WorkerError(
                    "uniform_rewards",
                    "non-uniform external rewards are required within each prompt group",
                )

    def _validate_contract(self) -> None:
        allowed = {
            "schema_version", "purpose", "python", "dependencies", "model", "device",
            "optimizer", "semantic_group", "controlled_rollouts", "acceptance", "imp_runtime",
        }
        unknown = set(self.contract) - allowed
        if unknown:
            raise WorkerError("unknown_contract_keys", f"unsupported contract keys: {sorted(unknown)}")
        if self.contract.get("schema_version") != 1:
            raise WorkerError("contract_schema_mismatch", "worker requires contract schema v1")
        if self.contract.get("python") != "3.12":
            raise WorkerError("contract_python_mismatch", "worker requires CPython 3.12")
        for key in ("dependencies", "model", "device", "optimizer"):
            if not isinstance(self.contract.get(key), dict):
                raise WorkerError("invalid_contract", f"contract {key} must be an object")
        optimizer = self.contract["optimizer"]
        required_optimizer = {
            "seed", "num_generations", "max_steps", "max_completion_length", "temperature",
            "learning_rate", "loss_type", "scale_rewards", "beta", "lora",
        }
        if set(optimizer) != required_optimizer:
            raise WorkerError("invalid_optimizer_contract", "optimizer contract keys do not match")
        if not isinstance(optimizer["max_steps"], int) or optimizer["max_steps"] < 1:
            raise WorkerError(
                "invalid_optimizer_contract",
                "max_steps must be a positive durable optimizer budget",
            )
        if not isinstance(optimizer["num_generations"], int) or optimizer["num_generations"] < 2:
            raise WorkerError("invalid_optimizer_contract", "num_generations must be at least two")
        acceptance = self.contract.get("acceptance", {})
        allowed_acceptance = {
            "require_non_uniform_rewards", "require_non_uniform_advantages", "require_weight_change"
        }
        if not isinstance(acceptance, dict) or set(acceptance) - allowed_acceptance:
            raise WorkerError("invalid_acceptance_contract", "acceptance assertions are invalid")
        if any(not isinstance(value, bool) for value in acceptance.values()):
            raise WorkerError("invalid_acceptance_contract", "acceptance assertions must be booleans")
        runtime = self.contract.get("imp_runtime", {"train_kwargs": {}})
        if not isinstance(runtime, dict) or set(runtime) != {"train_kwargs"}:
            raise WorkerError("invalid_runtime_contract", "runtime contract keys do not match")
        train_kwargs = runtime["train_kwargs"]
        if not isinstance(train_kwargs, dict) or set(train_kwargs) - {
            "learning_rate", "beta", "loss_type", "scale_rewards"
        }:
            raise WorkerError("invalid_runtime_contract", "runtime train kwargs are not allowlisted")
        for key, value in train_kwargs.items():
            if optimizer.get(key) != value:
                raise WorkerError("runtime_contract_mismatch", f"runtime override {key} was not applied")
        learning_rate = train_kwargs.get("learning_rate")
        if learning_rate is not None and (
            isinstance(learning_rate, bool)
            or not isinstance(learning_rate, (int, float))
            or not math.isfinite(learning_rate)
            or not 0 < learning_rate < 1
        ):
            raise WorkerError("invalid_runtime_contract", "learning_rate must be finite in (0, 1)")
        beta = train_kwargs.get("beta")
        if beta is not None and (
            isinstance(beta, bool)
            or not isinstance(beta, (int, float))
            or not math.isfinite(beta)
            or beta < 0
        ):
            raise WorkerError("invalid_runtime_contract", "beta must be finite and non-negative")
        if train_kwargs.get("loss_type", "grpo") not in {"grpo", "dr_grpo", "dapo", "bnpo"}:
            raise WorkerError("invalid_runtime_contract", "loss_type is not allowlisted")
        if train_kwargs.get("scale_rewards", "group") not in {
            "group", "batch", "none", True, False
        }:
            raise WorkerError("invalid_runtime_contract", "scale_rewards is not allowlisted")

    def _completion_logprobs(self, prompt_ids: list[int], completion_ids: list[int]) -> list[float]:
        torch = self.torch
        ids = torch.tensor([prompt_ids + completion_ids], dtype=torch.long, device="mps")
        with torch.no_grad():
            logits = self.model(input_ids=ids).logits[:, :-1, :]
            logprobs = torch.log_softmax(logits, dim=-1)
        start = len(prompt_ids) - 1
        selected = logprobs[0, start : start + len(completion_ids), :]
        targets = ids[0, len(prompt_ids) :]
        values = selected.gather(1, targets.unsqueeze(1)).squeeze(1)
        return [float(value) for value in values.detach().cpu().tolist()]

    def _status(self) -> dict[str, Any]:
        total = len(self.protocol["prompt_schedule"]["steps"]) if self.protocol else 0
        pending = self._pending_batch_ids() if self.step < total else []
        result = {
            "status": "running" if self.step < total else "succeeded",
            "pending_batch_ids": pending,
            "fulfilled_batch_ids": self.accepted_batch_ids,
            "current_model": str(self.artifact_path) if self.step else (
                self.protocol["behavior_policy"]["model"] if self.protocol else None
            ),
            "result_model": str(self.artifact_path) if self.step else None,
            "metadata": {"batch_assignment": "all_generated_groups"},
        }
        if self.artifact:
            result["metadata"].update({
                "artifact_sha256": self.artifact["payload_sha256"],
                "checkpoint_sha256": self.checkpoint["payload_sha256"],
                "protocol_payload_sha256": self.protocol["payload_sha256"],
            })
        return result

    def _mutation_result(self) -> dict[str, Any]:
        result = self._status()
        result.update(
            {"receipt": self.receipt, "checkpoint": self.checkpoint, "artifact": self.artifact}
        )
        return result

    def _load_durable_result(self) -> None:
        artifacts_root = self.root / "artifacts"
        steps = []
        if artifacts_root.is_dir():
            for path in artifacts_root.iterdir():
                if path.is_dir() and path.name.startswith("step-"):
                    try:
                        steps.append(int(path.name.removeprefix("step-")))
                    except ValueError:
                        raise WorkerError("artifact_step_identity_invalid", "invalid step directory")

        if not steps:
            if self.intent_path.exists():
                raise WorkerError(
                    "ambiguous_prior_acceptance",
                    "sealed intent exists without final artifact",
                    accepted=True,
                )
            self.step = 0
            return
        expected_steps = list(range(1, max(steps) + 1))
        if sorted(steps) != expected_steps:
            raise WorkerError("artifact_step_chain_incomplete", "durable step sequence has a gap")

        accepted_batch_ids = []
        prior_receipts = []
        for step in expected_steps:
            path = artifacts_root / f"step-{step}"
            manifest = json.loads((path / "imp-trl-artifact.json").read_text())
            checkpoint = json.loads((path / "trainer-checkpoint.json").read_text())
            receipt = json.loads((path / f"receipt-{step}.json").read_text())
            update = json.loads((path / f"update-{step}.json").read_text())
            validate_envelope(manifest, "imp_trl_grpo_artifact")
            validate_envelope(checkpoint, "imp_trl_grpo_checkpoint")
            validate_envelope(receipt, "imp_trl_grpo_receipt")
            validate_envelope(update, "imp_trl_grpo_update")
            self._verify_artifact_inventory(path, manifest)
            observation = json.loads((path / "trl-observation.json").read_text())
            rng_record = json.loads((path / "rng-state.json").read_text())
            if checkpoint["artifact_sha256"] != observation["trainable_after_sha256"]:
                raise WorkerError("checkpoint_tensor_identity_mismatch", "checkpoint tensor digest differs")
            if checkpoint["optimizer"]["state_sha256"] != file_digest(path / "optimizer.pt"):
                raise WorkerError("checkpoint_optimizer_identity_mismatch", "optimizer bytes differ")
            if checkpoint["rng"]["state_sha256"] != digest(rng_record):
                raise WorkerError("checkpoint_rng_identity_mismatch", "trainer RNG record differs")
            if receipt["accepted_update_sha256"] != update["payload_sha256"]:
                raise WorkerError("receipt_update_identity_mismatch", "receipt update digest differs")
            if receipt["checkpoint"]["payload_sha256"] != checkpoint["payload_sha256"]:
                raise WorkerError("receipt_checkpoint_identity_mismatch", "receipt checkpoint differs")
            if manifest["checkpoint_sha256"] != checkpoint["payload_sha256"]:
                raise WorkerError("artifact_checkpoint_identity_mismatch", "artifact checkpoint differs")
            prior_receipts.append(receipt["payload_sha256"])
            if manifest["trainer_step"] != step or manifest["receipt_sha256s"] != prior_receipts:
                raise WorkerError("artifact_step_chain_mismatch", "durable artifact chain differs")
            accepted_batch_ids.extend(group["batch_id"] for group in update["groups"])

        self.step = max(steps)
        if self.intent_path.exists():
            raise WorkerError(
                "ambiguous_prior_acceptance",
                "next-step sealed intent exists without a durable artifact",
                accepted=True,
            )
        manifest_path = self.artifact_path / "imp-trl-artifact.json"
        self.artifact = json.loads(manifest_path.read_text())
        self.checkpoint = json.loads((self.artifact_path / "trainer-checkpoint.json").read_text())
        self.receipt = json.loads((self.artifact_path / f"receipt-{self.step}.json").read_text())
        self.accepted_batch_ids = accepted_batch_ids
        validate_envelope(self.artifact, "imp_trl_grpo_artifact")
        validate_envelope(self.checkpoint, "imp_trl_grpo_checkpoint")
        validate_envelope(self.receipt, "imp_trl_grpo_receipt")

    def _load_latest_adapter(self) -> None:
        if self.model is None:
            raise WorkerError("worker_not_initialized", "base model must load before adapter resume")
        from peft import PeftModel

        self.model = PeftModel.from_pretrained(
            self.model,
            str(self.artifact_path / "adapter"),
            is_trainable=True,
        )
        self.model.to("mps")
        self._assert_trainable_device(self.model, "mps")
        observation = json.loads((self.artifact_path / "trl-observation.json").read_text())
        if self._trainable_digest(self.model) != observation["trainable_after_sha256"]:
            raise WorkerError("resume_adapter_identity_mismatch", "resumed LoRA tensors differ")

    def _copy_prior_envelopes(self, staging: pathlib.Path, target_step: int) -> None:
        for prior_step in range(1, target_step):
            prior = self.root / "artifacts" / f"step-{prior_step}"
            update = prior / f"update-{prior_step}.json"
            receipt = prior / f"receipt-{prior_step}.json"
            if not update.is_file() or not receipt.is_file():
                raise WorkerError(
                    "artifact_predecessor_missing",
                    f"step {prior_step} update/receipt is unavailable",
                    accepted=True,
                )
            shutil.copy2(update, staging)
            shutil.copy2(receipt, staging)

    def _verify_artifact_inventory(
        self, artifact_path: pathlib.Path, manifest: dict[str, Any]
    ) -> None:
        manifest_path = artifact_path / "imp-trl-artifact.json"
        expected_files = sorted(
            manifest["files"]
            + [
                {
                    "path": "imp-trl-artifact.json",
                    "size": manifest_path.stat().st_size,
                    "sha256": file_digest(manifest_path),
                }
            ],
            key=lambda entry: entry["path"],
        )
        actual_files = sorted(safe_tree_inventory(artifact_path), key=lambda entry: entry["path"])
        if actual_files != expected_files:
            raise WorkerError("artifact_inventory_mismatch", "durable artifact bytes changed")

    def _current_training_state(self) -> tuple[dict[str, Any], dict[str, Any]]:
        assert self.protocol is not None
        if self.step == 0:
            return (
                {
                    "global_step": 0,
                    "state_sha256": digest(
                        {"initial": self.protocol["optimizer"]["config_sha256"], "step": 0}
                    ),
                },
                {
                    "algorithm": self.protocol["rng"]["algorithm"],
                    "state_sha256": digest(
                        {"initial": self.protocol["rng"]["state_sha256"], "step": 0}
                    ),
                },
            )
        return self.checkpoint["optimizer"], self.checkpoint["rng"]

    def _current_behavior_policy(self) -> dict[str, Any]:
        assert self.protocol is not None
        if self.step == 0:
            return self.protocol["behavior_policy"]
        return {
            "model": str(self.artifact_path),
            "artifact_sha256": self.artifact["payload_sha256"],
            "tokenizer_sha256": self.protocol["behavior_policy"]["tokenizer_sha256"],
        }

    def _accepted_update_sha256s(self) -> list[str]:
        return [] if self.step == 0 else list(self.checkpoint["accepted_update_sha256s"])

    def _receipt_sha256s(self) -> list[str]:
        return [] if self.step == 0 else list(self.artifact["receipt_sha256s"])

    def _pending_batch_ids(self) -> list[str]:
        assert self.protocol is not None
        return [f"trl-step-{self.step}-all-generated-groups-ready"]

    def _verify_environment(self) -> None:
        if sys.version_info[:2] != (3, 12):
            raise WorkerError("python_identity_mismatch", "worker requires CPython 3.12")
        forbidden = [
            key
            for key in os.environ
            if any(fragment in key.upper() for fragment in ("TOKEN", "API_KEY", "PASSWORD", "SECRET"))
            and key != "TOKENIZERS_PARALLELISM"
            and os.environ.get(key)
        ]
        if forbidden:
            raise WorkerError("credential_environment_present", "credential-bearing environment refused")

    def _verify_model_tree(self) -> dict[str, Any]:
        if not self.model_path.is_dir():
            raise WorkerError("model_missing", "pinned local model directory is missing")
        expected = self.contract["model"]["files"]
        actual_names = sorted(path.name for path in self.model_path.iterdir())
        expected_names = sorted(item["path"] for item in expected)
        if actual_names != expected_names:
            raise WorkerError("model_inventory_mismatch", f"expected {expected_names}, got {actual_names}")
        inventory = []
        for item in expected:
            path = self.model_path / item["path"]
            if path.is_symlink() or not path.is_file() or path.stat().st_size != item["size"]:
                raise WorkerError("model_file_mismatch", f"invalid model file {item['path']}")
            sha = file_digest(path)
            if "sha256" in item and sha != "sha256:" + item["sha256"]:
                raise WorkerError("model_digest_mismatch", f"digest mismatch for {item['path']}")
            inventory.append({"path": item["path"], "size": item["size"], "sha256": sha})
        if sum(item["size"] for item in inventory) != self.contract["model"]["runtime_bytes"]:
            raise WorkerError("model_byte_count_mismatch", "model runtime byte count mismatch")
        return {"inventory": inventory, "sha256": digest(inventory)}

    @staticmethod
    def _messages(messages: Any) -> list[dict[str, str]]:
        if not isinstance(messages, list) or not messages:
            raise WorkerError("invalid_messages", "prompt messages are required")
        result = []
        for message in messages:
            if set(message) != {"role", "content"}:
                raise WorkerError("invalid_message_shape", "message keys must be role/content")
            if not isinstance(message["role"], str) or not isinstance(message["content"], str):
                raise WorkerError("invalid_message_value", "message role/content must be strings")
            result.append({"role": message["role"], "content": message["content"]})
        return result

    @staticmethod
    def _assert_model_device(model, expected: str) -> None:
        devices = {parameter.device.type for parameter in model.parameters()}
        if devices != {expected}:
            raise WorkerError("model_device_mismatch", f"model devices are {sorted(devices)}")

    @staticmethod
    def _assert_trainable_device(model, expected: str) -> None:
        devices = {parameter.device.type for parameter in model.parameters() if parameter.requires_grad}
        if devices != {expected}:
            raise WorkerError("trainable_device_mismatch", f"trainable devices are {sorted(devices)}")

    @staticmethod
    def _trainable_digest(model) -> str:
        hasher = hashlib.sha256()
        count = 0
        for name, parameter in sorted(model.named_parameters()):
            if parameter.requires_grad:
                count += 1
                value = parameter.detach().cpu().contiguous()
                hasher.update(canonical({"name": name, "shape": list(value.shape), "dtype": str(value.dtype)}))
                hasher.update(value.numpy().tobytes())
        if count == 0:
            raise WorkerError("no_trainable_tensors", "LoRA model has no trainable tensors")
        return "sha256:" + hasher.hexdigest()

    @staticmethod
    def _mps_rng_digest(torch) -> str | None:
        if hasattr(torch, "mps") and hasattr(torch.mps, "get_rng_state"):
            state = torch.mps.get_rng_state()
            return "sha256:" + hashlib.sha256(state.cpu().numpy().tobytes()).hexdigest()
        return None


def read_frame() -> bytes | None:
    header = sys.stdin.buffer.read(4)
    if not header:
        return None
    if len(header) != 4:
        raise EOFError("truncated frame header")
    length = struct.unpack(">I", header)[0]
    if length > 64 * 1024 * 1024:
        raise ValueError("frame too large")
    body = sys.stdin.buffer.read(length)
    if len(body) != length:
        raise EOFError("truncated frame")
    return body


def write_frame(value: Any) -> None:
    body = canonical(value)
    sys.stdout.buffer.write(struct.pack(">I", len(body)))
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()


def dispatch(worker: Worker, request: dict[str, Any]) -> Any:
    op = request.get("op")
    if op == "initialize":
        return worker.initialize()
    if op == "bind_session":
        return worker.bind_session(request["envelope"])
    if op == "reconcile":
        return worker.reconcile()
    if op == "status":
        return worker._status()
    if op == "generate":
        return worker.generate(request)
    if op == "controlled_completion":
        return worker.controlled_completion(request)
    if op == "deploy_artifact":
        return worker.deploy_artifact(request)
    if op == "deploy_base":
        return worker.deploy_base(request)
    if op == "prepare_update":
        return worker.prepare_update(request)
    if op == "apply_update":
        return worker.apply_update(request["envelope"])
    if op == "terminate":
        return worker.terminate()
    if op == "protocol_self_test":
        value = request["value"]
        return {"canonical": canonical(value).decode(), "sha256": digest(value)}
    raise WorkerError("unknown_operation", "operation is not allowlisted")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--contract", required=True)
    args = parser.parse_args()
    worker = Worker(pathlib.Path(args.root), pathlib.Path(args.model), pathlib.Path(args.contract))

    while (frame := read_frame()) is not None:
        try:
            request = json.loads(frame)
            if not isinstance(request, dict):
                raise WorkerError("invalid_request", "request must be an object")
            write_frame({"ok": True, "result": dispatch(worker, request)})
        except WorkerError as error:
            write_frame(
                {
                    "ok": False,
                    "error": {
                        "code": error.code,
                        "message": str(error),
                        "accepted": error.accepted,
                    },
                }
            )
        except Exception as error:
            write_frame(
                {
                    "ok": False,
                    "error": {
                        "code": "worker_failure",
                        "message": f"{type(error).__name__}: {error}",
                        "accepted": bool(worker.intent_path.exists()),
                    },
                }
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
