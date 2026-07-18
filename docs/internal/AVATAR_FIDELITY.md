# Avatar fidelity

Imp treats the Avatar actor and Avatar trajectory optimizer as two independent
families. Both are BEAM-native adaptations of source-defined DSPy 3.2.1
surfaces. Their provider-free C1 protocols authenticate the clean DSPy tag and
commit `29448ae12756abdd14bd8796c819247ebb83673c`, verify every file in the
296-file authority manifest, scrub credential-shaped environment variables
before importing DSPy, and execute in an isolated child process.

## Avatar actor protocol

```sh
mix imp.benchmark.avatar_actor_differential --require-clean
```

The fixture compares only three observations: a typed lookup precedes Finish,
the successful non-Finish action is retained in ordered history, and its result
is available when producing the final answer. It does not compare prompt or
signature text, provider behavior, model-selected tools, failure behavior, task
quality, or full Avatar parity.

Imp deliberately enforces the configured iteration bound, uses a separate
typed finisher, and turns unknown, denied, crashed, and timed-out tools into
recoverable observations. DSPy 3.2.1 mutates and reuses its actor signature and
does not consistently apply the constructor `max_iters` value. These are named
native deviations, not hidden mismatches.

## AvatarOptimizer protocol

```sh
mix imp.benchmark.avatar_optimizer_differential --require-clean
```

The fixture compares one upper-bound positive and one lower-bound negative
trajectory, one comparator and rewrite call, feedback propagation, and the
resulting rewritten instruction. It excludes exact Python RNG and sampling,
exact comparator prompts, provider behavior, rewrite quality, held-out lift,
and full AvatarOptimizer parity.

Imp evaluates the rewritten candidate and retains it only when the candidate's
measured score improves. DSPy 3.2.1 updates the instruction based on the
pre-rewrite actor score. Imp also returns an executable diagnostic baseline
when either trajectory class is absent and takes bounded examples
deterministically. A C1 artifact must preserve these deviations explicitly.

Neither protocol can emit admissible evidence from a dirty checkout. The
artifact binds the committed task, Python sidecar, shared authentication
helper, fixture, authority ledger and manifest, and relevant Imp implementation
source. Capture and registry admission therefore occur only after these files
are committed cleanly.
