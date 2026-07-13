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
    :behavior_policy_id,
    :sampling_config_digest,
    :behavior_logprobs
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
          behavior_policy_id: String.t(),
          sampling_config_digest: String.t(),
          behavior_logprobs: [number()],
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
      :behavior_policy_id,
      :sampling_config_digest,
      :behavior_logprobs
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
        is_binary(rollout.behavior_policy_id) and rollout.behavior_policy_id != "" and
        digest?(rollout.sampling_config_digest) and valid_logprobs?(rollout.behavior_logprobs) and
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
      "behavior_policy_id" => Map.fetch!(attrs, :behavior_policy_id),
      "sampling_config_digest" => Map.fetch!(attrs, :sampling_config_digest),
      "behavior_logprobs" => Map.fetch!(attrs, :behavior_logprobs)
    }
    |> Config.json_safe!([:rollout, :identity])
  end

  defp valid_indices?(indices) when is_list(indices),
    do: indices != [] and Enum.all?(indices, &(is_integer(&1) and &1 >= 0))

  defp valid_indices?(_indices), do: false

  defp valid_logprobs?(values) when is_list(values),
    do: values != [] and Enum.all?(values, &is_number/1)

  defp valid_logprobs?(_values), do: false

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
end
