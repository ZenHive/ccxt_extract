defmodule CcxtExtract.HandleErrorsLoadDescribeTest do
  @moduledoc """
  Disk-read tests for `HandleErrors.load_describe_exceptions/1` — the
  step that lifts `describe().exceptions` and `describe().httpExceptions`
  into the handle_errors extraction.

  `async: false`: every test points `:priv_dir_override` at a tmp
  `priv/discoveries/describe/` so we can seed a synthetic describe file.
  The override is VM-global app env.

  Regression coverage for the `__function:` sentinel: CCXT declares
  `httpExceptions` values as bare JS class identifiers (e.g.
  `'422': ExchangeError`), and QuickBEAM serializes those as
  `"__function:<ClassName>"`. The flat-parents lookup in
  `ContractTest.check_error_classes_covered_by_hierarchy` is a bare-
  string match, so the sentinel must be stripped at the extraction
  boundary or the contract test fails.
  """
  use ExUnit.Case, async: false

  alias CcxtExtract.HandleErrors

  setup do
    tmp = Path.join(System.tmp_dir!(), "ccxt_handle_errors_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([tmp, "discoveries", "describe"]))
    prior = Application.get_env(:ccxt_extract, :priv_dir_override)
    Application.put_env(:ccxt_extract, :priv_dir_override, tmp)

    on_exit(fn ->
      case prior do
        nil -> Application.delete_env(:ccxt_extract, :priv_dir_override)
        val -> Application.put_env(:ccxt_extract, :priv_dir_override, val)
      end

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  defp write_describe!(tmp, id, describe) do
    path = Path.join([tmp, "discoveries", "describe", "#{id}.json"])
    File.write!(path, Jason.encode!(%{"describe" => describe}))
  end

  describe "load_describe_exceptions/1 — __function: sentinel stripping" do
    test "strips sentinel from flat httpExceptions map", %{tmp: tmp} do
      write_describe!(tmp, "fake_a", %{
        "httpExceptions" => %{
          "401" => "__function:AuthenticationError",
          "429" => "__function:RateLimitExceeded",
          "404" => "BadRequest"
        }
      })

      assert {_exceptions, http_exceptions} = HandleErrors.load_describe_exceptions("fake_a")

      assert http_exceptions == %{
               "401" => "AuthenticationError",
               "429" => "RateLimitExceeded",
               "404" => "BadRequest"
             }
    end

    test "strips sentinel from 2-level exceptions map (exact/broad)", %{tmp: tmp} do
      write_describe!(tmp, "fake_b", %{
        "exceptions" => %{
          "exact" => %{
            "INVALID_KEY" => "__function:AuthenticationError",
            "BAD_REQ" => "BadRequest"
          },
          "broad" => %{
            "DDoS" => "__function:DDoSProtection"
          }
        }
      })

      assert {exceptions, _http} = HandleErrors.load_describe_exceptions("fake_b")

      assert exceptions == %{
               "exact" => %{
                 "INVALID_KEY" => "AuthenticationError",
                 "BAD_REQ" => "BadRequest"
               },
               "broad" => %{"DDoS" => "DDoSProtection"}
             }
    end

    test "strips sentinel from 3-level market-type-keyed exceptions", %{tmp: tmp} do
      write_describe!(tmp, "fake_c", %{
        "exceptions" => %{
          "linear" => %{
            "exact" => %{"E1" => "__function:InvalidOrder"}
          },
          "spot" => %{
            "broad" => %{"throttle" => "__function:RateLimitExceeded"}
          }
        }
      })

      assert {exceptions, _http} = HandleErrors.load_describe_exceptions("fake_c")

      assert exceptions == %{
               "linear" => %{"exact" => %{"E1" => "InvalidOrder"}},
               "spot" => %{"broad" => %{"throttle" => "RateLimitExceeded"}}
             }
    end

    test "passes through bare class names unchanged", %{tmp: tmp} do
      write_describe!(tmp, "fake_d", %{
        "exceptions" => %{"exact" => %{"X" => "ExchangeError"}},
        "httpExceptions" => %{"500" => "ExchangeError"}
      })

      assert {exceptions, http_exceptions} = HandleErrors.load_describe_exceptions("fake_d")

      assert exceptions == %{"exact" => %{"X" => "ExchangeError"}}
      assert http_exceptions == %{"500" => "ExchangeError"}
    end

    test "leaves `__function:` with empty suffix alone (malformed, not a class ref)", %{tmp: tmp} do
      # The sentinel always carries a class name from quickbeam_runtime.ex;
      # an empty suffix would be a malformed describe. Preserve verbatim
      # so any downstream surface that wants to flag it still can.
      write_describe!(tmp, "fake_e", %{
        "httpExceptions" => %{"599" => "__function:"}
      })

      assert {_exceptions, http_exceptions} = HandleErrors.load_describe_exceptions("fake_e")
      assert http_exceptions == %{"599" => "__function:"}
    end

    test "non-map describe.exceptions / describe.httpExceptions normalize to nil", %{tmp: tmp} do
      # QuickBEAM ships `"__undefined"` when a top-level key is absent on
      # the JS side; the pre-existing normalize_map/1 catches that.
      write_describe!(tmp, "fake_f", %{
        "exceptions" => "__undefined",
        "httpExceptions" => nil
      })

      assert {nil, nil} = HandleErrors.load_describe_exceptions("fake_f")
    end
  end
end
