defmodule Imp.Optimize.Anything.TrackingTest do
  use ExUnit.Case, async: false

  alias Imp.Optimize.Anything
  alias Imp.Optimize.Anything.Config
  alias Imp.Test.LocalHTTP

  test "runner records a complete MLflow lifecycle over HTTP" do
    tracking_uri = start_mlflow(self())

    result =
      Anything.run(
        "tracked",
        fn _candidate -> 0.75 end,
        config: config(tracking_uri),
        fallback_proposer: &same_component/4
      )

    assert result.validation_scores == [0.75]
    assert_receive {:mlflow, %{method: "GET", path: path}}
    assert path =~ "/experiments/get-by-name"
    assert_receive {:mlflow, %{method: "POST", path: path}}
    assert path =~ "/runs/create"

    assert_receive {:mlflow, %{body: config_body}}
    assert Jason.decode!(config_body)["params"] != []

    assert_receive {:mlflow, %{body: metrics_body}}
    metrics = Jason.decode!(metrics_body)["metrics"]
    assert Enum.any?(metrics, &(&1["key"] == "validation_score" and &1["value"] == 0.75))

    assert_receive {:mlflow, %{body: summary_body}}
    assert Jason.decode!(summary_body)["tags"] != []

    assert_receive {:mlflow, %{path: update_path, body: finish_body}}
    assert update_path =~ "/runs/update"
    assert Jason.decode!(finish_body)["status"] == "FINISHED"
  end

  test "runner marks MLflow failed when seed evaluation raises" do
    tracking_uri = start_mlflow(self())

    assert_raise RuntimeError, "evaluation failed", fn ->
      Anything.run(
        "tracked",
        fn _candidate -> raise "evaluation failed" end,
        config: config(tracking_uri),
        fallback_proposer: &same_component/4
      )
    end

    assert_receive {:mlflow, %{path: path}}
    assert path =~ "/experiments/get-by-name"
    assert_receive {:mlflow, %{path: path}}
    assert path =~ "/runs/create"
    assert_receive {:mlflow, %{body: config_body}}
    assert Jason.decode!(config_body)["params"] != []
    assert_receive {:mlflow, %{path: update_path, body: finish_body}}
    assert update_path =~ "/runs/update"
    assert Jason.decode!(finish_body)["status"] == "FAILED"
  end

  defp config(tracking_uri) do
    Config.new(
      engine: [max_candidate_proposals: 0],
      tracking: [
        use_mlflow: true,
        mlflow_tracking_uri: tracking_uri,
        mlflow_experiment_name: "imp-test"
      ]
    )
  end

  defp same_component(candidate, component, _records, _iteration),
    do: Map.fetch!(candidate, component)

  defp start_mlflow(receiver) do
    LocalHTTP.start(fn request ->
      send(receiver, {:mlflow, request})

      cond do
        request.path =~ "/experiments/get-by-name" ->
          {200, %{"experiment" => %{"experiment_id" => "17"}}}

        request.path =~ "/runs/create" ->
          {200,
           %{
             "run" => %{
               "info" => %{
                 "run_id" => "run-1",
                 "experiment_id" => "17",
                 "artifact_uri" => nil
               }
             }
           }}

        true ->
          {200, %{}}
      end
    end)
  end
end
