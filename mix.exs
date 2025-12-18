defmodule RagReview.MixProject do
  use Mix.Project

  def project do
    [
      app: :rag_review,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: [main_module: RagReview.CLI]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {RagReview.Application, []}
    ]
  end

  defp deps do
    [
      # HTTP client
      {:req, "~> 0.5"},

      # ChromaDB client
      {:chroma, "~> 0.1.3"},

      # JSON
      {:jason, "~> 1.4"},

      # Caching for embeddings
      {:cachex, "~> 3.6"}
    ]
  end
end
