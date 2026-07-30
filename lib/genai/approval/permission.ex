defmodule GenAI.Approval.Permission do
  @moduledoc """
  Allow/block command rules and their resolution (PRD §8).

  Resolution order (normative, §8.2):

    1. More specific pattern wins — `"github:issues.create"` beats
       `"github:issues.*"` beats `"github:*"` beats `"*:*"`. Command
       specificity dominates endpoint specificity.
    2. Block beats allow at equal specificity.
    3. Narrower scope beats wider at equal specificity + effect
       (`:call` > `:session` > `{:until, _}` > `:always`).
    4. No matching rule ⇒ `:ask` (default-deny: never default-allow).
    5. Expired `{:until, t}` rules never match (and stores prune them lazily).
  """

  defmodule Rule do
    @moduledoc "One allow/block rule. `pattern` is `\"endpoint:command\"` with glob support."
    @type scope :: :call | :session | {:until, DateTime.t()} | :always

    @type t :: %__MODULE__{
            id: String.t(),
            pattern: String.t(),
            effect: :allow | :block,
            scope: scope(),
            subject: String.t() | nil,
            session_id: String.t() | nil,
            granted_by: String.t() | nil,
            granted_at: DateTime.t() | nil,
            reason: String.t() | nil
          }

    defstruct [
      :id,
      :pattern,
      :effect,
      :scope,
      :subject,
      :session_id,
      :granted_by,
      :granted_at,
      :reason
    ]
  end

  @doc """
  Decide the outcome for `endpoint:command` given candidate rules.

  Returns `{:allow, rule}`, `{:block, rule}`, or `:ask`.
  """
  @spec decide([Rule.t()], String.t(), String.t(), DateTime.t()) ::
          {:allow, Rule.t()} | {:block, Rule.t()} | :ask
  def decide(rules, endpoint, command, now \\ DateTime.utc_now()) do
    rules
    |> Enum.reject(&expired?(&1, now))
    |> Enum.filter(&matches?(&1.pattern, endpoint, command))
    |> Enum.sort_by(&sort_key/1)
    |> case do
      [] -> :ask
      [winner | _] -> {winner.effect, winner}
    end
  end

  @doc "Does a rule pattern match the given endpoint + command?"
  @spec matches?(String.t(), String.t(), String.t()) :: boolean()
  def matches?(pattern, endpoint, command) do
    case String.split(pattern, ":", parts: 2) do
      [ep_pat, cmd_pat] -> ep_match?(ep_pat, endpoint) and cmd_match?(cmd_pat, command)
      _ -> false
    end
  end

  @doc "True when the rule's time scope has lapsed."
  @spec expired?(Rule.t(), DateTime.t()) :: boolean()
  def expired?(%Rule{scope: {:until, until}}, now), do: DateTime.compare(now, until) != :lt
  def expired?(%Rule{}, _now), do: false

  @doc "Build a rule with generated id + timestamp."
  @spec new(keyword()) :: Rule.t()
  def new(fields) do
    fields =
      fields
      |> Keyword.put_new_lazy(:id, fn ->
        "rule_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
      end)
      |> Keyword.put_new_lazy(:granted_at, &DateTime.utc_now/0)

    struct!(Rule, fields)
  end

  # -- ordering --------------------------------------------------------------

  # Elixir sorts ascending; smaller key = higher priority.
  defp sort_key(%Rule{} = rule) do
    {ep_pat, cmd_pat} = split_pattern(rule.pattern)

    {
      -cmd_specificity(cmd_pat),
      -ep_specificity(ep_pat),
      effect_rank(rule.effect),
      scope_rank(rule.scope),
      granted_at_rank(rule.granted_at)
    }
  end

  defp split_pattern(pattern) do
    case String.split(pattern, ":", parts: 2) do
      [ep, cmd] -> {ep, cmd}
      [only] -> {only, "*"}
    end
  end

  # exact >> glob-prefix (by literal segment count) >> "*"
  defp cmd_specificity("*"), do: 0

  defp cmd_specificity(cmd_pat) do
    if String.ends_with?(cmd_pat, ".*") do
      prefix = String.trim_trailing(cmd_pat, ".*")
      length(String.split(prefix, "."))
    else
      1_000_000 + byte_size(cmd_pat)
    end
  end

  defp ep_specificity("*"), do: 0
  defp ep_specificity(_exact), do: 1

  defp effect_rank(:block), do: 0
  defp effect_rank(:allow), do: 1

  defp scope_rank(:call), do: 0
  defp scope_rank(:session), do: 1
  defp scope_rank({:until, _}), do: 2
  defp scope_rank(:always), do: 3

  defp granted_at_rank(nil), do: 0
  defp granted_at_rank(%DateTime{} = dt), do: -DateTime.to_unix(dt, :millisecond)

  defp ep_match?("*", _endpoint), do: true
  defp ep_match?(pat, endpoint), do: pat == endpoint

  defp cmd_match?("*", _command), do: true

  defp cmd_match?(pat, command) do
    if String.ends_with?(pat, ".*") do
      prefix = String.trim_trailing(pat, ".*")
      command == prefix or String.starts_with?(command, prefix <> ".")
    else
      pat == command
    end
  end
end
