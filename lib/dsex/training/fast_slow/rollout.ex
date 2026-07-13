defmodule DSEx.Training.FastSlow.Rollout do
  @moduledoc false

  alias DSEx.Training.FastSlow.Config

  @statuses [:available, :claimed, :complete, :failed]
  @enforce_keys [
    :id,
    :identity_digest,
    :cycle,
    :group_id,
    :problem_id,
    :group_size,
    :member_index,
    :prompt_index,
    :theta_id,
    :prompt_revision,
    :dataset_indices,
    :input_digest,
    :prompt_digest,
    :behavior_policy_id,
    :sampling_config_digest,
    :behavior_logprobs,
    :response_token_ids,
    :response_mask,
    :source,
    :generated_at_step
  ]
  defstruct @enforce_keys ++
              [
                status: :available,
                claim_id: nil,
                output: nil,
                output_digest: nil,
                score: nil,
                metrics: %{},
                failure: nil
              ]

  @type status :: :available | :claimed | :complete | :failed
  @type t :: %__MODULE__{
          id: String.t(),
          identity_digest: String.t(),
          cycle: non_neg_integer(),
          group_id: String.t(),
          problem_id: String.t(),
          group_size: pos_integer(),
          member_index: non_neg_integer(),
          prompt_index: non_neg_integer(),
          theta_id: String.t(),
          prompt_revision: non_neg_integer(),
          dataset_indices: [non_neg_integer()],
          input_digest: String.t(),
          prompt_digest: String.t(),
          behavior_policy_id: String.t(),
          sampling_config_digest: String.t(),
          behavior_logprobs: [number()],
          response_token_ids: [non_neg_integer()],
          response_mask: [0 | 1],
          source: :live | :gepa_cache,
          generated_at_step: non_neg_integer(),
          status: status(),
          claim_id: String.t() | nil,
          output: Config.json_value() | nil,
          output_digest: String.t() | nil,
          score: number() | nil,
          metrics: Config.json_value(),
          failure: Config.json_value() | nil
        }

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = if is_list(attrs), do: Map.new(attrs), else: attrs

    required = [
      :cycle,
      :group_id,
      :problem_id,
      :group_size,
      :member_index,
      :prompt_index,
      :theta_id,
      :prompt_revision,
      :dataset_indices,
      :input_digest,
      :prompt_digest,
      :behavior_policy_id,
      :sampling_config_digest,
      :behavior_logprobs,
      :response_token_ids,
      :response_mask,
      :source,
      :generated_at_step
    ]

    missing = Enum.reject(required, &Map.has_key?(attrs, &1))
    if missing != [], do: raise(ArgumentError, "missing rollout keys: #{inspect(missing)}")

    identity = identity_from(attrs)
    identity_digest = Config.digest(identity)
    id = Map.get(attrs, :id, Config.digest(%{"rollout" => identity_digest}))

    attrs
    |> Map.put_new(:identity_digest, identity_digest)
    |> Map.put_new(:id, id)
    |> then(&struct!(__MODULE__, &1))
    |> validate!()
  end

  def new!(_attrs), do: raise(ArgumentError, "rollout attributes must be a keyword list or map")

  @doc false
  def from_cached!(%DSEx.Training.FastSlow.CachedTrajectory{} = cached, slot, state)
      when is_map(slot) do
    problem_id = fetch_slot!(slot, :problem_id)
    input_digest = fetch_slot!(slot, :input_digest)
    prompt_digest = fetch_slot!(slot, :prompt_digest)

    unless {problem_id, input_digest, prompt_digest} ==
             {cached.problem_id, cached.input_digest, cached.prompt_digest} do
      raise ArgumentError, "cached trajectory does not match the planned rollout slot"
    end

    rollout =
      new!(
        cycle: state.cycle,
        group_id: fetch_slot!(slot, :group_id),
        problem_id: problem_id,
        group_size: state.g,
        member_index: fetch_slot!(slot, :member_index),
        prompt_index: fetch_slot!(slot, :prompt_index),
        theta_id: cached.theta_id,
        prompt_revision: state.prompt_population.revision,
        dataset_indices: fetch_slot!(slot, :dataset_indices),
        input_digest: input_digest,
        prompt_digest: prompt_digest,
        behavior_policy_id: cached.theta_id,
        sampling_config_digest: state.sampling_config_digest,
        behavior_logprobs: cached.behavior_logprobs,
        response_token_ids: cached.response_token_ids,
        response_mask: cached.response_mask,
        source: :gepa_cache,
        generated_at_step: 0
      )

    claim_id = "gepa-cache:" <> cached.id
    {:ok, rollout} = claim(rollout, claim_id)
    complete!(rollout, claim_id, cached.output, cached.reward, %{"source" => "gepa_cache"})
  end

  @spec claim(t(), String.t()) :: {:ok, t()} | {:error, :already_claimed | :terminal}
  def claim(%__MODULE__{status: :available} = rollout, claim_id)
      when is_binary(claim_id) and claim_id != "" do
    {:ok, %{rollout | status: :claimed, claim_id: claim_id}}
  end

  def claim(%__MODULE__{status: :claimed, claim_id: claim_id} = rollout, claim_id),
    do: {:ok, rollout}

  def claim(%__MODULE__{status: :claimed}, claim_id) when is_binary(claim_id),
    do: {:error, :already_claimed}

  def claim(%__MODULE__{}, _claim_id), do: {:error, :terminal}

  @spec complete!(t(), String.t(), term(), number(), term()) :: t()
  def complete!(
        %__MODULE__{status: :claimed, claim_id: claim_id} = rollout,
        claim_id,
        output,
        score,
        metrics
      )
      when is_binary(claim_id) and is_number(score) do
    score = Config.json_safe!(score, [:rollout, :score])

    unless score >= 0 and score <= 1,
      do: raise(ArgumentError, "Fast-Slow verifier reward must be between zero and one")

    output = Config.json_safe!(output, [:rollout, :output])
    metrics = Config.json_safe!(metrics, [:rollout, :metrics])

    %{
      rollout
      | status: :complete,
        output: output,
        output_digest: Config.digest(output),
        score: score,
        metrics: metrics
    }
  end

  def complete!(%__MODULE__{}, _claim_id, _output, _score, _metrics),
    do: raise(ArgumentError, "rollout completion requires its current claim")

  @spec fail!(t(), String.t(), term()) :: t()
  def fail!(%__MODULE__{status: :claimed, claim_id: claim_id} = rollout, claim_id, failure) do
    %{rollout | status: :failed, failure: Config.json_safe!(failure, [:rollout, :failure])}
  end

  def fail!(%__MODULE__{}, _claim_id, _failure),
    do: raise(ArgumentError, "rollout failure requires its current claim")

  @spec reusable?(t(), non_neg_integer(), keyword() | map()) :: boolean()
  def reusable?(%__MODULE__{status: :complete} = rollout, cycle, identity)
      when is_integer(cycle) and (is_list(identity) or is_map(identity)) do
    identity = if is_list(identity), do: Map.new(identity), else: identity
    rollout.cycle == cycle and rollout.identity_digest == Config.digest(identity_from(identity))
  rescue
    ArgumentError -> false
  end

  def reusable?(%__MODULE__{}, _cycle, _identity), do: false

  @spec validate_complete_group!(
          [t()],
          String.t(),
          non_neg_integer(),
          pos_integer(),
          pos_integer() | nil
        ) :: [t()]
  def validate_complete_group!(rollouts, group_id, cycle, expected_size, prompt_count \\ nil)

  def validate_complete_group!(rollouts, group_id, cycle, expected_size, prompt_count)
      when is_list(rollouts) and is_binary(group_id) and is_integer(cycle) and
             is_integer(expected_size) and expected_size > 0 and
             (is_nil(prompt_count) or (is_integer(prompt_count) and prompt_count > 0)) do
    selected = Enum.filter(rollouts, &(&1.group_id == group_id and &1.cycle == cycle))
    indices = selected |> Enum.map(& &1.member_index) |> Enum.sort()

    prompt_count =
      prompt_count || selected |> Enum.map(& &1.prompt_index) |> Enum.uniq() |> length()

    allocation_valid =
      prompt_count > 0 and rem(expected_size, prompt_count) == 0 and
        selected
        |> Enum.frequencies_by(& &1.prompt_index)
        |> then(fn frequencies ->
          Map.keys(frequencies) |> Enum.sort() == Enum.to_list(0..(prompt_count - 1)) and
            Enum.all?(frequencies, fn {_index, count} ->
              count == div(expected_size, prompt_count)
            end)
        end)

    unless length(selected) == expected_size and indices == Enum.to_list(0..(expected_size - 1)) and
             Enum.all?(selected, &(&1.status == :complete and &1.group_size == expected_size)) and
             length(Enum.uniq_by(selected, & &1.id)) == expected_size and
             length(Enum.uniq_by(selected, & &1.problem_id)) == 1 and allocation_valid do
      raise ArgumentError, "rollout group #{inspect(group_id)} is incomplete or inconsistent"
    end

    Enum.sort_by(selected, & &1.member_index)
  end

  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = rollout) do
    identity = identity_from(Map.from_struct(rollout))
    expected_identity = Config.digest(identity)
    expected_id = Config.digest(%{"rollout" => expected_identity})

    valid =
      rollout.identity_digest == expected_identity and rollout.id == expected_id and
        rollout.status in @statuses and is_integer(rollout.cycle) and rollout.cycle >= 0 and
        is_binary(rollout.group_id) and rollout.group_id != "" and
        is_binary(rollout.problem_id) and rollout.problem_id != "" and
        is_integer(rollout.group_size) and rollout.group_size > 0 and
        is_integer(rollout.member_index) and rollout.member_index in 0..(rollout.group_size - 1) and
        is_integer(rollout.prompt_index) and rollout.prompt_index >= 0 and
        is_binary(rollout.theta_id) and rollout.theta_id != "" and
        is_integer(rollout.prompt_revision) and rollout.prompt_revision >= 0 and
        valid_indices?(rollout.dataset_indices) and digest?(rollout.input_digest) and
        digest?(rollout.prompt_digest) and
        rollout.behavior_policy_id == rollout.theta_id and
        digest?(rollout.sampling_config_digest) and valid_logprobs?(rollout.behavior_logprobs) and
        valid_token_alignment?(rollout) and rollout.source in [:live, :gepa_cache] and
        is_integer(rollout.generated_at_step) and rollout.generated_at_step >= 0 and
        valid_status_data?(rollout)

    unless valid, do: raise(ArgumentError, "rollout identity or state is invalid")
    rollout
  end

  defp identity_from(attrs) do
    %{
      "cycle" => Map.fetch!(attrs, :cycle),
      "group_id" => Map.fetch!(attrs, :group_id),
      "problem_id" => Map.fetch!(attrs, :problem_id),
      "group_size" => Map.fetch!(attrs, :group_size),
      "member_index" => Map.fetch!(attrs, :member_index),
      "prompt_index" => Map.fetch!(attrs, :prompt_index),
      "theta_id" => Map.fetch!(attrs, :theta_id),
      "prompt_revision" => Map.fetch!(attrs, :prompt_revision),
      "dataset_indices" => Map.fetch!(attrs, :dataset_indices),
      "input_digest" => Map.fetch!(attrs, :input_digest),
      "prompt_digest" => Map.fetch!(attrs, :prompt_digest),
      "behavior_policy_id" => Map.fetch!(attrs, :behavior_policy_id),
      "sampling_config_digest" => Map.fetch!(attrs, :sampling_config_digest),
      "behavior_logprobs" => Map.fetch!(attrs, :behavior_logprobs),
      "response_token_ids" => Map.fetch!(attrs, :response_token_ids),
      "response_mask" => Map.fetch!(attrs, :response_mask),
      "source" => attrs |> Map.fetch!(:source) |> Atom.to_string(),
      "generated_at_step" => Map.fetch!(attrs, :generated_at_step)
    }
    |> Config.json_safe!([:rollout, :identity])
  end

  defp valid_indices?(indices) when is_list(indices),
    do: indices != [] and Enum.all?(indices, &(is_integer(&1) and &1 >= 0))

  defp valid_indices?(_indices), do: false

  defp valid_logprobs?(values) when is_list(values),
    do: values != [] and Enum.all?(values, &is_number/1)

  defp valid_logprobs?(_values), do: false

  defp valid_token_alignment?(rollout) do
    values = [rollout.behavior_logprobs, rollout.response_token_ids, rollout.response_mask]

    if Enum.all?(values, &is_list/1) do
      lengths = Enum.map(values, &length/1)

      length(Enum.uniq(lengths)) == 1 and hd(lengths) > 0 and
        Enum.all?(rollout.response_token_ids, &(is_integer(&1) and &1 >= 0)) and
        Enum.all?(rollout.response_mask, &(&1 in [0, 1]))
    else
      false
    end
  end

  defp valid_status_data?(%__MODULE__{status: :available, claim_id: nil}), do: true

  defp valid_status_data?(%__MODULE__{status: :claimed, claim_id: id}),
    do: is_binary(id) and id != ""

  defp valid_status_data?(%__MODULE__{status: :complete} = rollout) do
    is_binary(rollout.claim_id) and digest?(rollout.output_digest) and is_number(rollout.score) and
      rollout.output_digest == Config.digest(rollout.output)
  end

  defp valid_status_data?(%__MODULE__{status: :failed} = rollout),
    do: is_binary(rollout.claim_id) and not is_nil(rollout.failure)

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp fetch_slot!(slot, key) do
    case Map.fetch(slot, key) do
      {:ok, value} -> value
      :error -> Map.fetch!(slot, Atom.to_string(key))
    end
  end
