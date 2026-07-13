defmodule ClaimsInventoryTest do
  use ExUnit.Case, async: true

  @claims_path "benchmarks/claims.json"
  @decisions ["proven_target", "active_gap"]

  test "claim ids and release decisions are explicit and internally consistent" do
    claims = read_claims!()
    ids = Enum.map(claims, &Map.fetch!(&1, "id"))

    assert length(ids) == length(Enum.uniq(ids))

    Enum.each(claims, fn claim ->
      assert claim["decision"] in @decisions,
             "#{claim["id"]} has invalid decision #{inspect(claim["decision"])}"

      assert is_binary(claim["release"]) and claim["release"] != "",
             "#{claim["id"]} must name its release scope"

      assert is_binary(claim["scope"]) and claim["scope"] != "",
             "#{claim["id"]} must define a precise scope"
    end)
  end

  test "proven targets and active telos gaps both remain release blocking" do
    Enum.each(read_claims!(), fn claim ->
      case claim["decision"] do
        "proven_target" ->
          assert claim["release"] == "v0.1"
          assert claim["release_blocking"] == true

        "active_gap" ->
          assert claim["release"] == "telos"
          assert claim["release_blocking"] == true

          assert is_list(claim["limitations"]) and claim["limitations"] != [],
                 "#{claim["id"]} active gap must state its limitations"
      end
    end)
  end

  test "every claim has an evidence requirement and auditable source" do
    Enum.each(read_claims!(), fn claim ->
      assert is_list(claim["requirements"]) and claim["requirements"] != [],
             "#{claim["id"]} must name evidence requirements"

      assert Enum.all?(claim["requirements"], fn requirement ->
               is_binary(requirement["id"]) and is_binary(requirement["lane"]) and
                 requirement["evidence"] in ["full", "passing"]
             end)

      assert is_list(claim["sources"]) and claim["sources"] != [],
             "#{claim["id"]} must cite its implementation or documentation sources"
    end)
  end

  defp read_claims! do
    @claims_path
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("claims")
  end
end
