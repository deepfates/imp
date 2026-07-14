defmodule Imp.Tracking.WandBClientTest do
  use ExUnit.Case, async: true

  alias Imp.Tracking.WandB
  alias Imp.Tracking.WandB.Backend

  defp transport(test_pid, opts \\ []) do
    inserted = Keyword.get(opts, :inserted, true)
    history_line_count = Keyword.get(opts, :history_line_count, 0)

    fn method, url, headers, body, request_opts ->
      decoded = decode_if_json(body)
      send(test_pid, {:wandb_request, method, url, headers, body, decoded, request_opts})

      cond do
        method == :put ->
          {:ok, %{status: 200, body: "", headers: []}}

        String.ends_with?(url, "/graphql") ->
          graphql_response(decoded, inserted, history_line_count)

        String.ends_with?(url, "/file_stream") ->
          {:ok, %{status: 200, body: "{}", headers: []}}
      end
    end
  end

  defp graphql_response(%{"operationName" => "Viewer"}, _inserted, _offset) do
    json_response(%{"data" => %{"viewer" => %{"id" => "viewer-1", "entity" => "viewer-team"}}})
  end

  defp graphql_response(%{"operationName" => "UpsertBucket"}, inserted, offset) do
    json_response(%{
      "data" => %{
        "upsertBucket" => %{
          "bucket" => %{
            "id" => "storage-1",
            "name" => "run-123",
            "displayName" => "display",
            "historyLineCount" => offset,
            "project" => %{"name" => "proj", "entity" => %{"name" => "team"}}
          },
          "inserted" => inserted
        }
      }
    })
  end

  defp graphql_response(
         %{"operationName" => "CreateRunFiles", "variables" => %{"files" => [path]}},
         _inserted,
         _offset
       ) do
    json_response(%{
      "data" => %{
        "createRunFiles" => %{
          "runID" => "storage-1",
          "uploadHeaders" => ["x-amz-meta-test: signed", "content-type:text/plain"],
          "files" => [%{"name" => path, "uploadUrl" => "https://uploads.example/#{path}"}]
        }
      }
    })
  end

  defp json_response(value),
    do: {:ok, %{status: 200, body: Jason.encode!(value), headers: []}}

  defp decode_if_json(body) do
    case Jason.decode(body) do
      {:ok, value} -> value
      {:error, _error} -> nil
    end
  end

  defp initialized_client(test_pid, constructor_opts \\ [], init_opts \\ []) do
    client =
      WandB.new(
        [transport: transport(test_pid), api_key: "secret", request_opts: [timeout: 321]] ++
          constructor_opts
      )

    defaults = [entity: "team", project: "proj", id: "run-123", name: "display"]
    {:ok, client} = WandB.init(client, Keyword.merge(defaults, init_opts))
    client
  end

  defp discard_init_requests do
    assert_receive {:wandb_request, :post, "https://api.wandb.ai/graphql", _, _, _, _}
    assert_receive {:wandb_request, :post, "https://api.wandb.ai/graphql", _, _, _, _}
  end

  test "strict constructor supports Basic and Bearer auth and rejects passthrough" do
    basic = WandB.new(transport: transport(self()), api_key: "abc")
    bearer = WandB.new(transport: transport(self()), bearer_token: "token")

    assert basic.authorization == "Basic YXBpOmFiYw=="
    assert bearer.authorization == "Bearer token"

    assert_raise ArgumentError, ~r/exactly one/, fn ->
      WandB.new(transport: transport(self()), api_key: "abc", bearer_token: "token")
    end

    assert_raise ArgumentError, ~r/unsupported options: \[:mode\]/, fn ->
      WandB.new(transport: transport(self()), api_key: "abc", mode: :online)
    end
  end

  test "init verifies Viewer then records the exact UpsertBucket request" do
    client =
      WandB.new(
        transport: transport(self()),
        api_key: "secret",
        request_opts: [timeout: 321]
      )

    assert {:ok, run} =
             WandB.init(client,
               project: "proj",
               id: "run-123",
               name: "display",
               group: "batch-a",
               job_type: "optimize",
               tags: ["gepa", "elixir"],
               notes: "recorded",
               resume: :allow,
               base_url: "https://api.wandb.ai/"
             )

    assert run.entity == "viewer-team"
    assert run.storage_id == "storage-1"
    assert run.history_offset == 0

    basic = "Basic " <> Base.encode64("api:secret")

    assert_receive {:wandb_request, :post, "https://api.wandb.ai/graphql", viewer_headers,
                    _viewer_raw,
                    %{
                      "operationName" => "Viewer",
                      "query" => viewer_query,
                      "variables" => %{}
                    }, [timeout: 321]}

    assert {"Authorization", basic} in viewer_headers
    assert {"Content-Type", "application/json"} in viewer_headers
    assert viewer_query =~ "query Viewer"

    assert_receive {:wandb_request, :post, "https://api.wandb.ai/graphql", upsert_headers,
                    _upsert_raw,
                    %{
                      "operationName" => "UpsertBucket",
                      "query" => upsert_query,
                      "variables" => variables
                    }, [timeout: 321]}

    assert {"Authorization", basic} in upsert_headers
    assert upsert_query =~ "mutation UpsertBucket"

    assert variables == %{
             "displayName" => "display",
             "entity" => "viewer-team",
             "groupName" => "batch-a",
             "id" => nil,
             "jobType" => "optimize",
             "name" => "run-123",
             "notes" => "recorded",
             "project" => "proj",
             "state" => "running",
             "tags" => ["gepa", "elixir"]
           }
  end

  test "init accepts only the documented init options" do
    client = WandB.new(transport: transport(self()), api_key: "secret")

    assert_raise ArgumentError, ~r/unsupported options: \[:config\]/, fn ->
      WandB.init(client, project: "proj", config: %{lr: 0.1})
    end

    assert_raise ArgumentError, ~r/unsupported option: "reinit"/, fn ->
      WandB.init(client, %{"project" => "proj", "reinit" => true})
    end

    assert_raise ArgumentError, ~r/:tags must be a list of strings/, fn ->
      WandB.init(client, project: "proj", tags: [:atom])
    end

    assert_raise ArgumentError, ~r/:resume must be/, fn ->
      WandB.init(client, project: "proj", resume: :unsupported)
    end

    refute_received {:wandb_request, _, _, _, _, _, _}
  end

  test "history uses monotonic offsets and strictly increasing explicit or implicit steps" do
    client = initialized_client(self())
    discard_init_requests()

    assert {:ok, client} = WandB.log(client, %{loss: 0.5}, step: 3)

    assert_receive {:wandb_request, :post,
                    "https://api.wandb.ai/files/team/proj/run-123/file_stream", _, _,
                    %{
                      "dropped" => 0,
                      "files" => %{
                        "wandb-history.jsonl" => %{"offset" => 0, "content" => [first]}
                      }
                    }, [timeout: 321]}

    assert Jason.decode!(first) == %{"_step" => 3, "loss" => 0.5}

    assert {:ok, client} = WandB.log(client, %{"score" => 9})

    assert_receive {:wandb_request, :post, _, _, _,
                    %{
                      "files" => %{
                        "wandb-history.jsonl" => %{"offset" => 1, "content" => [second]}
                      }
                    }, _}

    assert Jason.decode!(second) == %{"_step" => 4, "score" => 9}
    assert {:error, {:wandb_non_monotonic_step, 4, 4}} = WandB.log(client, %{score: 10}, step: 4)
    refute_received {:wandb_request, _, _, _, _, _, _}
  end

  test "summary writes are complete replacements at offset zero" do
    client = initialized_client(self())
    discard_init_requests()

    assert {:ok, client} = WandB.replace_summary(client, %{best: 0.7, stale: true})
    assert {:ok, _client} = WandB.replace_summary(client, %{best: 0.9})

    assert_receive {:wandb_request, :post, _, _, _,
                    %{
                      "files" => %{
                        "wandb-summary.json" => %{"offset" => 0, "content" => [first]}
                      }
                    }, _}

    assert_receive {:wandb_request, :post, _, _, _,
                    %{
                      "files" => %{
                        "wandb-summary.json" => %{"offset" => 0, "content" => [second]}
                      }
                    }, _}

    assert Jason.decode!(first) == %{"best" => 0.7, "stale" => true}
    assert Jason.decode!(second) == %{"best" => 0.9}
  end

  test "table media is prepared, uploaded, acknowledged, and referenced exactly" do
    client = initialized_client(self())
    discard_init_requests()

    assert {:ok, client} =
             WandB.log_table(client, "scores", ["candidate", "score"], [["a", 0.8]], step: 7)

    table_contents = Jason.encode!(%{"columns" => ["candidate", "score"], "data" => [["a", 0.8]]})
    digest = :crypto.hash(:sha256, table_contents) |> Base.encode16(case: :lower)
    path = "media/table/scores_7_#{String.slice(digest, 0, 20)}.table.json"

    assert_receive {:wandb_request, :post, "https://api.wandb.ai/graphql", _, _,
                    %{
                      "operationName" => "CreateRunFiles",
                      "variables" => %{
                        "entity" => "team",
                        "project" => "proj",
                        "run" => "run-123",
                        "files" => [^path]
                      }
                    }, [timeout: 321]}

    assert_receive {:wandb_request, :put, "https://uploads.example/" <> ^path, upload_headers,
                    ^table_contents, _decoded_table, [timeout: 321]}

    assert upload_headers == [
             {"x-amz-meta-test", "signed"},
             {"content-type", "text/plain"}
           ]

    assert_receive {:wandb_request, :post, _, _, _,
                    %{
                      "complete" => false,
                      "failed" => false,
                      "dropped" => 0,
                      "uploaded" => [^path]
                    }, _}

    assert_receive {:wandb_request, :post, _, _, _,
                    %{
                      "files" => %{
                        "wandb-history.jsonl" => %{"offset" => 0, "content" => [history]}
                      }
                    }, _}

    assert Jason.decode!(history) == %{
             "_step" => 7,
             "scores" => %{
               "_type" => "table-file",
               "log_mode" => "IMMUTABLE",
               "ncols" => 2,
               "nrows" => 1,
               "path" => path,
               "sha256" => digest,
               "size" => byte_size(table_contents)
             }
           }

    assert client.last_step == 7
  end

  test "HTML media uses the 0.21.3 reference and replaces the summary by default" do
    client = initialized_client(self())
    discard_init_requests()

    assert {:ok, client} = WandB.log_html(client, "tree", "<html><h1>Tree</h1></html>", step: 2)

    assert_receive {:wandb_request, :post, _, _, _,
                    %{"operationName" => "CreateRunFiles", "variables" => %{"files" => [path]}},
                    _}

    assert String.starts_with?(path, "media/html/tree_2_")
    assert String.ends_with?(path, ".html")

    assert_receive {:wandb_request, :put, _, _, uploaded_html, nil, _}
    assert uploaded_html =~ ~s(<base target="_blank">)
    assert uploaded_html =~ "<h1>Tree</h1>"

    assert_receive {:wandb_request, :post, _, _, _, %{"uploaded" => [^path]}, _}
    assert_receive {:wandb_request, :post, _, _, _, %{"files" => history_files}, _}
    assert_receive {:wandb_request, :post, _, _, _, %{"files" => summary_files}, _}

    history = history_files["wandb-history.jsonl"]["content"] |> List.first() |> Jason.decode!()
    summary = summary_files["wandb-summary.json"]["content"] |> List.first() |> Jason.decode!()

    assert history["_step"] == 2
    assert history["tree"]["_type"] == "html-file"
    assert history["tree"]["path"] == path
    assert summary == %{"tree" => history["tree"]}
    assert client.summary == summary
  end

  test "finish status is configurable between GEPA v0.1.1 compatibility and accurate mode" do
    accurate = initialized_client(self())
    discard_init_requests()

    assert {:ok, accurate} = WandB.finish(accurate, {:failed, 7})
    assert accurate.finished?

    assert_receive {:wandb_request, :post, _, _, _,
                    %{"complete" => true, "exitcode" => 7, "dropped" => 0, "uploaded" => []}, _}

    gepa =
      initialized_client(self(), [status_mode: :gepa_v0_1_1], id: "run-123")

    discard_init_requests()
    assert {:ok, _gepa} = WandB.finish(gepa, :failed)

    assert_receive {:wandb_request, :post, _, _, _,
                    %{"complete" => true, "exitcode" => 0, "dropped" => 0, "uploaded" => []}, _}

    cancelled = initialized_client(self())
    discard_init_requests()
    assert {:ok, _cancelled} = WandB.finish(cancelled, :cancelled)

    assert_receive {:wandb_request, :post, _, _, _,
                    %{"complete" => true, "exitcode" => 1, "dropped" => 0, "uploaded" => []}, _}
  end

  test "backend serializes immutable client state across callback events" do
    assert {:ok, backend} =
             Backend.start(
               transport: transport(self()),
               api_key: "secret",
               status_mode: :accurate,
               init: %{entity: "team", project: "proj", id: "run-123"}
             )

    discard_init_requests()
    assert :ok = Backend.log(backend, {:metrics, %{score: 0.5}, step: 0})
    assert :ok = Backend.log(backend, {:metrics, %{score: 0.8}, step: 1})
    assert :ok = Backend.finish(backend, :failed)
    refute Process.alive?(backend)

    assert_receive {:wandb_request, :post, _, _, _, %{"files" => first}, _}
    assert first["wandb-history.jsonl"]["offset"] == 0

    assert_receive {:wandb_request, :post, _, _, _, %{"files" => second}, _}
    assert second["wandb-history.jsonl"]["offset"] == 1

    assert_receive {:wandb_request, :post, _, _, _, %{"complete" => true, "exitcode" => 1}, _}
  end

  test "init rejects non-HTTP API origins before sending credentials" do
    client = WandB.new(transport: transport(self()), api_key: "secret")

    assert_raise ArgumentError, ~r/HTTP\(S\) origin/, fn ->
      WandB.init(client, project: "proj", base_url: "file:///tmp/wandb")
    end

    refute_receive {:wandb_request, _, _, _, _, _, _}
  end
end
