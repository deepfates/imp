# Choosing an optimizer

## Intent

Imp ships the DSPy optimizers and a few of its own, and the question
everyone asks is which one to use. This page is the selection guide: what
each optimizer changes in your program, what it needs before it can run,
what it costs, and when it is the right one.

Read it once you have a program, a metric and some labeled examples. How to
write the metric is on [Metrics and evaluation](metrics-and-evaluation.md);
what to do with the result is on [Saving and artifacts](saving-and-artifacts.md).

## Design decisions

### 1. Every optimizer tunes instructions, demos, or weights

Instructions are the text of each predictor's signature. Demos are the
worked examples a predictor sees in its prompt. Weights are the model
itself, when you can train it. Each optimizer turns one or two of these
knobs and leaves the rest alone, and the walkthrough below is grouped that
way. The result is data you can read: `program.demos`,
`program.signature.instructions`, or a training job.

### 2. Optimizing returns a new program

A program is an immutable value, so `Imp.optimize!/3` returns a new one and
the program you passed in is unchanged. You can run several optimizers on the
same starting point and compare them without state leaking between runs. The
optimizer's report travels with the result:

```elixir
metric = Imp.exact_match(:team)
router = Imp.predict("ticket -> team: enum[atlas,harbor,beacon,quill]")

trainset = [
  Imp.example(ticket: "We were charged twice this month.", team: "atlas")
  |> Imp.with_inputs(:ticket)
]

improved = Imp.optimize!(router, Imp.Optimizer.LabeledFewShot.new(k: 1), trainset)

{length(router.demos), length(improved.demos),
 Imp.Optimizer.Report.fetch(improved).optimizer}
#=> {0, 1, :labeled_few_shot}
```

### 3. Each optimizer declares the data it takes

Some optimizers select on a separate validation set and require one; others
take only a training set and refuse a validation set rather than ignore it.
`Imp.optimizer_capabilities/1` says which, and a call with the wrong data is
refused before any model is called:

```elixir
strong_lm = Imp.req_llm("openai:gpt-5.4", api_key: System.fetch_env!("OPENAI_API_KEY"))
gepa = Imp.Optimizer.GEPA.new(metric, reflection_lm: strong_lm, max_metric_calls: 300)

{:ok, capabilities} = Imp.optimizer_capabilities(gepa)
capabilities.datasets
#=> %{trainset: :required, validation: :required}

Imp.optimize(router, gepa, trainset)
#=> {:error, {:missing_dataset, :validation}}
```

Pass the validation set as the fourth argument: `Imp.optimize!(router, gepa,
trainset, valset)`.

### 4. Instruction optimizers need a model to write proposals, and you name it

COPRO, GEPA, MIPROv2, SIMBA and InferRules ask a model to write new
instructions. That model is usually stronger than the one running the task,
because writing a good instruction is harder than following one. Imp never
falls back to canned text when there is no proposal model: GEPA refuses to
start without `reflection_lm:`, COPRO uses `proposer_lm:` or the model in
Imp's settings, and MIPROv2, SIMBA and InferRules fall back to the program's
own model.

### 5. Only GEPA reads the metric's feedback

Every optimizer reads a score per example. GEPA also reads the `feedback`
a metric can return and hands it to the reflection model, so it knows *why*
an answer was wrong, not only that it was. With a metric that only scores,
GEPA still works, but it loses what it is best at, and MIPROv2 or COPRO may
do as well for the same spend.

### 6. Weights are trained with `Imp.train/4`, not `Imp.optimize/3`

Fine-tuning is a provider job that can take hours and can fail on its own
schedule. `Imp.train/4` returns an `Imp.Optimizer.TrainingResult` that
describes that job, rather than pretending to hand back a finished program.
Prompt optimizers work with any model; weight optimizers need a model you can
train.

### 7. Start with demos

Demos are cheap to find, easy to read and often enough. On the
[README](../../README.md)'s ticket router, eight labeled examples took
`gpt-5.4-mini` from 25–35% to 75–85% on unseen tickets in three runs, for
about a cent each. Instruction search earns its cost when the wording is the
problem: the task has a rule the examples do not show, or the program has
several steps whose instructions interact.

