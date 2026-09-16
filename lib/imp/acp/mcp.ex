defmodule Imp.ACP.MCP do
  @moduledoc "Adapts authorized host MCP attachments to Imp tools and ACP tool kinds."

  defmodule Import do
    @moduledoc "The generic import plus ACP presentation hints."
    defstruct tools: [],
              annotations: %{},
              provenance: %{},
              tool_kinds: %{},
              cleanup: nil,
              unavailable: []

    @type t :: %__MODULE__{}
  end

  def import_tools(servers, opts \\ []) do
    with {:ok, imported} <- Imp.MCP.connect(servers, opts) do
      {:ok,
       struct!(
         Import,
         Map.from_struct(imported)
         |> Map.put(:tool_kinds, Imp.ACP.ToolKind.derive_all(imported.annotations))
       )}
    end
  end
end
