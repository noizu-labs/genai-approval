defmodule GenAI.Approval.Lexer do
  @moduledoc """
  Splits script source into segments and tokenizes them.

  Segments:

    * `{:mustache, tokens, {line, col}}` — one `{{ ... }}` construct
    * `{:text, string, {line, col}}` — raw text between mustaches (only
      meaningful inside `endpoint`/`vars`/`outputs` blocks; must be
      whitespace everywhere else)

  Comments (`{{!-- ... --}}` and `{{! ... }}`) are stripped here.

  Tokens are `{kind, value, {line, col}}` with kind `:ident | :string |
  :number | :punct`. No atoms are ever created from input (S2): idents and
  strings stay binaries.
  """

  alias GenAI.Approval.Error

  @type token :: {:ident | :string | :number | :punct, term(), {pos_integer(), pos_integer()}}
  @type segment ::
          {:mustache, [token()], {pos_integer(), pos_integer()}}
          | {:text, String.t(), {pos_integer(), pos_integer()}}

  @spec segments(String.t()) :: {:ok, [segment()]} | {:error, Error.t()}
  def segments(source) do
    try do
      {:ok, scan(source, 1, 1, [], {[], 1, 1})}
    catch
      {:lex_error, err} -> {:error, err}
    end
  end

  @doc "Tokenize a raw-text segment (endpoint/vars/outputs bodies) starting at the given position."
  @spec tokenize(String.t(), {pos_integer(), pos_integer()}) ::
          {:ok, [token()]} | {:error, Error.t()}
  def tokenize(text, {line, col}) do
    try do
      {:ok, tokens(text, line, col, [])}
    catch
      {:lex_error, err} -> {:error, err}
    end
  end

  # -- outer scan: text / comments / mustaches -------------------------------

  # acc: finished segments (reversed); {tbuf, tline, tcol}: pending text buffer + where it started
  defp scan("", _line, _col, acc, {tbuf, tline, tcol}) do
    acc = flush_text(acc, tbuf, tline, tcol)
    Enum.reverse(acc)
  end

  defp scan("{{!--" <> rest, line, col, acc, text) do
    acc = flush_text(acc, elem(text, 0), elem(text, 1), elem(text, 2))

    case split_on(rest, "--}}") do
      {skipped, rest2} ->
        {line2, col2} = advance_pos(skipped <> "--}}", line, col + 5)
        scan(rest2, line2, col2, acc, {[], line2, col2})

      :nomatch ->
        throw({:lex_error, Error.new(:unterminated, "unterminated comment", {line, col})})
    end
  end

  defp scan("{{!" <> rest, line, col, acc, text) do
    acc = flush_text(acc, elem(text, 0), elem(text, 1), elem(text, 2))

    case split_on(rest, "}}") do
      {skipped, rest2} ->
        {line2, col2} = advance_pos(skipped <> "}}", line, col + 3)
        scan(rest2, line2, col2, acc, {[], line2, col2})

      :nomatch ->
        throw({:lex_error, Error.new(:unterminated, "unterminated comment", {line, col})})
    end
  end

  defp scan("{{" <> rest, line, col, acc, text) do
    acc = flush_text(acc, elem(text, 0), elem(text, 1), elem(text, 2))

    case take_mustache_body(rest, [], false) do
      {body, rest2} ->
        toks = tokens(body, line, col + 2, [])
        {line2, col2} = advance_pos(body <> "}}", line, col + 2)
        seg = {:mustache, toks, {line, col}}
        scan(rest2, line2, col2, [seg | acc], {[], line2, col2})

      :nomatch ->
        throw({:lex_error, Error.new(:unterminated, "unterminated '{{'", {line, col})})
    end
  end

  defp scan(<<"\n", rest::binary>>, line, _col, acc, {tbuf, tline, tcol}) do
    scan(rest, line + 1, 1, acc, {["\n" | tbuf], tline, tcol})
  end

  defp scan(<<c::utf8, rest::binary>>, line, col, acc, {tbuf, tline, tcol}) do
    scan(rest, line, col + 1, acc, {[<<c::utf8>> | tbuf], tline, tcol})
  end

  defp flush_text(acc, [], _line, _col), do: acc

  defp flush_text(acc, tbuf, line, col) do
    [{:text, tbuf |> Enum.reverse() |> IO.iodata_to_binary(), {line, col}} | acc]
  end

  # Find the closing `}}`, respecting string literals (a `}}` inside quotes
  # does not terminate the mustache).
  defp take_mustache_body("}}" <> rest, acc, false) do
    {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}
  end

  defp take_mustache_body(<<"\\\"", rest::binary>>, acc, true),
    do: take_mustache_body(rest, ["\\\"" | acc], true)

  defp take_mustache_body(<<"\"", rest::binary>>, acc, in_string),
    do: take_mustache_body(rest, ["\"" | acc], not in_string)

  defp take_mustache_body(<<c::utf8, rest::binary>>, acc, in_string),
    do: take_mustache_body(rest, [<<c::utf8>> | acc], in_string)

  defp take_mustache_body("", _acc, _in_string), do: :nomatch

  defp split_on(bin, marker) do
    case :binary.split(bin, marker) do
      [before, rest] -> {before, rest}
      [_] -> :nomatch
    end
  end

  defp advance_pos(bin, line, col) do
    bin
    |> String.graphemes()
    |> Enum.reduce({line, col}, fn
      "\n", {l, _c} -> {l + 1, 1}
      _g, {l, c} -> {l, c + 1}
    end)
  end

  # -- inner tokenizer -------------------------------------------------------

  defp tokens("", _line, _col, acc), do: Enum.reverse(acc)

  defp tokens(<<"\n", rest::binary>>, line, _col, acc), do: tokens(rest, line + 1, 1, acc)

  defp tokens(<<c, rest::binary>>, line, col, acc) when c in [?\s, ?\t, ?\r],
    do: tokens(rest, line, col + 1, acc)

  defp tokens(<<"\"", rest::binary>>, line, col, acc) do
    {value, rest2, ncol} = take_string(rest, [], line, col + 1)
    tokens(rest2, line, ncol, [{:string, value, {line, col}} | acc])
  end

  for punct <- ["==", "!=", "<=", ">="] do
    defp tokens(<<unquote(punct), rest::binary>>, line, col, acc) do
      tokens(rest, line, col + 2, [{:punct, unquote(punct), {line, col}} | acc])
    end
  end

  for punct <- ["=", ":", "?", ".", ",", "(", ")", "[", "]", "<", ">", "#", "/"] do
    defp tokens(<<unquote(punct), rest::binary>>, line, col, acc) do
      tokens(rest, line, col + 1, [{:punct, unquote(punct), {line, col}} | acc])
    end
  end

  defp tokens(<<c, _::binary>> = bin, line, col, acc) when c in ?0..?9 do
    {num, rest, ncol} = take_number(bin, line, col)
    tokens(rest, line, ncol, [{:number, num, {line, col}} | acc])
  end

  defp tokens(<<c, _::binary>> = bin, line, col, acc)
       when c in ?a..?z or c in ?A..?Z or c == ?_ do
    {ident, rest, ncol} = take_ident(bin, [], col)
    tokens(rest, line, ncol, [{:ident, ident, {line, col}} | acc])
  end

  defp tokens(<<c::utf8, _::binary>>, line, col, _acc) do
    throw(
      {:lex_error,
       Error.new(:unexpected_token, "unexpected character #{inspect(<<c::utf8>>)}", {line, col})}
    )
  end

  defp take_string(<<"\\", esc, rest::binary>>, acc, line, col) do
    ch =
      case esc do
        ?" -> "\""
        ?\\ -> "\\"
        ?n -> "\n"
        ?t -> "\t"
        other -> <<other>>
      end

    take_string(rest, [ch | acc], line, col + 2)
  end

  defp take_string(<<"\"", rest::binary>>, acc, _line, col) do
    {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest, col + 1}
  end

  defp take_string(<<"\n", _::binary>>, _acc, line, col) do
    throw({:lex_error, Error.new(:unterminated, "unterminated string", {line, col})})
  end

  defp take_string(<<c::utf8, rest::binary>>, acc, line, col) do
    take_string(rest, [<<c::utf8>> | acc], line, col + 1)
  end

  defp take_string("", _acc, line, col) do
    throw({:lex_error, Error.new(:unterminated, "unterminated string", {line, col})})
  end

  defp take_number(bin, line, col) do
    {digits, rest} = take_while(bin, fn c -> c in ?0..?9 end)

    case rest do
      <<".", c, _::binary>> when c in ?0..?9 ->
        <<".", rest2::binary>> = rest
        {frac, rest3} = take_while(rest2, fn c2 -> c2 in ?0..?9 end)
        num = String.to_float(digits <> "." <> frac)
        {num, rest3, col + byte_size(digits) + 1 + byte_size(frac)}

      _ ->
        _ = line
        {String.to_integer(digits), rest, col + byte_size(digits)}
    end
  end

  defp take_ident(<<c, rest::binary>>, acc, col)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ do
    take_ident(rest, [c | acc], col + 1)
  end

  defp take_ident(rest, acc, col) do
    {acc |> Enum.reverse() |> List.to_string(), rest, col}
  end

  defp take_while(bin, fun), do: do_take_while(bin, fun, [])

  defp do_take_while(<<c, rest::binary>> = bin, fun, acc) do
    if fun.(c) do
      do_take_while(rest, fun, [c | acc])
    else
      {acc |> Enum.reverse() |> List.to_string(), bin}
    end
  end

  defp do_take_while("", _fun, acc), do: {acc |> Enum.reverse() |> List.to_string(), ""}
end
