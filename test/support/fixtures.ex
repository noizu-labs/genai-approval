defmodule GenAI.Approval.Fixtures do
  @moduledoc false

  alias GenAI.Approval.Permission
  alias GenAI.Approval.Permission.Store.ETS

  @worked_example """
  {{!-- preamble --}}
  {{#endpoint "github"}}
    transport = "streamable_http"
    url       = "https://mcp.github.internal/mcp"
    auth      = credential("github-bot")
  {{/endpoint}}

  {{#endpoint "notify"}}
    transport = "local"
  {{/endpoint}}

  {{#vars}}
    repo      : string  = "noizu/genai_core"
    urgent    : boolean = false
    issue     : object?
  {{/vars}}

  {{#step "Find the open release issue" breakpoint=true}}
    {{assign issue = call("github", "issues.search",
        repo=repo, query="release", state="open")}}
  {{/step}}

  {{#if issue}}
    {{#step "Comment on the existing issue"}}
      {{call "github" "issues.comment"
          repo=repo, number=issue.number, body="Release approved by operator."}}
    {{/step}}
  {{else}}
    {{#step "Create the release issue" note="Only reached when no issue exists"}}
      {{assign issue = call("github", "issues.create",
          repo=repo, title="Release", labels=["release"])}}
    {{/step}}
  {{/if}}

  {{#if urgent}}
    {{#step "Page the on-call"}}
      {{call "notify" "oncall.page" message="Urgent release approved"}}
    {{/step}}
  {{/if}}

  {{#outputs}}
    issue_number = issue.number
    approved     = true
  {{/outputs}}
  """

  def worked_example, do: @worked_example

  @doc "A local-only script builder: steps calling the \"local\" endpoint."
  def local_script(body, extra \\ "") do
    """
    {{#endpoint "local"}}
      transport = "local"
    {{/endpoint}}
    #{extra}
    #{body}
    """
  end

  def allow_all_store do
    table = ETS.new()

    :ok =
      ETS.put(
        table,
        Permission.new(pattern: "*:*", effect: :allow, scope: :always, granted_by: "test")
      )

    {GenAI.Approval.Permission.Store.ETS, table}
  end

  def empty_store do
    {GenAI.Approval.Permission.Store.ETS, ETS.new()}
  end
end
