#!/usr/bin/env python3
"""Extract auditable comparator evidence from the upstream GEPA data archive."""

import argparse
import ast
import csv
import hashlib
import io
import json
import re
import tarfile
from pathlib import Path


FAMILIES = {
    "AIMEBench": "CoT",
    "HotpotQABench": "HotpotMultiHop",
    "hoverBench": "HoverMultiHop",
    "IFBench": "IFBenchCoT2StageProgram",
    "LiveBenchMathBench": "CoT",
    "Papillon": "PAPILLON",
}
OPTIMIZERS = ("Baseline", "GEPA", "MIPROv2-Heavy")
RUN_RE = re.compile(
    r"^experiment_runs_data/experiment_runs/seed_(\d+)/"
    r"(.+?)_(.+?)_(Baseline|GEPA|MIPROv2-Heavy)_(.+?)/"
    r"(config.json|metric_logs/(?:train|val|test)\.jsonl|"
    r"evaluation_results/evaluation_result\.txt)$"
)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    parser.add_argument("--upstream-repo", type=Path, required=True)
    parser.add_argument("--model", default="gpt-41-mini")
    parser.add_argument("--out", type=Path, required=True)
    return parser.parse_args()


def source_budgets(repo):
    path = repo / "scripts" / "experiment_configs.py"
    tree = ast.parse(path.read_text(), filename=str(path))

    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == "get_max_invocations":
            for statement in node.body:
                if (
                    isinstance(statement, ast.Assign)
                    and len(statement.targets) == 1
                    and isinstance(statement.targets[0], ast.Name)
                    and statement.targets[0].id == "known_max_calls"
                ):
                    values = ast.literal_eval(statement.value)
                    return {
                        (family, program): limit
                        for (family, program, optimizer), limit in values.items()
                        if optimizer == "MIPROv2-Heavy"
                    }, path

    raise ValueError(f"could not locate known_max_calls in {path}")


def read_archive(archive, model):
    runs = {}

    with tarfile.open(archive, "r:gz") as tar:
        for member in tar:
            match = RUN_RE.match(member.name)
            if not match or not member.isfile():
                continue

            seed, family, program, optimizer, run_model, relative = match.groups()
            if run_model != model or FAMILIES.get(family) != program:
                continue

            run = runs.setdefault(
                (family, program, optimizer, int(seed)),
                {"metric_logs": {}, "paths": {}},
            )
            extracted = tar.extractfile(member)
            if extracted is None:
                raise ValueError(f"could not read {member.name}")

            if relative.startswith("metric_logs/"):
                split = relative.removeprefix("metric_logs/").removesuffix(".jsonl")
                count = 0
                max_step = 0
                digest = hashlib.sha256()
                for raw_line in extracted:
                    digest.update(raw_line)
                    row = json.loads(raw_line)
                    count += 1
                    max_step = max(max_step, row["step_counter"])
                run["metric_logs"][split] = {
                    "records": count,
                    "max_step_counter": max_step,
                    "sha256": digest.hexdigest(),
                    "path": member.name,
                }
            else:
                payload = extracted.read()
                run["paths"][relative] = {
                    "bytes": payload,
                    "sha256": hashlib.sha256(payload).hexdigest(),
                    "path": member.name,
                }

    return runs


def evaluation_record(run):
    result = run["paths"].get("evaluation_results/evaluation_result.txt")
    if result is None:
        raise ValueError("run is missing evaluation_result.txt")
    rows = list(csv.DictReader(io.StringIO(result["bytes"].decode())))
    if len(rows) != 1:
        raise ValueError(f"expected one evaluation row in {result['path']}")
    return result, float(rows[0]["score"])


def config_enforces_gepa(run):
    config = run["paths"].get("config.json")
    if config is None:
        return False
    optimizer_config = json.loads(config["bytes"])["optimizer_config"]
    return (
        "'add_max_metric_calls': True" in optimizer_config
        and "'max_metric_calls_source_opt_name': 'MIPROv2-Heavy'" in optimizer_config
    )


