defmodule GenAI.Approval.StaticChecks do
  @moduledoc """
  Post-parse validation (PRD R5.1–R5.6). Returns a list of `%Error{}` —
  empty when the script is valid. All applicable errors are reported, not
  just the first.
  """

  alias GenAI.Approval.{Error, Parser, Script}
  alias GenAI.Approval.Script.{Assign, Call, If, Step, VarDecl}

  @spec check(Script.t()) :: [Error.t()]
  def check(%Script{} = script) do
    var_names = MapSet.new(script.vars, & &1.name)

    []
    |> check_duplicate_vars(script)
    |> check_var_defaults(script)
    |> check_body(script, var_names)
    |> check_outputs(script, var_names)
    |> Enum.reverse()
  end

  defp check_duplicate_vars(errors, script) do
    script.vars
    |> Enum.group_by(& &1.name)
    |> Enum.filter(fn {_n, ds} -> length(ds) > 1 end)
    |> Enum.reduce(errors, fn {name, [_, dup | _]}, acc ->
      [Error.new(:duplicate_var, "variable #{inspect(name)} declared twice", {dup.line, 1}) | acc]
    end)
  end

  defp check_var_defaults(errors, script) do
    Enum.reduce(script.vars, errors, fn %VarDecl{} = v, acc ->
      cond do
        not v.has_default ->
          acc

        is_nil(v.default) and not v.nullable ->
          [
            Error.new(
              :type_mismatch,
              "variable #{inspect(v.name)} has null default but is not nullable (add ?)",
              {v.line, 1}
            )
            | acc
          ]

        is_nil(v.default) ->
          acc

        not type_match?(v.type, v.default) ->
          [
            Error.new(
              :type_mismatch,
              "default for #{inspect(v.name)} does not match type #{v.type}",
              {v.line, 1}
            )
            | acc
          ]

        true ->
          acc
      end
    end)
  end

  defp type_match?("string", v), do: is_binary(v)
  defp type_match?("number", v), do: is_number(v)
  defp type_match?("boolean", v), do: is_boolean(v)
  defp type_match?("list", v), do: is_list(v)
  # objects can only be seeded by the caller or assigned at runtime
  defp type_match?("object", _v), do: false

  # -- body walk -------------------------------------------------------------

  defp check_body(errors, script, var_names) do
    {errors, _assigned} = walk_body(script.body, script, var_names, errors)
    errors
  end

  defp walk_body(nodes, script, var_names, errors) do
    Enum.reduce(nodes, {errors, var_names}, fn node, {errs, vars} ->
      case node do
        %Step{} = step ->
          {walk_step(step, script, vars, errs), vars}

        %If{} = node ->
          errs = check_condition(node.condition, node.line, errs)
          errs = check_expr_vars(node.condition, vars, node.line, errs)
          {errs, _} = walk_body(node.then_body, script, vars, errs)
          {errs, _} = walk_body(node.else_body, script, vars, errs)
          {errs, vars}
      end
    end)
  end

  defp walk_step(%Step{} = step, script, vars, errors) do
    errors =
      Enum.reduce(step.calls, errors, fn {endpoint, _cmd}, acc ->
        if Map.has_key?(script.endpoints, endpoint) do
          acc
        else
          [
            Error.new(
              :undeclared_endpoint,
              "step #{step.id} calls undeclared endpoint #{inspect(endpoint)}",
              {step.line, 1}
            )
            | acc
          ]
        end
      end)

    Enum.reduce(step.statements, errors, fn
      %Assign{var: var, expr: expr, line: line}, acc ->
        acc =
          if MapSet.member?(vars, var) do
            acc
          else
            [
              Error.new(
                :undeclared_var,
                "assignment to undeclared variable #{inspect(var)}",
                {line, 1}
              )
              | acc
            ]
          end

        check_expr_vars(expr, vars, line, acc)

      %Call{args: args, line: line}, acc ->
        Enum.reduce(args, acc, fn {_n, expr}, a -> check_expr_vars(expr, vars, line, a) end)
    end)
  end

  # R5.2 — conditions must be pure
  defp check_condition(expr, line, errors) do
    case Parser.calls_in_expr(expr) do
      [] ->
        errors

      _ ->
        [
          Error.new(
            :call_in_condition,
            "call() is not allowed in conditions — conditions must be pure",
            {line, 1}
          )
          | errors
        ]
    end
  end

  defp check_expr_vars(expr, vars, line, errors) do
    expr
    |> vars_in_expr()
    |> Enum.reduce(errors, fn name, acc ->
      if MapSet.member?(vars, name) do
        acc
      else
        [Error.new(:undeclared_var, "undeclared variable #{inspect(name)}", {line, 1}) | acc]
      end
    end)
  end

  defp vars_in_expr({:var, [head | _]}), do: [head]
  defp vars_in_expr({:not, e}), do: vars_in_expr(e)
  defp vars_in_expr({:op, _op, l, r}), do: vars_in_expr(l) ++ vars_in_expr(r)
  defp vars_in_expr({:lit_list, es}), do: Enum.flat_map(es, &vars_in_expr/1)

  defp vars_in_expr({:call, _e, _c, args}),
    do: Enum.flat_map(args, fn {_n, a} -> vars_in_expr(a) end)

  defp vars_in_expr(_), do: []

  # -- outputs ---------------------------------------------------------------

  defp check_outputs(errors, script, var_names) do
    Enum.reduce(script.outputs, errors, fn out, acc ->
      acc =
        case Parser.calls_in_expr(out.expr) do
          [] ->
            acc

          _ ->
            [
              Error.new(
                :call_in_outputs,
                "call() is not allowed in outputs — side effects belong in steps",
                {out.line, 1}
              )
              | acc
            ]
        end

      check_expr_vars(out.expr, var_names, out.line, acc)
    end)
  end
end
