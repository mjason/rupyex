defmodule Rupyex.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/mjason/rupyex"

  def project do
    [
      app: :rupyex,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Embed Python in Elixir with RustPython, via Rustler.",
      package: package(),
      docs: docs(),
      name: "Rupyex",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:rustler_precompiled, "~> 0.9"},
      {:rustler, "~> 0.38", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib guides native/rupyex_nif/src native/rupyex_nif/Cargo.toml
                native/rupyex_nif/Cargo.lock checksum-Elixir.Rupyex.Native.exs
                mix.exs README.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "guides/data_exchange.md"],
      groups_for_modules: [
        Values: [Rupyex.Bytes, Rupyex.Object, Rupyex.Set, Rupyex.Result],
        Internals: [Rupyex.Native]
      ]
    ]
  end
end
