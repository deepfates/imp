#!/usr/bin/env python3
"""Validate Imp's ATIF export using Harbor's own models, not a local schema copy.

Install Harbor in the selected Python environment. For an upstream checkout,
set PYTHONPATH=/path/to/harbor/src (its package metadata must also be installed).
"""
import argparse
from pathlib import Path

from harbor.utils.trajectory_validator import TrajectoryValidator

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("trajectory", type=Path)
args = parser.parse_args()
validator = TrajectoryValidator()
if not validator.validate(args.trajectory):
    parser.exit(1, "\n".join(validator.get_errors()) + "\n")
print(f"Harbor ATIF validation passed: {args.trajectory}")
