defmodule Imp.PyFloat do
  @moduledoc false

  # Byte-faithful reproduction of CPython's `repr(float)` / `str(float)` (the
  # `'r'` format of `PyOS_double_to_string`), which DSPy relies on when it renders
  # a float through `str(serialize_for_json(v))` or `json.dumps` (dee-h7nw).
  #
  # Elixir's `to_string/1` and `Jason.encode!/1` use Erlang's shortest-repr
  # (`:erlang.float_to_binary(f, [:short])`), which agrees with Python on the
  # significant digits but formats them differently: `1.0e6` vs `1000000.0`,
  # `1.0e16` vs `1e+16`, `1.0e-5` vs `1e-05`. We take Erlang's shortest digits
  # (guaranteeing the same round-trip value) and re-apply Python's fixed-vs-
  # exponent rule and exponent padding.

  @doc """
  Python `repr(f)` for a finite float. Raises for non-finite values (Python
  renders those as `inf`/`nan`, and DSPy never emits them through this path).
  """
  def repr(float) when is_float(float) do
    short = :erlang.float_to_binary(float, [:short])
    {sign, digits, decpt} = decompose(short)

    body =
      if digits == "0" do
        "0.0"
      else
        format(digits, decpt)
      end

    sign <> body
  end

  # Parse Erlang's shortest form (always "<int>.<frac>" with an optional
  # "e<exp>") into a sign, the significant digit string (no leading/trailing
  # zeros), and Python's `decimal_point`: the value is `0.<digits> * 10^decpt`.
  defp decompose(short) do
    {sign, rest} =
      case short do
        "-" <> tail -> {"-", tail}
        _ -> {"", short}
      end

    {mantissa, exp} =
      case String.split(rest, ["e", "E"]) do
        [m] -> {m, 0}
        [m, e] -> {m, String.to_integer(e)}
      end

    [int_part, frac_part] = String.split(mantissa, ".")
    all_digits = int_part <> frac_part

    trimmed_leading = String.replace_leading(all_digits, "0", "")
    leading_zeros = byte_size(all_digits) - byte_size(trimmed_leading)
    digits = String.replace_trailing(trimmed_leading, "0", "")

    if digits == "" do
      {sign, "0", 1}
    else
      decpt = byte_size(int_part) + exp - leading_zeros
      {sign, digits, decpt}
    end
  end

  # CPython 'r' format: exponent form when decpt <= -4 or decpt > 16.
  defp format(digits, decpt) when decpt <= -4 or decpt > 16 do
    exp = decpt - 1

    mantissa =
      case digits do
        <<lead::binary-size(1)>> -> lead
        <<lead::binary-size(1), tail::binary>> -> lead <> "." <> tail
      end

    mantissa <> "e" <> exponent(exp)
  end

  defp format(digits, decpt) do
    n = byte_size(digits)

    cond do
      decpt <= 0 ->
        "0." <> String.duplicate("0", -decpt) <> digits

      decpt >= n ->
        digits <> String.duplicate("0", decpt - n) <> ".0"

      true ->
        <<head::binary-size(decpt), tail::binary>> = digits
        head <> "." <> tail
    end
  end

  # Python always shows the exponent sign and at least two exponent digits.
  defp exponent(exp) do
    sign = if exp < 0, do: "-", else: "+"
    digits = exp |> abs() |> Integer.to_string() |> String.pad_leading(2, "0")
    sign <> digits
  end
end
