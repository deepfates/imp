defmodule Imp.BenchmarkTruth.SemanticSource do
  @moduledoc false

  @doc false
  def digest(source) when is_binary(source) do
    source
    |> Code.string_to_quoted!()
    |> Macro.prewalk(fn
      {:@, _metadata, [{attribute, _attribute_metadata, _value}]}
      when attribute in [:moduledoc, :doc, :typedoc] ->
        {:__block__, [], []}

      {form, metadata, arguments} when is_list(metadata) ->
        {form, [], arguments}

      other ->
        other
    end)
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
