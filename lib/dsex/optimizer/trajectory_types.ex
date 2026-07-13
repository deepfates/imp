defmodule DSEx.Optimizer.Trajectory.Event do
  @moduledoc "A single ordered, provider-neutral optimizer execution event."

  @enforce_keys [:sequence, :kind]
  defstruct [
    :sequence,
    :kind,
    :component,
    :input,
    :output,
    :reasoning,
    :tool_call_id,
    :tool_name,
    :error,
    :started_at_us,
    :duration_us,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          sequence: non_neg_integer(),
          kind: atom() | String.t(),
          component: atom() | String.t() | nil,
          input: term(),
          output: term(),
          reasoning: term(),
          tool_call_id: String.t() | nil,
          tool_name: atom() | String.t() | nil,
          error: term(),
          started_at_us: non_neg_integer() | nil,
          duration_us: non_neg_integer() | nil,
          metadata: map()
        }
end

defmodule DSEx.Optimizer.Trajectory.Usage do
  @moduledoc "Provider-neutral token, request, and cost accounting."

  defstruct input_tokens: 0,
            output_tokens: 0,
            total_tokens: 0,
            requests: 0,
            cost: nil,
            currency: nil,
            metadata: %{}

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          requests: non_neg_integer(),
          cost: number() | nil,
          currency: String.t() | nil,
          metadata: map()
        }
end

defmodule DSEx.Optimizer.Trajectory.Timing do
  @moduledoc "Wall-clock and monotonic duration information for a trajectory."

  defstruct [:started_at, :finished_at, duration_us: nil]

  @type t :: %__MODULE__{
          started_at: String.t() | nil,
          finished_at: String.t() | nil,
          duration_us: non_neg_integer() | nil
        }
end

defmodule DSEx.Optimizer.Trajectory.Cache do
  @moduledoc "Stable cache identity and whether the execution was reused."

  @enforce_keys [:key]
  defstruct [:key, hit: false, namespace: nil, metadata: %{}]

  @type t :: %__MODULE__{
          key: String.t(),
          hit: boolean(),
          namespace: String.t() | nil,
          metadata: map()
        }
end

defmodule DSEx.Optimizer.Trajectory.Parameter do
  @moduledoc "A named program parameter snapshot without optimizer-specific flattening."

  @enforce_keys [:name, :kind, :value]
  defstruct [:name, :kind, :value, metadata: %{}]

  @type t :: %__MODULE__{
          name: atom() | String.t(),
          kind: atom() | String.t(),
          value: term(),
          metadata: map()
        }
end

defmodule DSEx.Optimizer.Trajectory.Failure do
  @moduledoc "A typed runtime or evaluator failure."

  @enforce_keys [:kind, :message]
  defstruct [:kind, :message, :details, retryable: false]

  @type t :: %__MODULE__{
          kind: atom() | String.t(),
          message: String.t(),
          details: term(),
          retryable: boolean()
        }
end

defmodule DSEx.Optimizer.Trajectory.DecodeError do
  @moduledoc "A fail-closed trajectory decoding or validation error."

  defexception [:message, :path]

  @type t :: %__MODULE__{message: String.t(), path: [String.t()] | nil}
end
