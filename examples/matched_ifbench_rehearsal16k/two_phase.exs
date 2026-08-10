defmodule MatchedIFBenchR16k.TwoPhase do
  @moduledoc false

  @doc "Runs and durably seals every selection before the held-out loader is invoked."
  def seal_then_load_held_out!(work_items, compile_and_seal, persist_selections, load_held_out)
      when is_list(work_items) and is_function(compile_and_seal, 1) and
             is_function(persist_selections, 1) and is_function(load_held_out, 0) do
    sealed = Enum.map(work_items, compile_and_seal)
    :ok = persist_selections.(sealed)
    {sealed, load_held_out.()}
  end
end
