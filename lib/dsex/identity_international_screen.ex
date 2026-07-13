defmodule DSEx.IdentityInternationalScreen do
  @moduledoc false

  @schema_version 1
  @method "beam-deterministic-v1"
  @basis "algorithmic-screen"
  @check_ids ~w(unicode script transliteration speech-accessibility cultural-provenance)
  @statuses ~w(no-machine-signal attention unverified not-applicable)

  @letter ~r/\p{L}/u
  @mark ~r/\p{M}/u
  @control ~r/\p{Cc}/u
  @whitespace ~r/\s/u
  @punctuation_or_symbol ~r/[^\p{L}\p{N}\s]/u
  @bidi_control ~r/[\x{061C}\x{200E}\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u
  @default_ignorable ~r/[\x{00AD}\x{034F}\x{061C}\x{180E}\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2060}-\x{206F}\x{FE00}-\x{FE0F}\x{FEFF}\x{E0100}-\x{E01EF}]/u

  @script_patterns [
    {"Latin", ~r/\p{Latin}/u},
    {"Greek", ~r/\p{Greek}/u},
    {"Cyrillic", ~r/\p{Cyrillic}/u},
    {"Arabic", ~r/\p{Arabic}/u},
    {"Hebrew", ~r/\p{Hebrew}/u},
    {"Devanagari", ~r/\p{Devanagari}/u},
    {"Bengali", ~r/\p{Bengali}/u},
    {"Gurmukhi", ~r/\p{Gurmukhi}/u},
    {"Gujarati", ~r/\p{Gujarati}/u},
    {"Tamil", ~r/\p{Tamil}/u},
    {"Telugu", ~r/\p{Telugu}/u},
    {"Kannada", ~r/\p{Kannada}/u},
    {"Malayalam", ~r/\p{Malayalam}/u},
    {"Thai", ~r/\p{Thai}/u},
    {"Hangul", ~r/\p{Hangul}/u},
    {"Hiragana", ~r/\p{Hiragana}/u},
    {"Katakana", ~r/\p{Katakana}/u},
    {"Han", ~r/\p{Han}/u}
  ]

  @limitations [
    "No native-speaker or community validation was performed.",
    "No listener or assistive-technology user test was performed.",
    "No legal, trademark, or marketplace clearance was performed."
  ]

  @spec check_ids() :: [String.t()]
  def check_ids, do: @check_ids

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec build(map(), [map()], map(), [String.t()]) :: map()
  def build(entity, observations, code_forms, projection_peers \\ [])
      when is_map(entity) and is_list(observations) and is_map(code_forms) and
             is_list(projection_peers) do
    surface = entity["display"] || ""
    strategies = entity["strategies"] || []

    %{
      "schema_version" => @schema_version,
      "method" => @method,
      "basis" => @basis,
      "input_sha256" => evidence_digest(observations),
      "evidence_refs" => evidence_refs(observations),
      "checks" => [
        unicode_check(surface),
        script_check(surface),
        transliteration_check(surface, strategies, code_forms, projection_peers),
        speech_check(entity, observations),
        cultural_check(strategies)
      ],
      "limitations" => @limitations
    }
  end

  @spec evidence_digest([map()]) :: String.t()
  def evidence_digest(observations) when is_list(observations) do
    observations
    |> Enum.sort_by(&{&1["occurrence_id"] || "", &1["event_id"] || ""})
    |> :erlang.term_to_binary([:deterministic])
    |> sha256()
  end

  @spec current?(map(), [map()]) :: boolean()
  def current?(screen, observations) when is_map(screen) and is_list(observations) do
    screen["schema_version"] == @schema_version and
      screen["method"] == @method and
      screen["basis"] == @basis and
      screen["input_sha256"] == evidence_digest(observations) and
      screen["evidence_refs"] == evidence_refs(observations)
  end

  def current?(_screen, _observations), do: false

  defp unicode_check(surface) do
    if String.valid?(surface) do
      hazards = [
        {Regex.match?(@control, surface), "control-character-present"},
        {Regex.match?(@bidi_control, surface), "bidi-control-present"},
        {Regex.match?(@default_ignorable, surface), "default-ignorable-present"},
        {unusual_whitespace?(surface), "unusual-whitespace-present"}
      ]

      signals =
        [
          "valid-utf8",
          normalization_signal(surface, :nfc),
          normalization_signal(surface, :nfkc)
        ] ++
          enabled_signals(hazards) ++
          if(Regex.match?(@mark, surface), do: ["combining-mark-present"], else: [])

      %{
        "id" => "unicode",
        "status" =>
          if(Enum.any?(hazards, &elem(&1, 0)), do: "attention", else: "no-machine-signal"),
        "signals" => signals
      }
    else
      %{"id" => "unicode", "status" => "attention", "signals" => ["invalid-utf8"]}
    end
  end

  defp script_check(surface) do
    case scripts(surface) do
      %{letters?: false} ->
        %{
          "id" => "script",
          "status" => "not-applicable",
          "signals" => ["no-letter-script"]
        }

      %{unknown?: true, scripts: scripts} ->
        %{
          "id" => "script",
          "status" => "unverified",
          "signals" => Enum.map(scripts, &"script:#{&1}") ++ ["unrecognized-script-present"]
        }

      %{scripts: scripts} when length(scripts) > 1 ->
        %{
          "id" => "script",
          "status" => "attention",
          "signals" => Enum.map(scripts, &"script:#{&1}") ++ ["mixed-scripts"]
        }

      %{scripts: [script]} ->
        %{
          "id" => "script",
          "status" => "no-machine-signal",
          "signals" => ["script:#{script}"]
        }
    end
  end

  defp transliteration_check(surface, strategies, code_forms, projection_peers) do
    projection = code_forms["hex_package"]
    cross_language? = "archaic-cross-language" in strategies
    non_ascii? = not ascii_only?(surface)
    symbolic? = not Regex.match?(@letter, surface) and not String.match?(surface, ~r/\p{N}/u)
    peers = projection_peers |> Enum.uniq() |> Enum.sort()

    signals = transliteration_signals(surface, projection, peers, cross_language?, non_ascii?)
    status = transliteration_status(symbolic?, projection, peers)

    %{"id" => "transliteration", "status" => status, "signals" => signals}
  end

  defp transliteration_signals(surface, projection, peers, cross_language?, non_ascii?) do
    ["uts39-confusable-skeleton-not-run"]
    |> maybe_add(cross_language?, "source-romanization-unverified")
    |> maybe_add(non_ascii?, "non-ascii-display")
    |> maybe_add(non_ascii? and is_binary(projection), "mechanical-ascii-projection-only")
    |> maybe_add(is_nil(projection), "no-conventional-ascii-code-projection")
    |> maybe_add(
      is_binary(projection) and display_projection_changed?(surface, projection),
      "display-to-code-projection-changed"
    )
    |> Kernel.++(Enum.map(peers, &"ascii-code-projection-shared-with:#{&1}"))
  end

  defp transliteration_status(true, nil, _peers), do: "not-applicable"
  defp transliteration_status(_symbolic?, nil, _peers), do: "attention"
  defp transliteration_status(_symbolic?, _projection, [_peer | _rest]), do: "attention"
  defp transliteration_status(_symbolic?, _projection, []), do: "unverified"

  defp speech_check(entity, observations) do
    surface = entity["display"] || ""

    pronunciations =
      observations
      |> Enum.map(&get_in(&1, ["candidate", "pronunciation"]))
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.uniq()
      |> Enum.sort()

    strategies = entity["strategies"] || []
    surfaces = entity["surfaces"] || [surface]
    symbolic? = not String.match?(surface, ~r/[\p{L}\p{N}]/u)
    acronym? = "acronym-initialism" in strategies or uppercase_token?(surface)

    attention_signals =
      []
      |> maybe_add(pronunciations == [], "pronunciation-missing")
      |> maybe_add(length(pronunciations) > 1, "pronunciation-conflict")
      |> maybe_add(symbolic?, "symbolic-spoken-expansion-required")
      |> maybe_add(
        Regex.match?(@punctuation_or_symbol, surface),
        "punctuation-or-symbol-ambiguity"
      )
      |> maybe_add(acronym?, "acronym-or-initialism-ambiguity")
      |> maybe_add(case_only_variants?(surfaces), "case-only-surface-variants")

    %{
      "id" => "speech-accessibility",
      "status" => if(attention_signals == [], do: "unverified", else: "attention"),
      "signals" =>
        attention_signals ++
          ["listener-recovery-test-not-run", "assistive-technology-test-not-run"]
    }
  end

  defp cultural_check(strategies) do
    attention_signals =
      []
      |> maybe_add("archaic-cross-language" in strategies, "cross-language-source-review-needed")
      |> maybe_add(
        "proper-mythic-historical" in strategies,
        "proper-mythic-historical-stewardship-review-needed"
      )

    %{
      "id" => "cultural-provenance",
      "status" => if(attention_signals == [], do: "unverified", else: "attention"),
      "signals" => attention_signals ++ ["native-speaker-community-review-not-performed"]
    }
  end

  defp scripts(surface) do
    if String.valid?(surface) do
      surface
      |> String.graphemes()
      |> Enum.reduce(
        %{letters?: false, unknown?: false, scripts: MapSet.new()},
        &classify_script_grapheme/2
      )
      |> Map.update!(:scripts, &(MapSet.to_list(&1) |> Enum.sort()))
    else
      %{letters?: true, unknown?: true, scripts: []}
    end
  end

  defp classify_script_grapheme(grapheme, acc) do
    if Regex.match?(@letter, grapheme) do
      matched = matching_scripts(grapheme)

      %{
        letters?: true,
        unknown?: acc.unknown? or matched == [],
        scripts: Enum.reduce(matched, acc.scripts, &MapSet.put(&2, &1))
      }
    else
      acc
    end
  end

  defp matching_scripts(grapheme) do
    @script_patterns
    |> Enum.filter(fn {_name, pattern} -> Regex.match?(pattern, grapheme) end)
    |> Enum.map(&elem(&1, 0))
  end

  defp evidence_refs(observations) do
    observations
    |> Enum.map(& &1["occurrence_id"])
    |> Enum.filter(&is_binary/1)
    |> Enum.sort()
  end

  defp normalization_signal(surface, form) do
    suffix = if String.normalize(surface, form) == surface, do: "stable", else: "changed"
    "#{form}-#{suffix}"
  end

  defp unusual_whitespace?(surface) do
    surface
    |> String.graphemes()
    |> Enum.any?(fn grapheme -> grapheme != " " and Regex.match?(@whitespace, grapheme) end)
  end

  defp display_projection_changed?(surface, projection) do
    comparable =
      surface
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    comparable != projection
  end

  defp ascii_only?(surface),
    do: String.printable?(surface) and byte_size(surface) == String.length(surface)

  defp uppercase_token?(surface) do
    letters = String.replace(surface, ~r/[^\p{L}]/u, "")
    String.length(letters) >= 2 and letters == String.upcase(letters)
  end

  defp case_only_variants?(surfaces) do
    surfaces
    |> Enum.filter(&is_binary/1)
    |> Enum.group_by(&String.downcase/1)
    |> Enum.any?(fn {_folded, variants} -> length(Enum.uniq(variants)) > 1 end)
  end

  defp enabled_signals(items),
    do: for({true, signal} <- items, do: signal)

  defp maybe_add(items, true, value), do: items ++ [value]
  defp maybe_add(items, false, _value), do: items

  defp sha256(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