end

defmodule DSEx.Training.FastSlow.AdvantageGroup do
  @moduledoc false

  alias DSEx.Training.FastSlow.{Config, Rollout}

  @enforce_keys [
    :id,
    :cycle,
    :problem_id,
    :size,
    :prompt_count,
    :mean_reward,
    :std_reward,
    :epsilon,
    :members
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          cycle: non_neg_integer(),
          problem_id: String.t(),
          size: pos_integer(),
          prompt_count: pos_integer(),
          mean_reward: float(),
          std_reward: float(),
          epsilon: float(),
          members: [map()]
        }

  @doc "Builds one question-level advantage group across every prompt allocation."
  @spec new!([Rollout.t()], String.t(), non_neg_integer(), pos_integer(), pos_integer(), float()) ::
          t()
  def new!(rollouts, group_id, cycle, group_size, prompt_count, epsilon \\ 1.0e-6)

  def new!(rollouts, group_id, cycle, group_size, prompt_count, epsilon)
      when is_list(rollouts) and is_binary(group_id) and is_integer(cycle) and cycle >= 0 and
             is_integer(group_size) and group_size > 0 and is_integer(prompt_count) and
             prompt_count > 0 and is_float(epsilon) and epsilon > 0 do
    selected =
      Rollout.validate_complete_group!(rollouts, group_id, cycle, group_size, prompt_count)

    rewards = Enum.map(selected, &(&1.score * 1.0))
    mean = Enum.sum(rewards) / group_size
    variance = Enum.reduce(rewards, 0.0, &(&2 + :math.pow(&1 - mean, 2))) / group_size
    std = :math.sqrt(variance)

    members =
      Enum.map(selected, fn rollout ->
        %{
          "rollout_id" => rollout.id,
          "member_index" => rollout.member_index,
          "prompt_index" => rollout.prompt_index,
          "reward" => rollout.score,
          "advantage" => (rollout.score - mean) / (std + epsilon),
          "behavior_policy_id" => rollout.behavior_policy_id,
          "behavior_logprobs" => rollout.behavior_logprobs,
          "response_token_ids" => rollout.response_token_ids,
          "response_mask" => rollout.response_mask,
          "source" => Atom.to_string(rollout.source)
        }
      end)

    %__MODULE__{
      id: group_id,
      cycle: cycle,
      problem_id: hd(selected).problem_id,
      size: group_size,
      prompt_count: prompt_count,
      mean_reward: mean,
      std_reward: std,
      epsilon: epsilon,
      members: members
    }
  end

  def new!(_rollouts, _group_id, _cycle, _group_size, _prompt_count, _epsilon) do
    raise ArgumentError, "invalid Fast-Slow advantage group configuration"
  end

  @doc "Returns a deterministic JSON-safe representation for provider training boundaries."
  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = group), do: Config.json_safe!(Map.from_struct(group))
end
