#!/usr/bin/env python3
"""Capture pinned Optuna startup choices used by DSPy 3.2.1 MIPROv2."""

import json

import optuna


SEEDS = [2026072602, 2026072603, 2026072604]


def choices(seed):
    sampler = optuna.samplers.TPESampler(seed=seed, multivariate=True)
    study = optuna.create_study(direction="maximize", sampler=sampler)
    distribution = optuna.distributions.CategoricalDistribution(range(6))
    baseline = optuna.trial.create_trial(
        params={"0_predictor_instruction": 0},
        distributions={"0_predictor_instruction": distribution},
        value=0.0,
    )
    study.add_trial(baseline)

    selected = []
    for _ in range(9):
        trial = study.ask()
        selected.append(trial.suggest_categorical("0_predictor_instruction", range(6)))
        study.tell(trial, 0.0)
    return selected


print(
    json.dumps(
        {
            "optuna": optuna.__version__,
            "schedules": {str(seed): choices(seed) for seed in SEEDS},
        },
        sort_keys=True,
    )
)
