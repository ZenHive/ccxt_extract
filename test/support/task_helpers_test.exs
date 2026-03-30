defmodule CcxtExtract.TaskHelpersTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.TaskHelpers

  describe "collect_shell_output/0" do
    test "collects info and error messages in arrival order" do
      send(self(), {:mix_shell, :info, ["first"]})
      send(self(), {:mix_shell, :error, ["second"]})
      send(self(), {:mix_shell, :info, ["third"]})

      assert TaskHelpers.collect_shell_output() == "first\nsecond\nthird"
    end
  end
end
