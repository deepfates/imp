defmodule LiveTrainingGateContractTest do
  use ExUnit.Case, async: true

  @moduletag :live_training

  test "live training gate is explicit because it may create provider-side state" do
    assert System.get_env("LIVE_TRAINING") in [nil, "0", "1"]
  end
end
