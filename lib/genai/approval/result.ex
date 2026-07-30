defmodule GenAI.Approval.Result do
  @moduledoc """
  Result-contract helpers (PRD §9).

  `sanitize/1` converts a run result (or any engine term) into a
  JSON-serializable map: string keys, ISO-8601 datetimes, atoms as strings,
  tuples/pids/refs inspected. Used by the MCP `submit_approval_script` tool
  to return the result as structured content, and useful for any host that
  needs to ship results over a wire.
  """

  @spec sanitize(term()) :: term()
  def sanitize(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def sanitize(%Date{} = d), do: Date.to_iso8601(d)
  def sanitize(%MapSet{} = set), do: set |> MapSet.to_list() |> sanitize()

  def sanitize(%_struct{} = struct) do
    struct |> Map.from_struct() |> sanitize()
  end

  def sanitize(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {sanitize_key(k), sanitize(v)} end)
  end

  def sanitize(list) when is_list(list), do: Enum.map(list, &sanitize/1)

  def sanitize(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  def sanitize(nil), do: nil
  def sanitize(atom) when is_atom(atom), do: Atom.to_string(atom)
  def sanitize(other), do: inspect(other)

  defp sanitize_key(key) when is_binary(key), do: key
  defp sanitize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp sanitize_key(key), do: inspect(key)
end
