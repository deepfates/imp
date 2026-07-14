defmodule AdversarialSecurityStressTest do
  use ExUnit.Case, async: false

  defmodule SlowProgram do
    defstruct []

    def call(%__MODULE__{}, sleep_ms) do
      Process.sleep(sleep_ms)
      {:ok, Imp.Prediction.new(value: sleep_ms)}
    end
  end

  defmodule ExplodingProgram do
    defstruct []

    def call(%__MODULE__{}, :raise), do: raise("parallel exploded")
    def call(%__MODULE__{}, :throw), do: throw(:parallel_thrown)
    def call(%__MODULE__{}, :invalid), do: :not_a_module_result
    def call(%__MODULE__{}, value), do: {:ok, Imp.Prediction.new(value: value)}
  end

  test "parallel prediction timeouts kill slow tasks without exiting the caller" do
    assert [{:error, :timeout}, {:ok, prediction}] =
             Imp.Predict.Parallel.map(%SlowProgram{}, [50, 0],
               max_concurrency: 2,
               timeout: 5
             )

    assert Imp.Prediction.get(prediction, :value) == 0
  end

  test "parallel prediction records per-input crashes and invalid returns" do
    assert [
             {:ok, %Imp.Prediction{} = ok_prediction},
             {:error, {:parallel_program_failed, "parallel exploded"}},
             {:error, {:parallel_program_failed, "{:throw, :parallel_thrown}"}},
             {:error,
              {:invalid_module_result, AdversarialSecurityStressTest.ExplodingProgram,
               ":not_a_module_result"}}
           ] =
             Imp.Predict.Parallel.map(%ExplodingProgram{}, [:ok, :raise, :throw, :invalid],
               max_concurrency: 2
             )

    assert Imp.Prediction.get(ok_prediction, :value) == :ok
  end

  test "cache contention remains bounded and returns stored values" do
    Imp.Cache.clear()
    parent = self()

    values =
      1..100
      |> Task.async_stream(
        fn index ->
          Imp.Cache.fetch_or_store({:stress, rem(index, 10)}, fn ->
            send(parent, {:computed, rem(index, 10)})
            {:value, rem(index, 10)}
          end)
        end,
        max_concurrency: 20
      )
      |> Enum.map(fn {:ok, value} -> value end)

    assert Enum.all?(values, &match?({:value, key} when key in 0..9, &1))

    assert Enum.map(0..9, &Imp.Cache.get({:stress, &1})) ==
             Enum.map(0..9, &{:value, &1})

    computed =
      receive_computed([])
      |> Enum.frequencies()

    assert Map.keys(computed) |> Enum.sort() == Enum.to_list(0..9)
  end

  test "stdio MCP timeout returns a structured failure instead of hanging" do
    script =
      Path.join(System.tmp_dir!(), "imp-mcp-timeout-#{System.unique_integer([:positive])}.exs")

    File.write!(script, """
    Stream.repeatedly(fn ->
      IO.puts("non-json subprocess noise")
      Process.sleep(5)
    end)
    |> Stream.run()
    """)

    on_exit(fn -> File.rm(script) end)

    client =
      System.find_executable("elixir")
      |> Imp.MCP.StdioClient.new(args: [script], timeout: 50)

    assert_raise ArgumentError, ~r/MCP stdio failed: :timeout/, fn ->
      Imp.MCP.import_tools(client)
    end
  end

  test "high-volume telemetry redacts secret-shaped metadata" do
    ref = Imp.Test.TelemetryHelpers.attach([[:imp, :stress, :secret]])

    Enum.each(1..50, fn index ->
      Imp.Telemetry.execute(
        [:imp, :stress, :secret],
        %{count: index},
        %{
          authorization: "Bearer abcdefghijklmnopqrstuvwxyz",
          nested: %{api_key: "sk-abcdefghijklmnopqrstuvwxyz"},
          harmless: "event-#{index}"
        }
      )
    end)

    events = receive_events(ref, [])

    assert length(events) == 50

    assert Enum.all?(events, fn {_event, measurements, metadata} ->
             is_integer(measurements.count) and
               metadata.authorization == "[REDACTED]" and
               metadata.nested.api_key == "[REDACTED]" and
               String.starts_with?(metadata.harmless, "event-")
           end)
  end

  defp receive_computed(acc) do
    receive do
      {:computed, key} -> receive_computed([key | acc])
    after
      20 -> acc
    end
  end

  defp receive_events(ref, acc) do
    receive do
      {^ref, event, measurements, metadata} ->
        receive_events(ref, [{event, measurements, metadata} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end
end