def total_callbacks(run):
    logs = run["metric_logs"]
    records = sum(item["records"] for item in logs.values())
    max_step = max((item["max_step_counter"] for item in logs.values()), default=0)
    if records != max_step:
        raise ValueError(
            "metric logs are not one complete counter sequence: "
            f"records={records}, max_step_counter={max_step}"
        )
    return records


def build_sidecar(runs, budgets, budget_path, archive, repo, model):
    output_runs = []

    for family, program in FAMILIES.items():
        baseline_key = (family, program, "Baseline", 0)
        if baseline_key not in runs:
            raise ValueError(f"missing {baseline_key}")
        final_test_callbacks = total_callbacks(runs[baseline_key])

        for optimizer in OPTIMIZERS:
            key = (family, program, optimizer, 0)
            if key not in runs:
                raise ValueError(f"missing {key}")
            run = runs[key]
            total = total_callbacks(run)
            observed = total - final_test_callbacks
            result, score = evaluation_record(run)
            limit = budgets.get((family, program)) if optimizer == "GEPA" else None
            enforced = optimizer == "GEPA" and config_enforces_gepa(run)

            output_runs.append(
                {
                    "family": family,
                    "program": program,
                    "optimizer": optimizer,
                    "model": model,
                    "seed": 0,
                    "metric_call_evidence": {
                        "basis": "observed_metric_callback_count",
                        "observed": observed,
                        "configured_limit": limit,
                        "enforced": enforced,
                        "source": (
                            "upstream metric JSONL total minus matching Baseline final-test "
                            "callbacks; GEPA limit/enforcement from upstream source and run config"
                        ),
                        "total_callbacks": total,
                        "final_test_callbacks": final_test_callbacks,
                        "observed_by_logged_split": {
                            split: details["records"]
                            for split, details in sorted(run["metric_logs"].items())
                        },
                        "log_files": [
                            {
                                "path": details["path"],
                                "sha256": details["sha256"],
                                "records": details["records"],
                            }
                            for _, details in sorted(run["metric_logs"].items())
                        ],
                        "reference_mipro_invocations": budgets[(family, program)],
                    },
                    "seed_selection": {
                        "method": "predeclared",
                        "selection_split": None,
                        "selected_seed": 0,
                        "seeds": [0],
                        "test_scores_used": False,
                        "source": "upstream launch generator SEEDS=[0] and archive seed_0 root",
                    },
                    "evaluation": {
                        "split": "test",
                        "score": score,
                        "result_sha256": result["sha256"],
                        "test_scores_used_for_selection": False,
                        "source": (
                            "scripts/run_experiments.py final_eval_set=benchmark.test_set "
                            f"and {result['path']}"
                        ),
                    },
                }
            )

    return {
        "schema_version": 1,
        "kind": "gepa_upstream_evidence",
        "source": {
            "archive": str(archive),
            "archive_sha256": sha256_file(archive),
            "upstream_repo": str(repo),
            "upstream_commit": git_commit(repo),
            "budget_source": str(budget_path),
        },
        "runs": output_runs,
    }


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_commit(repo):
    head = (repo / ".git" / "HEAD").read_text().strip()
    if head.startswith("ref: "):
        ref = repo / ".git" / head.removeprefix("ref: ")
        if ref.exists():
            return ref.read_text().strip()
        packed = (repo / ".git" / "packed-refs").read_text().splitlines()
        target = head.removeprefix("ref: ")
        return next(line.split()[0] for line in packed if line.endswith(f" {target}"))
    return head


def main():
    args = parse_args()
    budgets, budget_path = source_budgets(args.upstream_repo)
    runs = read_archive(args.archive, args.model)
    sidecar = build_sidecar(
        runs,
        budgets,
        budget_path,
        args.archive,
        args.upstream_repo,
        args.model,
    )
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(sidecar, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
