defmodule GenAI.Approval.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/noizu-labs/genai-approval"

  def project do
    [
      app: :genai_approval,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "GenAI Approval",
      description:
        "Interactive approval scripts for agents: a non-Turing-complete, steppable " <>
          "script format a human drives call-by-call, plus scoped allow/block command permissions.",
      source_url: @source_url,
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url}
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {GenAI.Approval.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:telemetry, "~> 1.2"},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
