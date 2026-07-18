defmodule SavingConfigRoundtripTest do
  use ExUnit.Case, async: true

  # Regression: the README/tutorial template program carries
  # `config: [json_retries: 1]`. decode_config_key's allowlist did not map
  # "json_retries" back to an atom, so `Imp.save!` succeeded and `Imp.load!`
  # raised (`invalid value for :config option: expected keyword list, got:
  # [{"json_retries", 1}]`) — a silent-until-load failure on the front-door
  # path, found live by the real-data campaign's operate cell.
  test "the README template program's config round-trips through save!/load!" do
    program =
      "ticket -> team: enum[billing,infrastructure,security,product]"
      |> Imp.signature("Assign the support ticket to the team that owns it.")
      |> Imp.predict(adapter: Imp.Adapter.JSON, config: [json_retries: 1])

    path =
      Path.join(
        System.tmp_dir!(),
        "imp-config-roundtrip-#{System.unique_integer([:positive])}.json"
      )

    try do
      :ok = Imp.save!(program, path)
      loaded = Imp.load!(path)

      assert loaded.config[:json_retries] == 1

      lm = %{
        module: Imp.LM.Static,
        opts: [handler: fn _messages, _opts -> %{team: "security"} end]
      }

      {:ok, prediction} =
        Imp.context([lm: lm], fn ->
          Imp.call(loaded, %{ticket: "Customers can see other users' invoices."})
        end)

      assert Imp.get(prediction, :team) == "security"
    after
      File.rm(path)
    end
  end

  test "json_fallback survives the artifact boundary as an atom key" do
    program = Imp.predict("question -> answer", config: [json_retries: 2, json_fallback: false])

    loaded = program |> Imp.dump() |> Imp.load()

    assert loaded.config[:json_retries] == 2
    assert loaded.config[:json_fallback] == false
  end
end
