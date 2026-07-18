# Diagnostic probe (not an arm): characterize WHY the react_zero_shot arm errors
# on ~1/3 of held-out rows. Calls the SAME react program used in the cell on the
# 40 held-out test rows once, capturing the {:error, reason} tag for each failing
# row and tallying reason categories. Writes gsm8k_react_error_probe-result.json.
# Read-only w.r.t. the library; lives under the campaign runs dir.

defmodule ReactErrorProbe do
  @model "openai:gpt-5.4-mini"
  @data_relative "benchmarks/runs/campaign-20260718/data/gsm8k.json"
  @out "benchmarks/runs/campaign-20260718/gsm8k_react_error_probe-result.json"
  @test_range 80..119
  @max_iters 6

  defmodule Calc do
    def eval(expr) when is_binary(expr) do
      with {:ok, tokens} <- tokenize(expr), {value, []} <- expr_p(tokens) do
        {:ok, value}
      else
        {_v, rest} when is_list(rest) -> {:error, {:trailing_tokens, rest}}
        {:error, reason} -> {:error, reason}
      end
    rescue
      e -> {:error, Exception.message(e)}
    catch
      kind, reason -> {:error, {kind, reason}}
    end

    def eval(other), do: {:error, {:not_a_string, other}}
    defp tokenize(str), do: tokenize(String.trim(str), [])
    defp tokenize("", acc), do: {:ok, Enum.reverse(acc)}
    defp tokenize(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\n, ?\r], do: tokenize(rest, acc)
    defp tokenize(<<c, rest::binary>>, acc) when c in [?+, ?-, ?*, ?/, ?(, ?)], do: tokenize(rest, [{:op, <<c>>} | acc])

    defp tokenize(<<c, _::binary>> = str, acc) when (c >= ?0 and c <= ?9) or c == ?. do
      case Regex.run(~r/^\d*\.?\d+/, str) do
        [num] ->
          {value, ""} = Float.parse(ensure_float(num))
          rest = binary_part(str, byte_size(num), byte_size(str) - byte_size(num))
          tokenize(rest, [{:num, value} | acc])

        _ -> {:error, {:bad_number, str}}
      end
    end

    defp tokenize(<<c, _::binary>>, _acc), do: {:error, {:unexpected_char, <<c>>}}
    defp ensure_float("." <> _ = s), do: "0" <> s
    defp ensure_float(s), do: s
    defp expr_p(tokens), do: (fn {l, r} -> expr_p(l, r) end).(term_p(tokens))
    defp expr_p(left, [{:op, "+"} | rest]), do: (fn {r, r2} -> expr_p(left + r, r2) end).(term_p(rest))
    defp expr_p(left, [{:op, "-"} | rest]), do: (fn {r, r2} -> expr_p(left - r, r2) end).(term_p(rest))
    defp expr_p(left, rest), do: {left, rest}
    defp term_p(tokens), do: (fn {l, r} -> term_p(l, r) end).(factor_p(tokens))
    defp term_p(left, [{:op, "*"} | rest]), do: (fn {r, r2} -> term_p(left * r, r2) end).(factor_p(rest))
    defp term_p(left, [{:op, "/"} | rest]), do: (fn {r, r2} -> term_p(left / r, r2) end).(factor_p(rest))
    defp term_p(left, rest), do: {left, rest}
    defp factor_p([{:num, n} | rest]), do: {n, rest}

    defp factor_p([{:op, "("} | rest]) do
      {value, rest2} = expr_p(rest)
      case rest2 do
        [{:op, ")"} | rest3] -> {value, rest3}
        _ -> throw({:unbalanced_parens, rest2})
      end
    end

    defp factor_p([{:op, "-"} | rest]), do: (fn {v, r} -> {-v, r} end).(factor_p(rest))
    defp factor_p([{:op, "+"} | rest]), do: factor_p(rest)
    defp factor_p(other), do: throw({:unexpected_tokens, other})
  end

  defp run_calc(args) do
    expr = args[:expression] || args["expression"]
    case Calc.eval(expr) do
      {:ok, value} when is_float(value) ->
        r = Float.round(value)
        if abs(value - r) < 1.0e-9, do: r |> trunc() |> Integer.to_string(), else: :erlang.float_to_binary(value, [:short])

      {:ok, value} -> to_string(value)
      {:error, reason} -> "ERROR: could not evaluate #{inspect(expr)} (#{inspect(reason)})"
    end
  end

  # Bucket a raw error reason into a coarse category for tallying.
  defp category(reason) do
    s = inspect(reason)

    cond do
      s =~ "max_iter" or s =~ "iteration" or s =~ "exhaust" -> "max_iters_exhausted"
      s =~ "submit" -> "submit_validation"
      s =~ "tool_policy" -> "tool_policy"
      s =~ "parse" or s =~ "adapter" or s =~ "format" -> "parse_or_adapter"
      s =~ "timeout" or s =~ "Timeout" -> "timeout"
      true -> "other"
    end
  end

  def main do
    api_key = System.fetch_env!("OPENAI_API_KEY")
    lm = Imp.req_llm(@model, api_key: api_key, temperature: 0)

    bytes = File.read!(@data_relative)
    %{"rows" => rows} = Jason.decode!(bytes)
    test = for i <- @test_range, r = Enum.at(rows, i), do: {i, r}

    calc =
      Imp.tool(:calc, "Evaluate a basic arithmetic expression over numbers using + - * / and parentheses.",
        &run_calc/1,
        schema: %{"type" => "object", "properties" => %{"expression" => %{"type" => "string"}}, "required" => ["expression"]})

    react = Imp.react("question -> answer", [calc], lm: lm, tool_policy: [:calc, :submit], max_iters: @max_iters)

    Imp.Cache.clear()

    results =
      for {i, row} <- test do
        case Imp.call(react, %{question: row["question"]}) do
          {:ok, pred} ->
            %{"index" => i, "outcome" => "ok", "answer" => to_string(Imp.Prediction.get(pred, :answer))}

          {:error, reason} ->
            cat = category(reason)
            IO.puts("row #{i}: ERROR [#{cat}] #{String.slice(inspect(reason), 0, 200)}")
            %{"index" => i, "outcome" => "error", "category" => cat, "reason" => String.slice(inspect(reason), 0, 800)}
        end
      end

    errors = Enum.filter(results, &(&1["outcome"] == "error"))

    tally =
      errors
      |> Enum.frequencies_by(& &1["category"])

    IO.puts("\n=== #{length(errors)}/#{length(results)} rows errored ===")
    IO.inspect(tally, label: "category tally")

    File.write!(@out, Jason.encode!(%{
      "probe" => "gsm8k_react_error_probe",
      "model" => @model,
      "n_rows" => length(results),
      "n_errors" => length(errors),
      "category_tally" => tally,
      "results" => results
    }, pretty: true) <> "\n")

    IO.puts("artifact: #{@out}")
  end
end

ReactErrorProbe.main()
