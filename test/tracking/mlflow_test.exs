defmodule DSEx.Tracking.MLflowTest do
  use ExUnit.Case, async: false

  alias DSEx.Tracking.MLflow

  defmodule RecordingTransport do
    @behaviour DSEx.Tracking.Transport

    @impl true
    def request(method, url, headers, body, opts) do
      owner = Process.get({__MODULE__, :owner})
      send(owner, {:request, method, url, headers, IO.iodata_to_binary(body), opts})

      case Process.get({__MODULE__, :responses}, []) do
        [response | rest] ->
          Process.put({__MODULE__, :responses}, rest)
          response

        [] ->
          {:error, :no_recorded_response}
      end
    end
  end

  setup do
    Process.put({RecordingTransport, :owner}, self())
    Process.delete({RecordingTransport, :responses})
    :ok
  end

  test "gets an experiment and creates an owned run with bearer auth" do
    respond([
      json(200, %{"experiment" => %{"experiment_id" => "17"}}),
      json(200, run_response("run-1", "17", "mlflow-artifacts:/17/run-1/artifacts"))
    ])

    assert {:ok, state} =
             MLflow.start(
               tracking_uri: "https://mlflow.example/",
               experiment_name: "optimize",
               run_name: "trial-4",
               start_time: 1_234,
               tags: %{team: "research"},
               token: "secret-token",
               transport: RecordingTransport,
               transport_opts: [receive_timeout: 500]
             )

    assert state.owned_run
    assert state.run_id == "run-1"

    assert_request(
      :get,
      "https://mlflow.example/api/2.0/mlflow/experiments/get-by-name?experiment_name=optimize",
      "",
      "Bearer secret-token",
      receive_timeout: 500
    )

    assert_receive {:request, :post, "https://mlflow.example/api/2.0/mlflow/runs/create", headers,
                    body, [receive_timeout: 500]}

    assert {"authorization", "Bearer secret-token"} in headers

    assert Jason.decode!(body) == %{
             "experiment_id" => "17",
             "run_name" => "trial-4",
             "start_time" => 1_234,
             "tags" => [%{"key" => "team", "value" => "research"}]
           }
  end

  test "recovers when another client creates the missing experiment first" do
    respond([
      json(404, %{"error_code" => "RESOURCE_DOES_NOT_EXIST"}),
      json(400, %{"error_code" => "RESOURCE_ALREADY_EXISTS"}),
      json(200, %{"experiment" => %{"experiment_id" => "9"}}),
      json(200, run_response("race-run", "9", nil))
    ])

    assert {:ok, %{experiment_id: "9"}} =
             MLflow.start(
               tracking_uri: "http://localhost:5000",
               experiment_name: "race",
               start_time: 10,
               transport: RecordingTransport
             )

    assert_receive {:request, :get, url1, _, "", _}
    assert url1 =~ "/experiments/get-by-name?experiment_name=race"
    assert_receive {:request, :post, url2, _, create_body, _}
    assert url2 =~ "/experiments/create"
    assert Jason.decode!(create_body) == %{"name" => "race"}
    assert_receive {:request, :get, url3, _, "", _}
    assert url3 == url1
    assert_receive {:request, :post, url4, _, _, _}
    assert url4 =~ "/runs/create"
  end

  test "adopts a run with basic auth and leaves it active by default" do
    respond([
      json(200, run_response("adopted", "3", "mlflow-artifacts:/3/adopted/artifacts"))
    ])

    assert {:ok, state} =
             MLflow.start(
               tracking_uri: "http://mlflow.internal",
               run_id: "adopted",
               username: "alice",
               password: "p@ss",
               transport: RecordingTransport
             )

    refute state.owned_run

    assert_request(
      :get,
      "http://mlflow.internal/api/2.0/mlflow/runs/get?run_id=adopted",
      "",
      "Basic " <> Base.encode64("alice:p@ss"),
      []
    )

    assert :ok = MLflow.finish(state, :failed)
    refute_receive {:request, _, _, _, _, _}
  end

  test "logs config, metrics, and summary through log-batch" do
    state = adopted_state()

    respond([json(200, %{}), json(200, %{}), json(200, %{})])

    assert :ok = MLflow.log_config(state, %{model: "gpt", trials: 4})

    assert_batch(%{
      "run_id" => "run-1",
      "metrics" => [],
      "params" => [
        %{"key" => "model", "value" => "gpt"},
        %{"key" => "trials", "value" => "4"}
      ],
      "tags" => []
    })

    assert :ok = MLflow.log_metrics(state, %{loss: 0.25, score: 9}, timestamp: 500, step: 2)

    assert_batch(%{
      "run_id" => "run-1",
      "metrics" => [
        %{"key" => "loss", "value" => 0.25, "timestamp" => 500, "step" => 2},
        %{"key" => "score", "value" => 9, "timestamp" => 500, "step" => 2}
      ],
      "params" => [],
      "tags" => []
    })

    assert :ok = MLflow.log_summary(state, %{best: 0.9, winner: "candidate-2"})

    assert_batch(%{
      "run_id" => "run-1",
      "metrics" => [],
      "params" => [],
      "tags" => [
        %{"key" => "dsex.summary.best", "value" => "0.9"},
        %{"key" => "dsex.summary.winner", "value" => "candidate-2"}
      ]
    })
  end

  test "finishes an owned run with the mapped MLflow status" do
    state = %{adopted_state() | owned_run: true}
    respond([json(200, %{})])

    assert :ok = MLflow.finish(state, :failed)

    assert_receive {:request, :post, url, _, body, _}
    assert url =~ "/runs/update"
    decoded = Jason.decode!(body)
    assert decoded["run_id"] == "run-1"
    assert decoded["status"] == "FAILED"
    assert is_integer(decoded["end_time"])
  end

  test "uploads and appends split JSON tables through the artifact proxy" do
    state = adopted_state()

    respond([
      json(200, %{"columns" => ["input", "score"], "data" => [["old", 0.2]]}),
      %{status: 200, headers: [], body: ""} |> then(&{:ok, &1}),
      json(200, %{
        "run" => %{
          "data" => %{
            "tags" => [
              %{
                "key" => "mlflow.loggedArtifacts",
                "value" => Jason.encode!([%{"path" => "other.json", "type" => "table"}])
              }
            ]
          }
        }
      }),
      json(200, %{})
    ])

    assert :ok =
             MLflow.log_table(state, "tables/eval results.json", [
               %{input: "new", note: "accepted", score: 0.8}
             ])

    artifact_url =
      "https://mlflow.example/api/2.0/mlflow-artifacts/artifacts/17/run-1/artifacts/tables/eval%20results.json"

    assert_receive {:request, :get, ^artifact_url, [], "", []}
    assert_receive {:request, :put, ^artifact_url, headers, artifact_body, []}
    assert {"content-type", "application/json"} in headers

    assert Jason.decode!(artifact_body) == %{
             "columns" => ["input", "score", "note"],
             "data" => [["old", 0.2, nil], ["new", 0.8, "accepted"]]
           }

    assert_receive {:request, :get, run_url, _, "", []}
    assert run_url =~ "/runs/get?run_id=run-1"
    assert_receive {:request, :post, batch_url, _, tag_body, []}
    assert batch_url =~ "/runs/log-batch"

    [tag] = Jason.decode!(tag_body)["tags"]
    assert tag["key"] == "mlflow.loggedArtifacts"

    assert Jason.decode!(tag["value"]) == [
             %{"path" => "other.json", "type" => "table"},
             %{"path" => "tables/eval results.json", "type" => "table"}
           ]
  end

  test "rejects unsupported tracking and artifact URI schemes" do
    assert {:error, {:unsupported_tracking_uri, "file:///tmp/mlruns"}} =
             MLflow.start(tracking_uri: "file:///tmp/mlruns", transport: RecordingTransport)

    state = %{adopted_state() | artifact_uri: "s3://bucket/run-1/artifacts"}

    assert {:error, {:unsupported_artifact_uri_scheme, "s3"}} =
             MLflow.log_artifact(state, "result.json", "{}", "application/json")

    refute_receive {:request, _, _, _, _, _}
  end

  test "artifact proxy uploads stay on the configured tracking origin" do
    state = %{
      adopted_state()
      | artifact_uri: "mlflow-artifacts://attacker.example/17/run-1/artifacts"
    }

    respond([{:ok, %{status: 200, headers: [], body: ""}}])

    assert :ok = MLflow.log_artifact(state, "result.json", "{}", "application/json")

    assert_receive {:request, :put, url, _, "{}", []}
    assert URI.parse(url).host == "mlflow.example"
    refute url =~ "attacker.example"

    assert {:error, {:invalid_artifact_path, "/"}} =
             MLflow.log_artifact(state, "/", "{}", "application/json")

    traversing = %{state | artifact_uri: "mlflow-artifacts:/17/../admin"}

    assert {:error, {:invalid_artifact_path, "/17/../admin"}} =
             MLflow.log_artifact(traversing, "result.json", "{}", "application/json")

    refute_receive {:request, _, _, _, _, _}
  end

  defp adopted_state do
    %MLflow{
      tracking_uri: "https://mlflow.example",
      transport: RecordingTransport,
      transport_opts: [],
      headers: [],
      run_id: "run-1",
      experiment_id: "17",
      artifact_uri: "mlflow-artifacts:/17/run-1/artifacts",
      owned_run: false,
      finish_adopted_run: false
    }
  end

  defp run_response(run_id, experiment_id, artifact_uri) do
    %{
      "run" => %{
        "info" => %{
          "run_id" => run_id,
          "experiment_id" => experiment_id,
          "artifact_uri" => artifact_uri
        }
      }
    }
  end

  defp respond(responses), do: Process.put({RecordingTransport, :responses}, responses)

  defp json(status, body),
    do:
      {:ok,
       %{
         status: status,
         headers: [{"content-type", "application/json"}],
         body: Jason.encode!(body)
       }}

  defp assert_request(method, url, body, authorization, opts) do
    assert_receive {:request, ^method, ^url, headers, ^body, ^opts}
    assert {"authorization", authorization} in headers
    assert {"content-type", "application/json"} in headers
  end

  defp assert_batch(expected) do
    assert_receive {:request, :post, url, _, body, []}
    assert url =~ "/runs/log-batch"
    assert Jason.decode!(body) == expected
  end
end