### 8. Optimize once, serve many times

A compile that calls models is expensive; serving its result is not. The
economics work when you optimize once per version of the program, save the
result, and serve the saved program. The saved form is JSON without
credentials, reviewed like any other change.

### 9. Imp does not choose for you

Nothing inspects your task and picks an optimizer. The `auto:` levels on
MIPROv2 set a budget within that optimizer, not which optimizer to use. The
table at the end of this page is the closest thing to a recommendation.

## A two-axis decision

**What is holding the program back?** If the wording is wrong, instruction
optimizers help (COPRO, GEPA, MIPROv2). If the model needs examples to get
the format or the categories right, demo optimizers help (LabeledFewShot,
BootstrapFewShot, RandomSearch). If the model itself is the limit and you can
train it, tune weights (BootstrapFinetune).

**What can you spend?** LabeledFewShot costs nothing and BootstrapFewShot
little. Search (RandomSearch, MIPROv2, GEPA, SIMBA) costs real money, roughly
in proportion to candidates times validation examples. Combinations
(BetterTogether) pay for each step. To put a hard ceiling on any of them, wrap
the task and proposal models with `Imp.budgeted_lm/3` under
`Imp.start_optimizer_budget/1`; a call that would exceed the ceiling is
refused before it is sent.

## API walkthrough

Grouped by what each optimizer tunes. The examples use `metric` and
`strong_lm` from above.

### Start here

```elixir
labeled = Imp.Optimizer.LabeledFewShot.new(k: 8)

bootstrap =
  Imp.Optimizer.BootstrapFewShot.new(metric,
    max_bootstrapped_demos: 4,
    max_labeled_demos: 8
  )
```

**`LabeledFewShot`** makes no model calls. It attaches up to `k` training
examples (16 by default) as demos to every predictor. It is the baseline: if
it is good enough, heavier optimization is wasted.

**`BootstrapFewShot`** runs the program on training examples, scores each run
with the metric, and keeps the passing runs as demos, including the
intermediate fields of multi-step programs that your labels do not have. It
stops once it has `max_bootstrapped_demos` and fills the rest with labeled
examples. Cost: at most one program run per training example. The safe first
try when you trust the metric.

### Search across demo sets

```elixir
random_search = Imp.Optimizer.RandomSearch.new(metric, num_candidate_programs: 8)

knn =
  Imp.Optimizer.KNNFewShot.new(3, trainset,
    vectorizer: Imp.Embeddings.BagOfWords,
    few_shot_bootstrap_args: [metric: metric]
  )
```

