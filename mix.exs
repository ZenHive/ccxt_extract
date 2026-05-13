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
      dialyzer: [
        # OOM mitigation: skip transitive deps. tidewave + bandit (dev) drag in
        # plug, finch, mint, gun, hpax, cowlib, websock, mime — none in lib/'s
        # call graph. Default :app_tree bloats the PLT to ~800 modules.
        plt_add_deps: :apps_direct,
        plt_add_apps: [:mix, :ex_unit],
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        ignore_warnings: ".dialyzer_ignore.exs"
      ]
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
      {:oxc, "~> 0.12.1"},
      {:quickbeam, "~> 0.10.11"},
      {:npm, "~> 0.7.1"},

      # JSON
      {:jason, "~> 1.4"},

      # Validation — runtime: false because the OTP app doesn't need JSV at runtime,
      # only mix tasks (ccxt_extract.validate) and tests use it
      {:jsv, "~> 0.19.0", runtime: false},

      # Dev/test tooling
      {:ex_unit_json, "~> 0.4", only: [:dev, :test], runtime: false},
      {:dialyzer_json, "~> 0.2", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7.18", only: [:dev, :test], runtime: false, override: true},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40.2", only: :dev, runtime: false},
      {:doctor, "~> 0.22", only: [:dev, :test], runtime: false},

      # Code analysis tools
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      {:ex_ast, "~> 0.11.2", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.3.0", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.3", only: [:dev, :test], runtime: false},
      {:tidewave, "~> 0.5", only: :dev},
      {:bandit, "~> 1.10", only: :dev}
    ]
  end

  defp aliases do
    [
      # `ccxt_extract.update` internally runs `ccxt_extract.setup` in Stage 1
      # (lib/mix/tasks/ccxt_extract.update.ex:131), so listing setup explicitly
      # here would double-run it. `deps.get` is the only additional step.
      setup: ["deps.get", "ccxt_extract.update"],
      "ccxt_extract.regenerate_fixtures": ["ccxt_extract.signing_fixtures"],
      tidewave: [
        "run --no-halt -e 'Agent.start(fn -> Bandit.start_link(plug: Tidewave, port: 4002) end)'"
      ]
    ]
  end
end
