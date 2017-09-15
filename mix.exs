defmodule Nerves.IO.PN532.Mixfile do
  use Mix.Project

  @version "0.1.0"
  @url "https://github.com/jmerriweather/nerves_io_pn532"
  @maintainers ["Jonathan Merriweather"]

  def project do
    [app: :nerves_io_pn532,
     version: @version,
     elixir: "~> 1.3",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     description: description(),
     package: package(),
     deps: deps()]
  end

  defp package do
    [
      name: :nerves_io_pn532,
      maintainers: @maintainers,
      licenses: ["MIT"],
      links: %{"GitHub" => @url},
      files: ["lib", "mix.exs", "README*", "LICENSE*"]
    ]
  end

  defp description do
    """
    Elixir library to work with the NXP PN532 RFID module.
    """
  end

  def docs do
    [
      extras: ["README.md", "LICENSE.md"],
      source_ref: "v#{@version}",
      main: "readme"
    ]
  end

  # Configuration for the OTP application
  #
  # Type "mix help compile.app" for more information
  def application do
    [applications: [:logger, :nerves_uart]]
  end

  # Dependencies can be Hex packages:
  #
  #   {:mydep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:mydep, git: "https://github.com/elixir-lang/mydep.git", tag: "0.1.0"}
  #
  # Type "mix help deps" for more examples and options
  defp deps do
    [{:nerves_uart, "~> 0.1.2"},
     {:earmark, ">= 1.0.1", only: :dev},
     {:ex_doc, "~> 0.13", only: :dev}]
  end
end
