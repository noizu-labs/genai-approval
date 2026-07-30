defmodule GenAI.Approval.ParserTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias GenAI.Approval.{Error, Fixtures, Script}
  alias GenAI.Approval.Script.{Assign, Call, If, Step}

  defp errors_for(source, opts) do
    assert {:error, errors} = GenAI.Approval.load(source, opts)
    errors
  end

  defp assert_code(source, code, opts \\ []) do
    errors = errors_for(source, opts)

    assert Enum.any?(errors, &(&1.code == code)),
           "expected #{inspect(code)} in #{inspect(Enum.map(errors, & &1.code))}"

    error = Enum.find(errors, &(&1.code == code))
    assert is_integer(error.line), "error #{inspect(code)} missing line"
    assert is_binary(error.message)
    error
  end

  describe "AC1 — worked example golden parse" do
    test "parses to the documented structure" do
      assert {:ok, %Script{} = script} = GenAI.Approval.load(Fixtures.worked_example())

      # endpoints
      assert Map.keys(script.endpoints) |> Enum.sort() == ["github", "notify"]
      github = script.endpoints["github"]
      assert github.transport == "streamable_http"
      assert github.url == "https://mcp.github.internal/mcp"
      assert github.auth == {:credential, "github-bot"}
      assert script.endpoints["notify"].transport == "local"

      # vars
      assert [repo, urgent, issue] = script.vars
      assert {repo.name, repo.type, repo.default} == {"repo", "string", "noizu/genai_core"}
      assert {urgent.name, urgent.type, urgent.default} == {"urgent", "boolean", false}
      assert {issue.name, issue.type, issue.nullable} == {"issue", "object", true}
      refute issue.has_default

      # body shape: step, if/else, if
      assert [%Step{id: "s1"}, %If{} = if1, %If{} = if2] = script.body
      assert if1.condition == {:var, ["issue"]}
      assert [%Step{id: "s2"}] = if1.then_body
      assert [%Step{id: "s3", attrs: %{"note" => _}}] = if1.else_body
      assert if2.condition == {:var, ["urgent"]}
      assert [%Step{id: "s4"}] = if2.then_body

      # step 1: assign with call-expr, breakpoint attr, extracted calls
      s1 = hd(script.body)
      assert s1.attrs["breakpoint"] == true

      assert [%Assign{var: "issue", expr: {:call, "github", "issues.search", args}}] =
               s1.statements

      assert {"repo", {:var, ["repo"]}} in args
      assert {"query", {:lit, "release"}} in args
      assert s1.calls == [{"github", "issues.search"}]

      # step 2: call statement with dotted path arg
      [s2] = if1.then_body
      assert [%Call{endpoint: "github", command: "issues.comment", args: args2}] = s2.statements
      assert {"number", {:var, ["issue", "number"]}} in args2

      # step 3: list literal arg
      [s3] = if1.else_body
      assert [%Assign{expr: {:call, "github", "issues.create", args3}}] = s3.statements
      assert {"labels", {:lit_list, [lit: "release"]}} in args3

      # steps flattened in document order
      assert Enum.map(script.steps, & &1.id) == ["s1", "s2", "s3", "s4"]

      # outputs
      assert [out1, out2] = script.outputs
      assert {out1.name, out1.expr} == {"issue_number", {:var, ["issue", "number"]}}
      assert {out2.name, out2.expr} == {"approved", {:lit, true}}
    end
  end

  describe "AC2 — rejections (R5.1–R5.9)" do
    test "loop-like blocks do not exist (R5.1)" do
      source = Fixtures.local_script("{{#each items}}{{/each}}")
      assert_code(source, :unknown_block)
    end

    test "call statement outside a step (R5.2)" do
      source = Fixtures.local_script(~s[{{call "local" "cmd"}}])
      assert_code(source, :stmt_outside_step)
    end

    test "assign outside a step" do
      source = Fixtures.local_script(~s[{{assign x = 1}}])
      assert_code(source, :stmt_outside_step)
    end

    test "call() inside an if condition (R5.2)" do
      source =
        Fixtures.local_script("""
        {{#if call("local", "check")}}
        {{/if}}
        """)

      assert_code(source, :call_in_condition)
    end

    test "call() inside outputs (R5.6)" do
      source =
        Fixtures.local_script("""
        {{#outputs}}
          x = call("local", "fetch")
        {{/outputs}}
        """)

      assert_code(source, :call_in_outputs)
    end

    test "undeclared endpoint alias (R5.3)" do
      source =
        Fixtures.local_script("""
        {{#step "s"}}
          {{call "ghost" "cmd"}}
        {{/step}}
        """)

      assert_code(source, :undeclared_endpoint)
    end

    test "inline auth secret is rejected (R5.4)" do
      source = """
      {{#endpoint "x"}}
        transport = "streamable_http"
        auth = "sk-secret-value"
      {{/endpoint}}
      """

      assert_code(source, :auth_literal)
    end

    test "type-mismatched var default (R5.5)" do
      source =
        Fixtures.local_script("", """
        {{#vars}}
          count : number = "three"
        {{/vars}}
        """)

      assert_code(source, :type_mismatch)
    end

    test "null default requires nullable marker (R5.5)" do
      source =
        Fixtures.local_script("", """
        {{#vars}}
          maybe : string = null
        {{/vars}}
        """)

      assert_code(source, :type_mismatch)
    end

    test "unknown type" do
      source =
        Fixtures.local_script("", """
        {{#vars}}
          x : widget
        {{/vars}}
        """)

      assert_code(source, :unknown_type)
    end

    test "assignment to undeclared variable (R5.5)" do
      source =
        Fixtures.local_script("""
        {{#step "s"}}
          {{assign ghost = 1}}
        {{/step}}
        """)

      assert_code(source, :undeclared_var)
    end

    test "undeclared variable in outputs" do
      source =
        Fixtures.local_script("""
        {{#outputs}}
          x = ghost.field
        {{/outputs}}
        """)

      assert_code(source, :undeclared_var)
    end

    test "oversized script (R5.9)" do
      source = Fixtures.local_script("")
      assert_code(source, :script_too_large, max_script_size: 10)
    end

    test "too many steps (R5.9)" do
      source =
        Fixtures.local_script(
          """
          {{#step "one"}}{{assign x = 1}}{{/step}}
          {{#step "two"}}{{assign x = 2}}{{/step}}
          """,
          "{{#vars}} x : number = 0 {{/vars}}"
        )

      assert_code(source, :too_many_steps, max_steps: 1)
    end

    test "stray text in the body" do
      source = Fixtures.local_script("hello there")
      assert_code(source, :unexpected_text)
    end

    test "unterminated step block" do
      source = Fixtures.local_script(~s[{{#step "s"}} {{assign x = 1}}])
      assert_code(source, :unterminated)
    end

    test "duplicate endpoint" do
      source = """
      {{#endpoint "a"}} transport = "local" {{/endpoint}}
      {{#endpoint "a"}} transport = "local" {{/endpoint}}
      """

      assert_code(source, :duplicate_endpoint)
    end

    test "duplicate variable" do
      source =
        Fixtures.local_script("", """
        {{#vars}}
          x : number = 1
          x : number = 2
        {{/vars}}
        """)

      assert_code(source, :duplicate_var)
    end

    test "endpoint missing transport" do
      source = """
      {{#endpoint "a"}} url = "https://x" {{/endpoint}}
      """

      assert_code(source, :invalid_endpoint)
    end

    test "errors carry machine-readable code, message, line (R5.8)" do
      %Error{} = error = assert_code(Fixtures.local_script("stray"), :unexpected_text)
      assert error.line >= 1
      assert error.column >= 1
    end
  end

  describe "AC3 — parser robustness" do
    property "never raises on arbitrary printable input" do
      check all(source <- StreamData.string(:printable, max_length: 500), max_runs: 300) do
        case GenAI.Approval.load(source) do
          {:ok, _} -> :ok
          {:error, errors} -> assert is_list(errors)
        end
      end
    end

    property "never raises on mustache-dense input" do
      fragments =
        StreamData.member_of([
          "{{",
          "}}",
          "{{#step",
          "{{/step}}",
          "\"s\"",
          "{{#if x}}",
          "{{else}}",
          "{{/if}}",
          "{{assign x = 1}}",
          "call(",
          ")",
          "=",
          "x",
          " ",
          "\n",
          "{{!-- c --}}"
        ])

      check all(parts <- StreamData.list_of(fragments, max_length: 30), max_runs: 300) do
        source = Enum.join(parts)

        case GenAI.Approval.load(source) do
          {:ok, _} -> :ok
          {:error, errors} -> assert is_list(errors)
        end
      end
    end
  end
end
