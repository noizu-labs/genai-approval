defmodule GenAI.Approval.Expr do
  @moduledoc """
  Pure evaluator for script expressions against a string-keyed environment.

  Call expressions are delegated to the `call_fn` callback (`fn endpoint,
  command, args_map -> {:ok, result} | {:error, reason} end`); pass
  `:forbidden` where calls are illegal (conditions, outputs) — statically
  prevented, defensively enforced here too.

  Traversal is lenient: dotted access on `nil` or a non-map yields `nil`
  (approval scripts branch on presence, they don't crash on it).
  """

  @type env :: %{optional(String.t()) => term()}
  @type call_fn ::
          (String.t(), String.t(), map() -> {:ok, term()} | {:error, term()}) | :forbidden

  @spec eval(term(), env(), call_fn()) :: {:ok, term()} | {:error, term()}
  def eval({:lit, v}, _env, _cb), do: {:ok, v}

  def eval({:lit_list, exprs}, env, cb) do
    Enum.reduce_while(exprs, {:ok, []}, fn e, {:ok, acc} ->
      case eval(e, env, cb) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  def eval({:var, [head | path]}, env, _cb) do
    {:ok, dig(Map.get(env, head), path)}
  end

  def eval({:not, e}, env, cb) do
    with {:ok, v} <- eval(e, env, cb), do: {:ok, not truthy?(v)}
  end

  def eval({:op, :and, l, r}, env, cb) do
    with {:ok, lv} <- eval(l, env, cb) do
      if truthy?(lv), do: eval(r, env, cb), else: {:ok, lv}
    end
  end

  def eval({:op, :or, l, r}, env, cb) do
    with {:ok, lv} <- eval(l, env, cb) do
      if truthy?(lv), do: {:ok, lv}, else: eval(r, env, cb)
    end
  end

  def eval({:op, op, l, r}, env, cb) do
    with {:ok, lv} <- eval(l, env, cb),
         {:ok, rv} <- eval(r, env, cb) do
      apply_op(op, lv, rv)
    end
  end

  def eval({:call, _e, _c, _args}, _env, :forbidden), do: {:error, :call_forbidden_here}

  def eval({:call, endpoint, command, args}, env, cb) when is_function(cb, 3) do
    with {:ok, args_map} <- eval_args(args, env, cb) do
      cb.(endpoint, command, args_map)
    end
  end

  @doc "Evaluate a `[{name, expr}]` arg list into a string-keyed map."
  @spec eval_args([{String.t(), term()}], env(), call_fn()) :: {:ok, map()} | {:error, term()}
  def eval_args(args, env, cb) do
    Enum.reduce_while(args, {:ok, %{}}, fn {name, expr}, {:ok, acc} ->
      case eval(expr, env, cb) do
        {:ok, v} -> {:cont, {:ok, Map.put(acc, name, v)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @doc "Handlebars-style truthiness: only `false` and `nil` are falsy."
  def truthy?(false), do: false
  def truthy?(nil), do: false
  def truthy?(_), do: true

  defp apply_op(:==, l, r), do: {:ok, l == r}
  defp apply_op(:!=, l, r), do: {:ok, l != r}

  defp apply_op(op, l, r) when is_number(l) and is_number(r) do
    case op do
      :< -> {:ok, l < r}
      :> -> {:ok, l > r}
      :<= -> {:ok, l <= r}
      :>= -> {:ok, l >= r}
    end
  end

  defp apply_op(op, l, r), do: {:error, {:bad_comparison, op, l, r}}

  # dotted access; result maps may be string- or atom-keyed
  defp dig(value, []), do: value

  defp dig(value, [seg | rest]) when is_map(value) do
    case Map.fetch(value, seg) do
      {:ok, v} ->
        dig(v, rest)

      :error ->
        atom_key =
          try do
            String.to_existing_atom(seg)
          rescue
            ArgumentError -> nil
          end

        case atom_key && Map.fetch(value, atom_key) do
          {:ok, v} -> dig(v, rest)
          _ -> nil
        end
    end
  end

  defp dig(_value, _path), do: nil
end
