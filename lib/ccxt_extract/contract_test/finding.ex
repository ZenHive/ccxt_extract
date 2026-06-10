defmodule CcxtExtract.ContractTest.Finding do
  @moduledoc """
  A single `CcxtExtract.ContractTest` invariant violation.

  Promoted from a bare `{exchange, invariant, path, message}` map (Task 109)
  so every builder site is key-validated at compile time via `@enforce_keys`
  instead of relying on the post-edit `struct-hint` hook. `@derive
  Jason.Encoder` keeps `priv/output/_contract_test_report.json` free of
  `__struct__` keys when a finding is encoded directly.
  """

  @derive Jason.Encoder
  @enforce_keys [:exchange, :invariant, :path, :message]
  defstruct [:exchange, :invariant, :path, :message]

  @type t :: %__MODULE__{
          exchange: String.t(),
          invariant: String.t(),
          path: String.t(),
          message: String.t()
        }
end
