defmodule DSExDoctestTest do
  use ExUnit.Case, async: true

  doctest DSEx.Adapter.JSON
  doctest DSEx.Evaluate
  doctest DSEx.Optimizer.RandomSearch
  doctest DSEx.Tool
end
