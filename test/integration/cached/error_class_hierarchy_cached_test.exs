defmodule CcxtExtract.Integration.Cached.ErrorClassHierarchyCachedTest do
  @moduledoc """
  Cached integration tests for the error class hierarchy.

  Reads the committed discovery JSON at
  `priv/discoveries/error_class_hierarchy.json` and verifies envelope
  structure, well-known taxonomy fixtures, and the parent/ancestor
  contract — without re-running OXC or hitting CCXT source.
  """
  use ExUnit.Case, async: true

  @moduletag :integration
  @moduletag timeout: 30_000

  @fixture_path Path.join(CcxtExtract.Paths.discoveries(), "error_class_hierarchy.json")

  setup_all do
    data = @fixture_path |> File.read!() |> Jason.decode!()
    %{data: data}
  end

  describe "envelope structure" do
    test "has required top-level keys", %{data: data} do
      assert is_binary(data["extracted_at"])
      assert is_integer(data["class_count"])
      assert is_map(data["tree"])
      assert is_map(data["flat_parents"])
      assert is_map(data["ancestors"])
    end

    test "class_count matches flat_parents size", %{data: data} do
      assert data["class_count"] == map_size(data["flat_parents"])
    end

    test "flat_parents and ancestors cover the same class set", %{data: data} do
      assert MapSet.new(Map.keys(data["flat_parents"])) ==
               MapSet.new(Map.keys(data["ancestors"]))
    end

    test "class_count meets the floor for current CCXT", %{data: data} do
      # Concrete release at extraction time had 41 classes; future bumps
      # shouldn't fail the test, but a count drop signals regression.
      assert data["class_count"] >= 40
    end
  end

  describe "root + parent contract" do
    test "BaseError is the single root", %{data: data} do
      assert data["flat_parents"]["BaseError"] == nil
      roots = for {class, nil} <- data["flat_parents"], do: class
      assert Enum.sort(roots) == ["BaseError"]
    end

    test "every flat_parents value is either nil or a known class name", %{data: data} do
      known = MapSet.new(Map.keys(data["flat_parents"]))

      for {class, parent} <- data["flat_parents"] do
        assert is_nil(parent) or MapSet.member?(known, parent),
               "class #{class} has parent #{inspect(parent)} not in flat_parents"
      end
    end

    test "ancestors[c] is empty exactly for roots", %{data: data} do
      for {class, parent} <- data["flat_parents"] do
        chain = data["ancestors"][class]

        if is_nil(parent) do
          assert chain == [], "root #{class} should have empty ancestors, got #{inspect(chain)}"
        else
          refute chain == [], "non-root #{class} should have non-empty ancestors"
          assert hd(chain) == parent, "ancestors[#{class}] should start with parent #{parent}"
        end
      end
    end
  end

  describe "well-known taxonomy fixtures" do
    test "AccountNotEnabled is at depth 4 under BaseError", %{data: data} do
      assert data["ancestors"]["AccountNotEnabled"] == [
               "PermissionDenied",
               "AuthenticationError",
               "ExchangeError",
               "BaseError"
             ]
    end

    test "AuthenticationError descends from ExchangeError", %{data: data} do
      assert data["flat_parents"]["AuthenticationError"] == "ExchangeError"
    end

    test "RateLimitExceeded descends from NetworkError", %{data: data} do
      assert data["flat_parents"]["RateLimitExceeded"] == "NetworkError"
    end

    test "tree[BaseError] is a non-empty map", %{data: data} do
      assert is_map(data["tree"]["BaseError"])
      assert map_size(data["tree"]["BaseError"]) > 0
    end
  end
end
