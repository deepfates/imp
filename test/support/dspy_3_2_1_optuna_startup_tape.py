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


def two_parameter_choices(seed):
    sampler = optuna.samplers.TPESampler(seed=seed, multivariate=True)
    study = optuna.create_study(direction="maximize", sampler=sampler)
    distribution = optuna.distributions.CategoricalDistribution(range(4))
    distributions = {
        "0_predictor_instruction": distribution,
        "1_predictor_instruction": distribution,
    }
    baseline = optuna.trial.create_trial(
        params={
            "0_predictor_instruction": 0,
            "1_predictor_instruction": 0,
        },
        distributions=distributions,
        value=0.0,
    )
    study.add_trial(baseline)

    selected = []
    for _ in range(8):
        trial = study.ask()
        params = {
            name: trial.suggest_categorical(name, range(4))
            for name in distributions
        }
        selected.append(params)
        study.tell(trial, 0.0)
    return selected


def modeled_choices(seed, parameter_count, constant_score=None):
    sampler = optuna.samplers.TPESampler(seed=seed, multivariate=True)
    study = optuna.create_study(direction="maximize", sampler=sampler)
    names = [f"{index}_predictor_instruction" for index in range(parameter_count)]
    distributions = {
        name: optuna.distributions.CategoricalDistribution(range(4)) for name in names
    }
    baseline_params = {name: 0 for name in names}
    study.add_trial(
        optuna.trial.create_trial(
            params=baseline_params,
            distributions=distributions,
            value=constant_score if constant_score is not None else 0.25,
        )
    )

    trials = []
    for trial_index in range(15):
        trial = study.ask()
        params = {
            name: trial.suggest_categorical(name, range(4)) for name in names
        }
        # Deterministic, non-monotonic scores make the modeled phase depend on
        # both ranking and the full joint categorical assignment.
        score = (
            constant_score
            if constant_score is not None
            else ((sum((index + 2) * params[name] for index, name in enumerate(names)) * 3 + trial_index) % 13) / 12
        )
        study.tell(trial, score)
        trials.append({"params": params, "score": score})
    return trials


print(
    json.dumps(
        {
            "optuna": optuna.__version__,
            "schedules": {str(seed): choices(seed) for seed in SEEDS},
            "two_parameter_schedules": {
                str(seed): two_parameter_choices(seed) for seed in SEEDS
            },
            "modeled_schedules": {
                str(seed): {
                    "one_parameter": modeled_choices(seed, 1),
                    "two_parameter": modeled_choices(seed, 2),
                }
                for seed in [9, *SEEDS]
            },
            "constant_modeled_schedule": modeled_choices(9, 1, constant_score=1.0),
        },
        sort_keys=True,
    )
)
