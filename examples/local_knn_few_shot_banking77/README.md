# Local KNNFewShot Banking77 program

This ordinary consumer runs `Imp.Optimizer.KNNFewShot` against the retained,
verified MLX-fused Qwen Banking77 classifier. It uses sixteen frozen training
rows for local Bag-of-Words retrieval and metric-gated BootstrapFewShot, eight
separate rows to select baseline versus KNN, and opens the forty untouched rows
only for the selected arm.

Every KNN call retrieves one neighbor, makes one teacher/bootstrap task call,
and then calls the student with any accepted demonstration. The example rejects
a façade where retrieval occurs but no demonstration is ever rendered. It
saves the selected program and completed `TrainingJob`, restarts them in a
fresh OS BEAM, and requires exact artifact identity plus byte-identical ordered
predictions/errors.

Set `IMP_MLX_JOB` to the retained completed Banking77 job:

```sh
export IMP_MLX_JOB=/path/to/training-job.json
mix run examples/local_knn_few_shot_banking77/run.exs
```

A positive, neutral, or negative result applies only to this model/task/split.
It cannot establish general KNNFewShot or BootstrapFewShot effectiveness,
upstream parity, production reliability, or BEAM superiority.
