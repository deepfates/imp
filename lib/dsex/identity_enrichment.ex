defmodule DSEx.IdentityEnrichment do
  @moduledoc false

  alias DSEx.IdentityEvaluation

  @baseline_version 1

  @spec baseline([map()], map(), keyword()) :: [map()]
  def baseline(registry, atlas, opts \\ []) do
    generated_at =
      Keyword.get_lazy(opts, :generated_at, fn ->
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      end)

    observations =
      registry
      |> Enum.filter(&(&1["event_type"] == "candidate_observed"))
      |> Enum.group_by(& &1["candidate_id"])

    registry
    |> IdentityEvaluation.candidate_entities()
    |> Enum.sort_by(fn {_candidate_id, entity} ->
      {String.downcase(entity["display"]), entity["candidate_id"]}
    end)
    |> Enum.map(fn {candidate_id, entity} ->
      candidate_observations = Map.fetch!(observations, candidate_id)
      first = hd(candidate_observations)
      candidate = first["candidate"] || %{}
      code_forms = code_forms(entity["display"])

      %{
        "id" => stable_id("enrichment", "baseline-v#{@baseline_version}:#{candidate_id}"),
        "candidate_id" => candidate_id,
        "enriched_at" => generated_at,
        "assessor" => %{
          "kind" => "algorithm",
          "name" => "identity baseline embodiment v#{@baseline_version}"
        },
        "spoken_forms" => %{
          "pronunciation" => candidate["pronunciation"],
          "recommendation" => "Try #{entity["display"]} for the Elixir LM program.",
          "support_call" => "I am using #{entity["display"]} in an Elixir application.",
          "ambiguities" => spoken_ambiguities(entity)
        },
        "code_forms" => code_forms,
        "prose_forms" => %{
          "readme_headline" =>
            "#{entity["display"]}: declarative, measurable LM programs for Elixir.",
          "paper_title" =>
            "#{entity["display"]}: Declarative Language-Model Programs and Optimization on the BEAM",
          "conference_sentence" =>
            "We built and evaluated the program with #{entity["display"]}.",
          "error_sentence" => "#{entity["display"]} could not complete the model call."
        },
        "architecture_forms" =>
          architecture_forms(candidate_observations, entity["display"], atlas),
        "international_notes" => [],
        "future_scope_notes" => [
          "Baseline embodiment only; it does not establish international, legal, or ecosystem fitness.",
          "Assess against both the current Elixir library and the credible artifact-optimization horizon."
        ],
        "evidence_refs" => Enum.map(candidate_observations, & &1["occurrence_id"]),
        "supersedes" => nil
      }
    end)
  end

  @spec code_forms(String.t()) :: map()
  def code_forms(surface) do
    slug = code_slug(surface)
    valid = slug != "" and String.match?(slug, ~r/^[a-z][a-z0-9_]*$/)

    concerns =
      []
      |> maybe_add(
        not ascii_only?(surface),
        "Display form contains non-ASCII characters; no transliteration was inferred."
      )
      |> maybe_add(
        slug == "",
        "No ASCII letter or number remains for a conventional Elixir identifier."
      )
      |> maybe_add(
        slug != "" and not valid,
        "Derived identifier does not start with an ASCII letter."
      )

    if valid do
      %{
        "hex_package" => slug,
        "otp_app" => slug,
        "module_root" => Macro.camelize(slug),
        "mix_task_prefix" => slug,
        "config_prefix" => slug,
        "telemetry_prefix" => "[:#{slug}]",
        "code_concerns" => concerns
      }
    else
      %{
        "hex_package" => nil,
        "otp_app" => nil,
        "module_root" => nil,
        "mix_task_prefix" => nil,
        "config_prefix" => nil,
        "telemetry_prefix" => nil,
        "code_concerns" => concerns
      }
    end
  end

  defp code_slug(surface) do
    surface
    |> String.normalize(:nfkd)
    |> String.replace(~r/[\p{Mn}\p{Me}]/u, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp ascii_only?(surface),
    do: String.printable?(surface) and byte_size(surface) == String.length(surface)

  defp spoken_ambiguities(entity) do
    entity["surfaces"]
    |> Enum.reject(&(&1 == entity["display"]))
    |> Enum.map(&"Also observed as #{&1}.")
  end

  defp architecture_forms(observations, display, atlas) do
    labels = Map.new(atlas["brand_architectures"] || [], &{&1["id"], &1["label"]})

    observations
    |> Enum.flat_map(&(get_in(&1, ["candidate", "architecture_lenses"]) || []))
    |> Enum.uniq()
    |> Enum.map(fn architecture_id ->
      %{
        "architecture_id" => architecture_id,
        "form" => architecture_form(architecture_id, display),
        "notes" => Map.get(labels, architecture_id, architecture_id)
      }
    end)
  end

  defp architecture_form("neutral-master-beam-implementation", display),
    do: "#{display} for Elixir"

  defp architecture_form("shared-prefix-family", display),
    do: "#{display}_core / #{display}_eval / #{display}_optimize"

  defp architecture_form("oss-commercial-split", display),
    do: "#{display} Open Source / [commercial steward]"

  defp architecture_form("research-stable-split", display),
    do: "#{display} / #{display} Research"

  defp architecture_form("company-product-split", display),
    do: "[company] #{display}"

  defp architecture_form("spec-implementations", display),
    do: "#{display} Specification / #{display} Elixir"

  defp architecture_form("edition-architecture", display),
    do: "#{display} Local / Hosted / Enterprise"

  defp architecture_form("federated-compatibility", display),
    do: "#{display} Compatible"

  defp architecture_form(_architecture_id, display), do: display

  defp maybe_add(items, true, value), do: items ++ [value]
  defp maybe_add(items, false, _value), do: items

  defp stable_id(prefix, value) do
    digest = :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
    prefix <> "-" <> binary_part(digest, 0, 16)
  end
end