**`RandomSearch`** (also `BootstrapRS`, DSPy's name) bootstraps
`num_candidate_programs` demo sets with different seeds, evaluates each, and
keeps the best. Pass a validation set to select on it; without one it selects
on the training set. Cost: candidates times (bootstrap plus evaluation).

**`KNNFewShot`** chooses demos when the program is *called*: it finds the `k`
training examples nearest the input and bootstraps demos from them for that
one call. Build the program with `Imp.Optimizer.KNNFewShot.compile(knn,
router)`. Reach for it when no single demo set suits every input, and budget
for the extra model calls it makes on every request.

### Optimize instructions

```elixir
copro = Imp.Optimizer.COPRO.new(metric, proposer_lm: strong_lm, breadth: 6, depth: 2)
gepa = Imp.Optimizer.GEPA.new(metric, reflection_lm: strong_lm, max_metric_calls: 300)
```

**`COPRO`** proposes `breadth` instructions per predictor, keeps the best, and
repeats `depth` times. Cost: about breadth times depth times predictors
evaluations of the training set. Light, and useful when the demos are fine and
the wording is not.

**`GEPA`** keeps a population of programs, runs them on minibatches, reads the
metric's feedback, and asks `reflection_lm` to rewrite one predictor's
instruction at a time; it returns the best candidate on the validation set.
`max_metric_calls` is the budget. Requires a validation set. It is the
strongest prompt optimizer when you have a good reflection model and a metric
that explains its scores.

### Optimize instructions and demos together

```elixir
mipro = Imp.Optimizer.MIPROv2.new(metric, auto: :light, prompt_lm: strong_lm)
simba = Imp.Optimizer.SIMBA.new(metric, prompt_lm: strong_lm, max_steps: 4)
infer_rules = Imp.Optimizer.InferRules.new(metric, rule_lm: strong_lm, num_rules: 5)
```

**`MIPROv2`** bootstraps demo sets, proposes instructions grounded in your
data and program, then searches the combinations with a Bayesian optimizer
over minibatches, choosing only on full validation scores. `auto: :light`,
`:medium` or `:heavy` sets the budget. Requires a validation set.

**`SIMBA`** samples minibatches, finds the examples where the program's
answers vary most, and adds either a demo from a good run or a rule written
by `prompt_lm` for that predictor. It targets the current weak spot rather
than the average.

**`InferRules`** bootstraps demos, asks `rule_lm` to state the rules they
follow, and appends those rules to the instructions, where you can read and
edit them. The original program and the bootstrapped one stay candidates, so
the rules must beat both.

### Tune weights

```elixir
finetune = Imp.Optimizer.BootstrapFinetune.new(metric)
```

**`BootstrapFinetune`** bootstraps passing runs the way `BootstrapFewShot`
does and turns them into a fine-tuning job for the student model. Run it with
`Imp.train/4`. It needs a model whose client can train, such as
`Imp.Clients.OpenAITrainer`. Experimental: the training clients are newer
than the prompt optimizers.

### Compose

```elixir
better_together = Imp.Optimizer.BetterTogether.new(metric)
ensemble = Imp.Optimizer.Ensemble.new(reduce_fn: &Imp.majority/1)
```

**`BetterTogether`** runs a sequence such as `strategy: "p -> w -> p"`
(prompt, then weights, then prompt again), evaluates the original and every
prefix, and returns the best. Its default prompt step is `RandomSearch`; its
weight step needs a configured trainer.

**`Ensemble`** is not a search. `Imp.Optimizer.Ensemble.compile(ensemble,
programs)` builds one program that calls several and reduces their answers,
here by majority vote. Useful when several runs each produced a competent
program.

### Specialized

```elixir
avatar = Imp.Optimizer.Avatar.new(metric)
```

**`Avatar`** rewrites the instructions of an `Imp.avatar/3` agent by
contrasting runs that scored well with runs that scored badly.

### Experimental

Each of these is Imp's own and still settling.

- **`Imp.Optimizer.SignatureOptimizer`** searches instructions for one named
  predictor, choosing on a validation set.
- **`Imp.Optimizer.GRPO`** trains weights by reinforcement from the program's
  rewards, through `Imp.train/4`.
- **`Imp.Optimizer.Playbook`** grows a reviewed playbook of lessons the
  program reads at run time.
- **`Imp.Optimize.Anything`** optimizes any text or JSON value, such as tool
  descriptions, against an evaluator's feedback, using GEPA's search.

## Which one

| Situation | Try |
|---|---|
| Starting out; no idea what helps | `LabeledFewShot`, then `BootstrapFewShot` |
| Multi-step program; labels cover only the final answer | `BootstrapFewShot` |
| Demo quality varies from run to run | `RandomSearch` |
| Inputs vary so much that one demo set cannot fit them all | `KNNFewShot` |
| The wording is wrong; the demos are fine | `COPRO` or `GEPA` |
| Both look weak and you have budget | `MIPROv2` or `GEPA` |
| Your metric can say why an answer is wrong | `GEPA` |
| Failures share a pattern you could state as a rule | `SIMBA` or `InferRules` |
| Prompt optimization has plateaued and you can train the model | `BootstrapFinetune` |
| You want prompt and weight tuning in sequence | `BetterTogether` |
| You have several competent programs | `Ensemble` |

## Cross-links

- [Metrics and evaluation](metrics-and-evaluation.md): the metric every
  optimizer compiles against, and the feedback shape GEPA reads.
- [Saving and artifacts](saving-and-artifacts.md): keeping what an optimizer
  produced and applying it to a running application.
- [Runs and supervision](runs-and-supervision.md): how optimizer fan-out is
  bounded by `async_max_workers`.
- The module docs of each optimizer list every option.
