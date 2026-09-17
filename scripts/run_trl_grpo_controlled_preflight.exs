alias Imp.Optimizer.GRPO.Callback

[mode, root] = System.argv()
runtime_mode = if mode == "create", do: :hang_after_start, else: :normal

source =
  "benchmarks/data/provider-training-banking77-v1.json"
  |> File.read!()
  |> Jason.decode!()

row = Enum.find(source["train"], &(&1["id"] == "banking77-train-2511"))

signature =
  Imp.Signature.new(%{
    inputs: [%{name: :utterance, desc: "a real customer banking support request"}],
    outputs: [%{name: :route, desc: "exactly one opaque route: R17, R42, R68, or R93"}],
    instructions: """
    Classify the customer request into exactly one opaque route and return only that route.
    R17: a fee was charged for making a card payment.
    R42: a card payment is not recognized by the customer.
    R68: a card payment is still pending.
    R93: a card payment was reversed or reverted.
    """
  })

program =
  Imp.predict(signature,
    lm: %Imp.Test.ControlledRouteLM{
      model: "Qwen/Qwen2.5-0.5B-Instruct@7ae557604adf67be50417f59c2c2f167def9a775"
    }
  )

callback =
  Callback.reward(Imp.Test.StableGRPOCallbacks, :exact_answer,
    id: "banking77-exact-route-v1",
    config: %{"field" => "route"}
  )

trainer = %Imp.Test.FileGRPOTrainer{root: root, runtime_mode: runtime_mode}

optimizer =
  Imp.Optimizer.GRPO.new(callback,
    trainer: trainer,
    checkpoint_path: Path.join(root, "checkpoint.json"),
    num_train_steps: 1,
    num_dspy_examples_per_grpo_step: 1,
    num_rollouts_per_grpo_step: 4,
    seed: 20_260_725,
    callback_timeout_ms: 100,
    status_poll_interval_ms: 0,
    timeout: 120_000
  )

example =
  Imp.example(
    utterance: row["utterance"],
    route: row["route"],
    source_id: row["id"]
  )
  |> Imp.with_inputs(:utterance)

IO.inspect(Imp.train(program, optimizer, [example]), limit: :infinity)
