defmodule Imp.Tracking.Backend do
  @moduledoc "Lifecycle contract implemented by experiment tracking backends."

  @type event :: term()
  @type status :: :finished | :success | :failed | :failure | :killed | :cancelled

  @callback start(keyword()) :: {:ok, term()} | {:error, term()}
  @callback log(term(), event()) :: :ok | {:error, term()}
  @callback finish(term(), status()) :: :ok | {:error, term()}
end
