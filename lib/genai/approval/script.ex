defmodule GenAI.Approval.Script do
  @moduledoc """
  Parsed approval script: AST + metadata.

  A script has four ordered sections — endpoint declarations (preamble), typed
  variable declarations, a body of steps and conditionals, and declared outputs.
  Expressions are data-only tuples (never code):

    * `{:lit, term}` — literal
    * `{:lit_list, [expr]}` — list literal
    * `{:var, [segment, ...]}` — dotted variable path
    * `{:not, expr}`
    * `{:op, op, left, right}` — `op` in `:== :!= :< :> :<= :>= :and :or`
    * `{:call, endpoint, command, [{name, expr}]}` — call expression (assign RHS only)
  """

  defmodule Endpoint do
    @moduledoc "Preamble endpoint declaration. `auth` is `{:credential, id}` — never a secret."
    defstruct [:name, :transport, :url, :auth, opts: %{}, line: nil]
  end

  defmodule VarDecl do
    @moduledoc "Typed variable declaration."
    defstruct [:name, :type, :default, nullable: false, has_default: false, line: nil]
  end

  defmodule Step do
    @moduledoc "One approvable unit. `calls` is the statically-extracted `{endpoint, command}` list."
    defstruct [
      :id,
      :title,
      statements: [],
      attrs: %{},
      calls: [],
      line: nil,
      end_line: nil
    ]
  end

  defmodule Assign do
    @moduledoc "`{{assign var = expr}}` — expr may be a call expression."
    defstruct [:var, :expr, line: nil]
  end

  defmodule Call do
    @moduledoc "`{{call \"endpoint\" \"command\" arg=expr ...}}` statement."
    defstruct [:endpoint, :command, args: [], line: nil]
  end

  defmodule If do
    @moduledoc "Conditional. `{{#unless}}` parses to an If with `negate: true`."
    defstruct [
      :condition,
      then_body: [],
      else_body: [],
      negate: false,
      line: nil,
      else_line: nil,
      end_line: nil
    ]
  end

  defmodule Output do
    @moduledoc "One declared output, evaluated at end of run."
    defstruct [:name, :expr, line: nil]
  end

  @type t :: %__MODULE__{}

  defstruct endpoints: %{},
            vars: [],
            body: [],
            outputs: [],
            steps: [],
            source: nil

  @doc "All steps in document order (includes steps inside both branch arms)."
  def collect_steps(body), do: do_collect(body, []) |> Enum.reverse()

  defp do_collect([], acc), do: acc

  defp do_collect([%Step{} = s | rest], acc), do: do_collect(rest, [s | acc])

  defp do_collect([%If{then_body: t, else_body: e} | rest], acc) do
    acc = do_collect(t, acc)
    acc = do_collect(e, acc)
    do_collect(rest, acc)
  end

  @doc "Steps contained in a (possibly nested) body — used to mark untaken branches."
  def step_ids(body), do: collect_steps(body) |> Enum.map(& &1.id)
end
