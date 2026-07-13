defmodule DSEx.Observability.Status do
  @moduledoc """
  Normalized status for long-running DSEx work.

  The artifact is ordinary immutable data suitable for terminal UIs, LiveViews,
  telemetry consumers, and tests. `completed` and `total` are optional because
  some providers expose a phase before they expose a work estimate.
  """

  @enforce_keys [:state, :phase, :message, :metadata]
  defstruct [:state, :phase, :completed, :total, :message, :metadata]

  @type t :: %__MODULE__{
          state: :pending | :running | :succeeded | :failed | :cancelled | :unknown,
          phase: atom() | String.t(),
          completed: non_neg_integer() | nil,
          total: non_neg_integer() | nil,
          message: String.t(),
          metadata: map()
        }
end
