defmodule GenAI.Approval.Error do
  @moduledoc """
  Structured error for script rejection (parse + static checks).

  Every error carries a machine-readable `code`, a human `message`, and the
  `line`/`column` of the offending construct (PRD R5.8). Codes are stable API.
  """

  @type code ::
          :script_too_large
          | :too_many_steps
          | :unterminated
          | :unexpected_text
          | :unexpected_token
          | :unknown_block
          | :section_order
          | :stmt_outside_step
          | :call_in_condition
          | :call_in_outputs
          | :undeclared_endpoint
          | :duplicate_endpoint
          | :undeclared_var
          | :duplicate_var
          | :type_mismatch
          | :auth_literal
          | :invalid_endpoint
          | :unknown_type

  @type t :: %__MODULE__{
          code: code(),
          message: String.t(),
          line: pos_integer() | nil,
          column: pos_integer() | nil
        }

  defstruct [:code, :message, :line, :column]

  def new(code, message, {line, column}) do
    %__MODULE__{code: code, message: message, line: line, column: column}
  end

  def new(code, message, nil) do
    %__MODULE__{code: code, message: message}
  end
end
