defmodule Imp.ACP.ToolKind do
  @moduledoc """
  Derives an ACP tool kind from the MCP tool annotations a server declares.

  An MCP server already states what each of its tools does to the world.
  `ToolAnnotations` carries `readOnlyHint`, `destructiveHint`, `idempotentHint`
  and `openWorldHint`, and those hints travel on the wire in `tools/list`. A
  host that instead keeps a hand-written table from tool *name* to ACP kind has
  re-derived that declaration, and the table goes stale the moment the server
  publishes a tool the table does not name - which is the case where a
  permission mode that would have asked does not ask.

  So the kind is computed from the declaration, once, here.

  ## The rule

  The MCP specification's own defaults apply when a hint is absent:
  `readOnlyHint` defaults to `false`, `destructiveHint` to `true`, and
  `openWorldHint` to `true`. Those defaults are only consulted when the tool
  declared *some* hint; a tool that declares none is undeclared, and this
  module answers `nil` rather than guessing.

      readOnlyHint: true,  openWorldHint: true    -> "read"
      readOnlyHint: true,  openWorldHint: false   -> "think"
      write, destructiveHint: true                -> "delete"
      write, not destructive, openWorldHint: true -> "execute"
      write, not destructive, openWorldHint: false-> "edit"
      no annotations, or no hints in them         -> nil

  The safety-relevant distinction is the one the hints actually make: does this
  tool change anything, and can the change be destructive. The finer ACP kinds
  (`search` versus `read`, `edit` versus `execute`) are presentational, so a
  host that wants a nicer card keeps declaring those by name in `:tool_kinds`,
  which takes precedence over anything derived here. Nothing safety-relevant
  depends on that override existing.

  `"think"` for a read that declares `openWorldHint: false` is the reading of a
  tool that touches nothing outside the process - Kite's `silence` is the
  example, and it is the kind Dwell's hand table already assigned it.
  """

  @hint_keys ["readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"]

  @doc """
  Derives one ACP tool kind, or `nil` when the tool declares no annotation
  hints at all.
  """
  @spec derive(map() | nil) :: String.t() | nil
  def derive(annotations) when is_map(annotations) do
    annotations = normalize(annotations)

    if Enum.any?(@hint_keys, &Map.has_key?(annotations, &1)) do
      classify(
        hint(annotations, "readOnlyHint", false),
        hint(annotations, "destructiveHint", true),
        hint(annotations, "openWorldHint", true)
      )
    else
      nil
    end
  end

  def derive(_annotations), do: nil

  @doc """
  Derives a name-to-kind map from a name-to-annotations map, dropping every
  tool that declares nothing to derive from.
  """
  @spec derive_all(%{optional(String.t()) => map()}) :: %{optional(String.t()) => String.t()}
  def derive_all(annotations) when is_map(annotations) do
    annotations
    |> Enum.flat_map(fn {name, tool_annotations} ->
      case derive(tool_annotations) do
        nil -> []
        kind -> [{to_string(name), kind}]
      end
    end)
    |> Map.new()
  end

  def derive_all(_annotations), do: %{}

  defp classify(true, _destructive, false), do: "think"
  defp classify(true, _destructive, _open_world), do: "read"
  defp classify(_read_only, true, _open_world), do: "delete"
  defp classify(_read_only, _destructive, false), do: "edit"
  defp classify(_read_only, _destructive, _open_world), do: "execute"

  # A hint is a boolean in the MCP schema. Anything else is not a declaration
  # this can read, so the specification default stands rather than a coercion.
  defp hint(annotations, key, default) do
    case Map.get(annotations, key) do
      value when is_boolean(value) -> value
      _other -> default
    end
  end

  defp normalize(annotations) do
    Map.new(annotations, fn {key, value} -> {to_string(key), value} end)
  end
end
