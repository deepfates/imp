defmodule LiveTrainingGateContractTest do
  use ExUnit.Case, async: true

  @moduletag :live_training

  test "live training alias is reserved until real provider-side tests are configured" do
    assert System.get_env("LIVE_TRAINING") in [nil, "0", "1"]
  end
end
