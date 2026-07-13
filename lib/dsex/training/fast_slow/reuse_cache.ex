defmodule DSEx.Training.FastSlow.CachedTrajectory do
  @moduledoc false

  alias DSEx.Training.FastSlow.Config

  @enforce_keys [
    :id,
    :cycle,
    :theta_id,
    :problem_id,
    :input_digest,
    :prompt_digest,
    :output,
    :reward,
    :response_token_ids,
    :response_mask,
    :behavior_logprobs
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          cycle: non_neg_integer(),
          theta_id: String.t(),
          problem_id: String.t(),
          input_digest: String.t(),
          prompt_digest: String.t(),
          output: Config.json_value(),
          reward: number(),
          response_token_ids: [non_neg_integer()],
          response_mask: [0 | 1],
          behavior_logprobs: [number()]
        }

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = if is_list(attrs), do: Map.new(attrs), else: attrs
    attrs = Map.update(attrs, :output, nil, &Config.persisted_safe!/1)
    payload = Map.take(attrs, required_payload_keys()) |> Config.persisted_safe!()
    id = Config.digest(payload)

    trajectory = struct!(__MODULE__, Map.put(attrs, :id, id))
    validate!(trajectory)
  end

  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = trajectory) do
    valid =
      trajectory.id == Config.digest(payload(trajectory)) and is_integer(trajectory.cycle) and
        trajectory.cycle >= 0 and
        digest?(trajectory.theta_id) and non_empty?(trajectory.problem_id) and
        digest?(trajectory.input_digest) and digest?(trajectory.prompt_digest) and
        is_number(trajectory.reward) and trajectory.reward >= 0 and trajectory.reward <= 1 and
        aligned_tokens?(trajectory)

    unless valid, do: raise(ArgumentError, "cached Fast-Slow trajectory is invalid")
    Config.persisted_safe!(payload(trajectory))
    trajectory
  end

  @doc false
  def dump(%__MODULE__{} = trajectory),
    do: Map.from_struct(trajectory) |> Config.persisted_safe!()

  @doc false
  def load!(state) when is_map(state) do
    expected =
      ~w(behavior_logprobs cycle id input_digest output problem_id prompt_digest response_mask response_token_ids reward theta_id)

    unless Enum.sort(Map.keys(state)) == Enum.sort(expected),
      do: raise(ArgumentError, "cached Fast-Slow trajectory keys are invalid")

    trajectory =
      new!(
        cycle: state["cycle"],
        theta_id: state["theta_id"],
        problem_id: state["problem_id"],
        input_digest: state["input_digest"],
        prompt_digest: state["prompt_digest"],
        output: state["output"],
        reward: state["reward"],
        response_token_ids: state["response_token_ids"],
        response_mask: state["response_mask"],
        behavior_logprobs: state["behavior_logprobs"]
      )

    unless trajectory.id == state["id"],
      do: raise(ArgumentError, "cached Fast-Slow trajectory identity is invalid")

    trajectory
  end

  defp payload(trajectory),
    do: trajectory |> Map.from_struct() |> Map.drop([:id]) |> Config.persisted_safe!()

  defp required_payload_keys do
    [
      :cycle,
      :theta_id,
      :problem_id,
      :input_digest,
      :prompt_digest,
      :output,
      :reward,
      :response_token_ids,
      :response_mask,
      :behavior_logprobs
    ]
  end

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp non_empty?(value), do: is_binary(value) and value != ""

  defp aligned_tokens?(trajectory) do
    values = [
      trajectory.response_token_ids,
      trajectory.response_mask,
      trajectory.behavior_logprobs
    ]

    if Enum.all?(values, &is_list/1) do
      lengths = Enum.map(values, &length/1)

      length(Enum.uniq(lengths)) == 1 and hd(lengths) > 0 and
        Enum.all?(trajectory.response_token_ids, &(is_integer(&1) and &1 >= 0)) and
        Enum.all?(trajectory.response_mask, &(&1 in [0, 1])) and
        Enum.all?(trajectory.behavior_logprobs, &is_number/1)
    else
      false
    end
  end
end

defmodule DSEx.Training.FastSlow.ReuseCache do
  @moduledoc false

  alias DSEx.Training.FastSlow.{CachedTrajectory, Config}

  @enforce_keys [:cycle, :theta_id, :entries]
  defstruct @enforce_keys

  @type key :: {String.t(), String.t(), String.t()}
  @type t :: %__MODULE__{
          cycle: non_neg_integer(),
          theta_id: String.t(),
          entries: %{key() => [CachedTrajectory.t()]}
        }

  @spec new!(non_neg_integer(), String.t(), [CachedTrajectory.t()]) :: t()
  def new!(cycle, theta_id, trajectories \\ [])

  def new!(cycle, theta_id, trajectories)
      when is_integer(cycle) and cycle >= 0 and is_binary(theta_id) and is_list(trajectories) do
    unless Regex.match?(~r/\A[0-9a-f]{64}\z/, theta_id),
      do: raise(ArgumentError, "reuse cache theta must be a SHA-256 policy identity")

    entries =
      trajectories
      |> Enum.map(&CachedTrajectory.validate!/1)
      |> Enum.map(fn trajectory ->
        unless trajectory.cycle == cycle and trajectory.theta_id == theta_id,
          do: raise(ArgumentError, "cached trajectory does not match cache policy generation")

        trajectory
      end)
      |> Enum.group_by(&key/1)
      |> Map.new(fn {key, values} -> {key, Enum.sort_by(values, & &1.id)} end)

    %__MODULE__{cycle: cycle, theta_id: theta_id, entries: entries}
  end

  @doc "Claims one exact GEPA trajectory for an RL `(problem, prompt)` slot."
  @spec claim(t(), String.t(), String.t(), String.t()) ::
          {:ok, CachedTrajectory.t(), t()} | :miss
  def claim(%__MODULE__{} = cache, problem_id, input_digest, prompt_digest) do
    key = {problem_id, input_digest, prompt_digest}

    case Map.get(cache.entries, key, []) do
      [trajectory | rest] ->
        entries =
          if rest == [],
            do: Map.delete(cache.entries, key),
            else: Map.put(cache.entries, key, rest)

        {:ok, trajectory, %{cache | entries: entries}}

      [] ->
        :miss
    end
  end

  @doc "Clears all prior GEPA samples when a new fast cycle starts."
  @spec next_cycle(t(), non_neg_integer(), String.t()) :: t()
  def next_cycle(%__MODULE__{}, cycle, theta_id), do: new!(cycle, theta_id)

  @doc false
  def dump(%__MODULE__{} = cache) do
    %{
      "cycle" => cache.cycle,
      "theta_id" => cache.theta_id,
      "entries" =>
        cache.entries
        |> Map.values()
        |> List.flatten()
        |> Enum.sort_by(& &1.id)
        |> Enum.map(&CachedTrajectory.dump/1)
    }
  end

  @doc false
  def load!(%{"cycle" => cycle, "theta_id" => theta_id, "entries" => entries} = state)
      when map_size(state) == 3 and is_list(entries) do
    new!(cycle, theta_id, Enum.map(entries, &CachedTrajectory.load!/1))
  end

  @doc false
  def validate!(%__MODULE__{} = cache) do
    trajectories = cache.entries |> Map.values() |> List.flatten()
    expected = new!(cache.cycle, cache.theta_id, trajectories)
    unless expected == cache, do: raise(ArgumentError, "Fast-Slow reuse cache is invalid")
    cache
  end

  defp key(trajectory),
    do: {trajectory.problem_id, trajectory.input_digest, trajectory.prompt_digest}
end
