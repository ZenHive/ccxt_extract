defmodule CcxtExtract.PrivWriteCase do
  @moduledoc """
  Isolates writes for `:extraction`-tagged integration tests.

  Each test gets a fresh tmp directory assigned to
  `:ccxt_extract, :priv_write_override`. All call sites that write via
  `CcxtExtract.Paths.out/1` land under the tmp dir; reads via
  `CcxtExtract.Paths.priv/1` continue to hit the committed corpus.

  On exit the override is restored to its prior value (or deleted) and the
  tmp dir is removed.

      defmodule MyIntegrationTest do
        use CcxtExtract.PrivWriteCase
        import CcxtExtract.TaskHelpers

        @tag :extraction
        test "extracts and writes to tmp", %{tmp_priv: tmp} do
          run_task_capturing_output(Mix.Tasks.CcxtExtract.Exchanges)
          assert File.exists?(Path.join(tmp, "discoveries/exchanges.json"))
        end
      end

  `async: false` is enforced because `Application.put_env/2` is VM-global.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: false
    end
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "ccxt_priv_write_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    prior = Application.get_env(:ccxt_extract, :priv_write_override)
    Application.put_env(:ccxt_extract, :priv_write_override, tmp)

    on_exit(fn ->
      case prior do
        nil -> Application.delete_env(:ccxt_extract, :priv_write_override)
        val -> Application.put_env(:ccxt_extract, :priv_write_override, val)
      end

      File.rm_rf!(tmp)
    end)

    {:ok, tmp_priv: tmp}
  end
end
