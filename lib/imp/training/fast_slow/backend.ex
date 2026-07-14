defmodule Imp.Training.FastSlow.Backend do
  @moduledoc """
  Provider-neutral effects required by the Fast-Slow Algorithm 1 runner.

  Every callback receives the persisted operation intent. Backends should use
  `intent.id` as their idempotency key when an effect can be retried.
  """

  alias Imp.Training.FastSlow.{
    AdvantageGroup,
    CachedTrajectory,
    Config,
    DatasetState,
    OperationIntent,
    State
  }

  @type data_minibatch :: map()
  @type backend_context :: Config.json_value()
  @type error_reason :: term()

  @type gepa_result :: %{
          required(:candidates) => [term()],
          required(:candidate_ids) => [String.t()],
          required(:instance_scores) => map(),
          required(:instance_frontier) => map(),
          optional(:anchor_digest) => String.t(),
          optional(:cached_trajectories) => [CachedTrajectory.t()]
        }

  @type rollout_slot :: %{
          required(:cycle) => non_neg_integer(),
          required(:slow_step) => non_neg_integer(),
          required(:batch_id) => String.t(),
          required(:group_id) => String.t(),
          required(:problem) => map(),
          required(:problem_id) => String.t(),
          required(:dataset_indices) => [non_neg_integer()],
          required(:input_digest) => String.t(),
          required(:prompt) => term(),
          required(:prompt_digest) => String.t(),
          required(:prompt_index) => non_neg_integer(),
          required(:member_index) => non_neg_integer(),
          required(:group_size) => pos_integer(),
          required(:theta_id) => String.t(),
          required(:prompt_revision) => non_neg_integer(),
          required(:sampling_config_digest) => String.t()
        }

  @type live_rollout_result :: %{
          required(:output) => term(),
          required(:score) => number(),
          required(:behavior_logprobs) => [number()],
          required(:response_token_ids) => [non_neg_integer()],
          required(:response_mask) => [0 | 1],
          optional(:metrics) => term()
        }

  @doc """
  Certifies that replaying an existing unreconciled or retryable intent cannot
  duplicate an external effect.

  Return `true` only when the provider uses `intent.id` idempotently or has
  established that the prior attempt was not applied.
  """
  @callback replay_safe?(OperationIntent.t(), backend_context()) :: boolean()

  @doc "Prefetches exactly `count` ordered, data-only minibatches and their resulting cursor."
  @callback prefetch(State.t(), pos_integer(), OperationIntent.t(), backend_context()) ::
              {:ok, [data_minibatch()], DatasetState.t(), backend_context()}
              | {:error, error_reason(), backend_context()}

  @doc """
  Validates the provider-owned dataset transition produced by `prefetch/4`.

  The runner validates count, order, identities, and content digests itself.
  The backend owns cursor, epoch, shuffle, and sampler semantics, so it must
  reject a resulting dataset state that does not follow from the returned
  minibatches.
  """
  @callback validate_prefetch_progression(
              State.t(),
              [data_minibatch()],
              DatasetState.t(),
              backend_context()
            ) :: :ok | {:error, error_reason()}

  @doc "Runs one fast GEPA phase and returns exactly K Pareto-selected candidates."
  @callback optimize_fast(
              State.t(),
              [data_minibatch()],
              OperationIntent.t(),
              backend_context()
            ) ::
              {:ok, gepa_result(), backend_context()}
              | {:error, error_reason(), backend_context()}

  @doc "Generates and verifies one rollout for a planned slot not satisfied by the reuse cache."
  @callback generate_rollout(
              State.t(),
              rollout_slot(),
              OperationIntent.t(),
              backend_context()
            ) ::
              {:ok, live_rollout_result(), backend_context()}
              | {:error, error_reason(), backend_context()}

  @doc "Performs one slow provider update from one ordered minibatch and its question groups."
  @callback update_slow(
              State.t(),
              data_minibatch(),
              [AdvantageGroup.t()],
              OperationIntent.t(),
              backend_context()
            ) ::
              {:ok, theta_payload :: term(), backend_context()}
              | {:error, error_reason(), backend_context()}
end
