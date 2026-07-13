defmodule DSExDeployment.OptimizerArtifacts do
  @moduledoc false

  alias DSEx.Optimizer.Artifact

  def load_apply_and_preserve(path, live_program, candidate_id \\ :champion) do
    artifact = Artifact.read!(path)
    applied = Artifact.apply(artifact, live_program, candidate_id)
    {applied, artifact}
  end

  def promote_and_persist(path, artifact, candidate_id) do
    promoted = Artifact.promote(artifact, candidate_id)
    :ok = Artifact.write!(promoted, path)
    promoted
  end

  def rollback_and_persist(path, artifact) do
    rolled_back = Artifact.rollback(artifact)
    :ok = Artifact.write!(rolled_back, path)
    rolled_back
  end
end
