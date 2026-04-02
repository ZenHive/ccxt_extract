defmodule CcxtExtract.MixProject do
  use Mix.Project

  def project do
    [
      app: :ccxt_extract,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      dialyzer: [plt_add_apps: [:mix], ignore_warnings: ".dialyzer_ignore.exs"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [preferred_envs: ["test.json": :test, "dialyzer.json": :dev]]
  end

  defp deps do
    [
      # Core extraction tools
      {:oxc, "~> 0.5"},
      {:quickbeam, "~> 0.8"},
      {:npm, "~> 0.5"},

      # JSON
      {:jason, "~> 1.4"},

      # Validation — runtime: false because the OTP app doesn't need JSV at runtime,
      # only mix tasks (ccxt_extract.validate) and tests use it
      {:jsv, "~> 0.16", runtime: false},

      # Dev/test tooling
      {:ex_unit_json, "~> 0.4", only: [:dev, :test], runtime: false},
      {:dialyzer_json, "~> 0.1", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.4", only: [:dev, :test], runtime: false},
      # TODO(Task 37): Using git branch as workaround for Credo 1.7.x crash on Elixir 1.18+ multi-line sigils.
      # Switch back to hex {:credo, "~> 1.8"} when a compatible release is published.
      {:credo, github: "rrrene/credo", branch: "release/1.7", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.39", only: :dev, runtime: false},
      {:doctor, "~> 0.22", only: [:dev, :test], runtime: false},

      # Code analysis tools
      {:ex_dna, "~> 1.1", only: [:dev, :test], runtime: false},
      {:ex_ast, "~> 0.2", only: [:dev, :test], runtime: false},
      {:tidewave, "~> 0.5", only: :dev},
      {:bandit, "~> 1.10", only: :dev}
    ]
  end

  defp aliases do
    [
      tidewave: [
        "run --no-halt -e 'Agent.start(fn -> Bandit.start_link(plug: Tidewave, port: 4001) end)'"
      ]
    ]
  end
end
