defmodule OpenrouterSdk.MixProject do
  use Mix.Project

  @version "0.1.4"
  @source_url "https://github.com/sf-voice/openrouter-elixir-sdk"

  def project do
    [
      app: :openrouter_sdk,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url,
      name: "OpenRouter SDK"
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :public_key, :ssl, :inets],
      mod: {OpenrouterSdk.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:finch, "~> 0.18"},
      {:telemetry, "~> 1.2"},
      # jason is optional — we prefer the built-in JSON module on elixir 1.18+
      {:jason, "~> 1.4", optional: true},
      {:bypass, "~> 2.1", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Unofficial Elixir SDK for the OpenRouter API: chat, anthropic messages, " <>
      "embeddings, speech, transcription, OAuth PKCE, and a versioned " <>
      "model/provider catalog. Not affiliated with or endorsed by the " <>
      "OpenRouter team. Maintained by the San Francisco Voice Company."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md"]
    ]
  end
end
