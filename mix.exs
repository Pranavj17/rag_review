defmodule RagReview.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/Pranavj17/rag_review"

  def project do
    [
      app: :rag_review,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: [main_module: RagReview.CLI],

      # Hex
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  defp description do
    """
    RAG-based code review tool using local LLMs. Indexes codebases into ChromaDB
    for semantic search and provides relevant context to improve code review quality.
    """
  end

  defp package do
    [
      name: "rag_review",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "docs/how-it-works.md"],
      source_url: @source_url,
      source_ref: "v#{@version}"
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
      {:cachex, "~> 3.6"},

      # Documentation
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end
end
