defmodule Mix.Tasks.CcxtExtract.ValidateFixturesTaskTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.CcxtExtract.ValidateFixtures, as: Task

  test "rejects unknown options" do
    assert_raise Mix.Error, ~r/Unknown option/, fn ->
      Task.run(["--bogus", "x"])
    end
  end

  test "rejects unexpected leftover arguments" do
    assert_raise Mix.Error, ~r/Unexpected argument/, fn ->
      Task.run(["random-leftover"])
    end
  end

  # Regression for the default report path landing inside the fixtures
  # directory, which made the next run treat it as an extra fixture.
  test "default report path lives outside the fixtures directory" do
    fixtures_default = CcxtExtract.Paths.priv("fixtures/signing")
    report_default = CcxtExtract.Paths.priv("discoveries/fixture_parity_report.json")

    refute String.starts_with?(report_default, fixtures_default <> "/"),
           "default report path must not be nested inside fixtures dir"
  end
end
