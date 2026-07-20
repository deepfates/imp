defmodule Imp.CacheMajorsRegressionTest do
  # Regression tests for tickets de-buqx and de-6pyq.
  use ExUnit.Case, async: false

  defmodule TextStub do
    def generate_text(model, messages, opts) do
      if pid = Keyword.get(opts, :test_pid), do: send(pid, {:req_llm_generate, model, opts})

      {:ok,
       %{
         text: "response for #{Keyword.get(opts, :api_key, "no-key")}",
         model: model,
         messages: messages
       }}
    end
  end

  setup do
    Imp.Cache.configure()
    Imp.Cache.clear()

    on_exit(fn ->
      Imp.Cache.configure()
      Imp.Cache.clear()
    end)

    :ok
  end

  describe "de-buqx: credential-scoped cache identity" do
    test "different api keys produce different cache keys; same key is stable" do
      lm = Imp.req_llm("openai:gpt-scope-test", req_module: TextStub)
      messages = [%{role: :user, content: "same prompt"}]

      key_a = Imp.Clients.ReqLLM.cache_key(lm, messages, api_key: "sk-tenant-a")
      key_b = Imp.Clients.ReqLLM.cache_key(lm, messages, api_key: "sk-tenant-b")
      key_a_again = Imp.Clients.ReqLLM.cache_key(lm, messages, api_key: "sk-tenant-a")

      refute key_a == key_b,
             "two different API keys aliased to the same cache key (cross-account response sharing)"

      assert key_a == key_a_again
    end

    test "credential discriminator covers nested and header-shaped credentials" do
      lm = Imp.req_llm("openai:gpt-scope-test", req_module: TextStub)
      messages = [%{role: :user, content: "same prompt"}]

      key_a =
        Imp.Clients.ReqLLM.cache_key(lm, messages,
          authorization: "Bearer tenant-a",
          headers: [{"x-api-key", "tenant-a"}],
          provider_options: %{client_secret: "tenant-a"}
        )

      key_b =
        Imp.Clients.ReqLLM.cache_key(lm, messages,
          authorization: "Bearer tenant-b",
          headers: [{"x-api-key", "tenant-b"}],
          provider_options: %{client_secret: "tenant-b"}
        )

      refute key_a == key_b
    end

    test "generate/3 does not serve one tenant's cached response to another" do
      model = "openai:gpt-scope-#{System.unique_integer([:positive])}"
      lm = Imp.req_llm(model, test_pid: self(), req_module: TextStub)
      messages = [%{role: :user, content: "same prompt"}]

      assert {:ok, first} =
               Imp.Clients.ReqLLM.generate(lm, messages, api_key: "sk-tenant-a")

      assert_received {:req_llm_generate, ^model, _opts}

      assert {:ok, second} =
               Imp.Clients.ReqLLM.generate(lm, messages, api_key: "sk-tenant-b")

      assert_received {:req_llm_generate, ^model, _opts},
                      "tenant B was served tenant A's cached response without a provider call"

      refute first == second
    end
  end

  describe "de-6pyq: capacity enforcement under concurrent writers" do
    test "max_entries holds at every observable instant during concurrent puts" do
      max_entries = 5
      writers = 64
      rounds = 20
      Imp.Cache.configure(max_entries: max_entries)

      observe = fn observe, worst ->
        receive do
          {:stop, from} -> send(from, {:worst_observed, worst})
        after
          0 -> observe.(observe, max(worst, :ets.info(Imp.Cache, :size)))
        end
      end

      observer = spawn_link(fn -> observe.(observe, 0) end)

      worst_settled =
        Enum.reduce(1..rounds, 0, fn round, worst ->
          Imp.Cache.clear()
          parent = self()

          tasks =
            for writer <- 1..writers do
              Task.async(fn ->
                send(parent, {:ready, self()})

                receive do
                  :go -> Imp.Cache.put({:capacity_race, round, writer}, writer)
                end
              end)
            end

          for task <- tasks do
            assert_receive {:ready, pid} when pid == task.pid, 5_000
          end

          Enum.each(tasks, fn task -> send(task.pid, :go) end)
          Task.await_many(tasks, 30_000)

          max(worst, Imp.Cache.stats().size - max_entries)
        end)

      send(observer, {:stop, self()})
      assert_receive {:worst_observed, worst_observed}, 5_000

      assert worst_settled <= 0,
             "cache exceeded max_entries (#{max_entries}) by #{worst_settled} after puts settled"

      assert worst_observed <= max_entries,
             "a concurrent reader observed #{worst_observed} entries while max_entries is " <>
               "#{max_entries}; capacity is not actually enforced under concurrent writes"
    end
  end

  describe "de-6pyq: fetch_or_store does not permanently cache error tuples" do
    test "an {:error, _} result is recomputed on the next call" do
      key = {:error_result, System.unique_integer([:positive])}
      counter = :counters.new(1, [])

      compute = fn ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1 do
          {:error, :transient_boom}
        else
          {:ok, :recovered}
        end
      end

      assert {:error, :transient_boom} = Imp.Cache.fetch_or_store(key, compute)

      assert {:ok, :recovered} = Imp.Cache.fetch_or_store(key, compute),
             "error tuple was cached forever; the recovery path never ran"

      assert Imp.Cache.fetch_or_store(key, compute) == {:ok, :recovered}
      assert :counters.get(counter, 1) == 2
    end
  end
end
