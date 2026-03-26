defmodule CcxtExtractTest do
  use ExUnit.Case

  test "project compiles" do
    assert is_list(Application.spec(:ccxt_extract, :modules))
  end
end
