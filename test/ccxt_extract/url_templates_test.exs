defmodule CcxtExtract.UrlTemplatesTest do
  @moduledoc """
  Unit tests for UrlTemplates pure functions.
  Uses synthetic data — no QuickBEAM runtime.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.UrlTemplates

  @sample_results [
    %{
      "id" => "binance",
      "url_templates" => %{
        "public" => %{
          "api_param" => "public",
          "http_method" => "GET",
          "sample_path" => "ticker/price",
          "resolved_url" => "https://api.binance.com/api/v3/ticker/price",
          "url_prefix" => "https://api.binance.com/api/v3/"
        },
        "private" => %{
          "api_param" => "private",
          "http_method" => "GET",
          "sample_path" => "account",
          "resolved_url" => nil,
          "url_prefix" => nil
        }
      }
    },
    %{
      "id" => "okx",
      "url_templates" => %{
        "public" => %{
          "api_param" => "public",
          "http_method" => "GET",
          "sample_path" => "market/tickers",
          "resolved_url" => "https://www.okx.com/api/v5/market/tickers",
          "url_prefix" => "https://www.okx.com/api/v5/"
        }
      }
    },
    %{
      "id" => "gate",
      "url_templates" => %{
        "public.spot" => %{
          "api_param" => ["public", "spot"],
          "http_method" => "GET",
          "sample_path" => "currencies",
          "resolved_url" => "https://api.gateio.ws/api/v4/spot/currencies",
          "url_prefix" => "https://api.gateio.ws/api/v4/spot/"
        }
      }
    },
    %{
      "id" => "emptyex",
      "url_templates" => %{}
    }
  ]

  describe "write!/1" do
    @tag :tmp_dir
    test "writes valid JSON with standard envelope", %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "url_templates.json")
      assert :ok = UrlTemplates.write!(@sample_results, output_path)

      data = output_path |> File.read!() |> Jason.decode!()

      assert is_binary(data["extracted_at"])
      assert data["count"] == 4
      assert is_list(data["exchanges"])
      assert length(data["exchanges"]) == 4
    end

    @tag :tmp_dir
    test "preserves exchange data structure", %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "url_templates.json")
      UrlTemplates.write!(@sample_results, output_path)

      data = output_path |> File.read!() |> Jason.decode!()
      okx = Enum.find(data["exchanges"], &(&1["id"] == "okx"))

      assert okx["url_templates"]["public"]["api_param"] == "public"
      assert okx["url_templates"]["public"]["http_method"] == "GET"
      assert okx["url_templates"]["public"]["sample_path"] == "market/tickers"
      assert okx["url_templates"]["public"]["resolved_url"] == "https://www.okx.com/api/v5/market/tickers"
      assert okx["url_templates"]["public"]["url_prefix"] == "https://www.okx.com/api/v5/"
    end

    @tag :tmp_dir
    test "preserves null fields for sign() failures", %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "url_templates.json")
      UrlTemplates.write!(@sample_results, output_path)

      data = output_path |> File.read!() |> Jason.decode!()
      binance = Enum.find(data["exchanges"], &(&1["id"] == "binance"))

      assert binance["url_templates"]["private"]["resolved_url"] == nil
      assert binance["url_templates"]["private"]["url_prefix"] == nil
      # Inputs are always present even when sign() fails
      assert binance["url_templates"]["private"]["api_param"] == "private"
      assert binance["url_templates"]["private"]["http_method"] == "GET"
      assert binance["url_templates"]["private"]["sample_path"] == "account"
    end

    @tag :tmp_dir
    test "preserves array api_param for multi-level sections", %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "url_templates.json")
      UrlTemplates.write!(@sample_results, output_path)

      data = output_path |> File.read!() |> Jason.decode!()
      gate = Enum.find(data["exchanges"], &(&1["id"] == "gate"))

      assert gate["url_templates"]["public.spot"]["api_param"] == ["public", "spot"]
    end

    @tag :tmp_dir
    test "handles empty results", %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "url_templates.json")
      assert :ok = UrlTemplates.write!([], output_path)

      data = output_path |> File.read!() |> Jason.decode!()

      assert data["count"] == 0
      assert data["exchanges"] == []
    end

    @tag :tmp_dir
    test "creates parent directories", %{tmp_dir: tmp_dir} do
      output_path = Path.join([tmp_dir, "nested", "dir", "url_templates.json"])
      assert :ok = UrlTemplates.write!(@sample_results, output_path)
      assert File.exists?(output_path)
    end
  end

  describe "output shape" do
    test "each exchange entry has id and url_templates keys" do
      for entry <- @sample_results do
        assert Map.has_key?(entry, "id")
        assert Map.has_key?(entry, "url_templates")
        assert is_binary(entry["id"])
        assert is_map(entry["url_templates"])
      end
    end

    test "each url_template entry has all required keys" do
      required_keys = ~w(api_param http_method sample_path resolved_url url_prefix)

      for entry <- @sample_results,
          {_section, template} <- entry["url_templates"] do
        for key <- required_keys do
          assert Map.has_key?(template, key), "Missing key #{key} in #{entry["id"]}"
        end

        assert is_binary(template["sample_path"])
        assert is_binary(template["http_method"])
        assert is_binary(template["resolved_url"]) or is_nil(template["resolved_url"])
        assert is_binary(template["url_prefix"]) or is_nil(template["url_prefix"])
        assert is_binary(template["api_param"]) or is_list(template["api_param"])
      end
    end
  end

  describe "url_prefix correctness (discovery data)" do
    @tag :extraction
    test "url_prefix is consistent with resolved_url and sample_path" do
      path = CcxtExtract.Paths.priv("discoveries/url_templates.json")

      if not File.exists?(path) do
        flunk("""
        Missing discovery data!

        Run extraction first:
          mix ccxt_extract.url_templates
        """)
      end

      data = path |> File.read!() |> Jason.decode!()

      for_result =
        for %{"id" => id, "url_templates" => templates} <- data["exchanges"],
            {section, entry} <- templates,
            not is_nil(entry["url_prefix"]) do
          # One-shot suffix subtraction matching JS semantics (not trim_trailing which repeats)
          resolved = entry["resolved_url"]
          sample = entry["sample_path"]
          expected = String.slice(resolved, 0, String.length(resolved) - String.length(sample))

          if entry["url_prefix"] != expected do
            "#{id}.#{section}: url_prefix #{inspect(entry["url_prefix"])} != expected #{inspect(expected)}"
          end
        end

      violations = Enum.reject(for_result, &is_nil/1)

      assert violations == [],
             "url_prefix inconsistencies found:\n  #{Enum.join(violations, "\n  ")}"
    end

    @tag :extraction
    test "url_prefix is null when resolved_url doesn't end with sample_path" do
      path = CcxtExtract.Paths.priv("discoveries/url_templates.json")

      if not File.exists?(path) do
        flunk("""
        Missing discovery data!

        Run extraction first:
          mix ccxt_extract.url_templates
        """)
      end

      data = path |> File.read!() |> Jason.decode!()

      # For entries where resolved_url doesn't end with sample_path,
      # url_prefix must be null (suffix-mutation exchanges)
      violations =
        for %{"id" => id, "url_templates" => templates} <- data["exchanges"],
            {section, entry} <- templates,
            not is_nil(entry["resolved_url"]),
            not String.ends_with?(entry["resolved_url"], entry["sample_path"]),
            not is_nil(entry["url_prefix"]) do
          "#{id}.#{section}: url_prefix should be null (suffix mutation) but is #{inspect(entry["url_prefix"])}"
        end

      assert violations == [],
             "url_prefix should be null for suffix-mutated URLs:\n  #{Enum.join(violations, "\n  ")}"
    end
  end
end
