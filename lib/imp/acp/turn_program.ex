defmodule Imp.ACP.TurnProgram do
  @moduledoc false
  @behaviour Imp.Module
  defstruct [:program, :lifecycle]

  # Preparation belongs to the cancellable execution task, not the session's
  # mailbox. Keep the original program in session state for history and cleanup.
  @impl true
  def call(turn, inputs) do
    with :ok <- Imp.ACP.Options.before_turn(turn.lifecycle) do
      Imp.Module.call(turn.program, inputs)
    end
  end

  @impl true
  def execute(turn, inputs, execution) do
    with :ok <- Imp.ACP.Options.before_turn(turn.lifecycle) do
      Imp.Module.execute(turn.program, inputs, execution)
    end
  end
end
