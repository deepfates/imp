"""Stock-DSPy translation of the GEPA artifact IFBench two-stage program.

The paper artifact's program overrides ``__call__`` for its modified DSPy
fork. Stock DSPy 3.2.1 instruments ``Module.forward`` during GEPA bootstrap.
This class changes only that top-level entry contract: predictor construction,
names, signatures, and the two-stage dataflow are inherited verbatim from the
pinned artifact program.
"""

from __future__ import annotations

import dspy

from gepa_artifact.benchmarks.IFBench.ifbench_program import IFBenchCoT2StageProgram


TRANSLATION_ID = "stock-dspy-adapted-ifbench-cot-2stage-v1"


class IFBenchCoT2StageModule(dspy.Module):
    """Ordinary DSPy module for the artifact's exact two-stage task graph."""

    def __init__(self) -> None:
        super().__init__()
        artifact_program = IFBenchCoT2StageProgram()
        self.generate_response_module = artifact_program.generate_response_module
        self.ensure_correct_response_module = (
            artifact_program.ensure_correct_response_module
        )

    def forward(self, prompt: str):
        response = self.generate_response_module(query=prompt).response
        final_response = self.ensure_correct_response_module(
            query=prompt, response=response
        )
        return dspy.Prediction(response=final_response.final_response)
