defmodule CcxtExtract.ClockTest do
  use ExUnit.Case, async: false

  alias CcxtExtract.Clock

  setup do
    prior_extracted_at = Application.get_env(:ccxt_extract, :extracted_at)

    on_exit(fn ->
      case prior_extracted_at do
        nil -> Application.delete_env(:ccxt_extract, :extracted_at)
        value -> Application.put_env(:ccxt_extract, :extracted_at, value)
      end
    end)

    :ok
  end

  test "timestamp/1 returns the frozen application env value when present" do
    Application.put_env(:ccxt_extract, :extracted_at, "2026-04-15T12:00:00Z")

    assert Clock.timestamp(:extracted_at) == "2026-04-15T12:00:00Z"
  end

  test "timestamp/0 uses the extracted_at key" do
    Application.put_env(:ccxt_extract, :extracted_at, "2026-04-15T12:00:00Z")

    assert Clock.timestamp() == "2026-04-15T12:00:00Z"
  end

  test "timestamp/1 defaults to an ISO8601 wall-clock value" do
    Application.delete_env(:ccxt_extract, :extracted_at)

    assert {:ok, _datetime, _offset} = DateTime.from_iso8601(Clock.timestamp(:extracted_at))
  end
end
