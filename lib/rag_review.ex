defmodule RagReview do
  @moduledoc """
  RAG Review - Context-aware code review using local LLMs.

  This tool improves local LLM code reviews by:
  1. Indexing your codebase into semantic chunks
  2. Storing embeddings in ChromaDB
  3. Retrieving relevant context when reviewing diffs
  4. Generating reviews with full codebase awareness

  ## Quick Start

      # Index a repository
      {:ok, stats} = RagReview.index("/path/to/repo")

      # Review a diff
      diff = File.read!("changes.diff")
      {:ok, result} = RagReview.review(diff, "my-project")
      IO.puts(result.review)

  ## Prerequisites

  1. ChromaDB running: `docker run -p 8000:8000 chromadb/chroma`
  2. Ollama running: `ollama serve`
  3. Embedding model: `ollama pull nomic-embed-text`
  """

  alias RagReview.Indexing.Pipeline
  alias RagReview.Generation.Reviewer
  alias RagReview.Store.ChromaStore
  alias RagReview.Embeddings.OllamaProvider

  @doc """
  Index a git repository.

  ## Options

    * `:name` - Collection name (default: basename of path)
    * `:batch_size` - Chunks per embedding batch (default: 50)
    * `:progress_callback` - Function called with progress updates

  ## Examples

      {:ok, stats} = RagReview.index("/path/to/repo")
      {:ok, stats} = RagReview.index("/path/to/repo", name: "my-project")

  """
  defdelegate index(repo_path, opts \\ []), to: Pipeline, as: :run

  @doc """
  Re-index a repository (deletes existing index first).
  """
  defdelegate reindex(repo_path, opts \\ []), to: Pipeline

  @doc """
  Generate a code review for a git diff.

  ## Options

    * `:model` - LLM model to use
    * `:type` - Review type: `:general` or `:security` (default: `:general`)
    * `:n_results` - Number of context chunks to retrieve (default: 10)

  ## Examples

      diff = System.cmd("git", ["diff", "HEAD~1"]) |> elem(0)
      {:ok, result} = RagReview.review(diff, "my-project")
      IO.puts(result.review)

  """
  defdelegate review(diff, repo_name, opts \\ []), to: Reviewer

  @doc """
  Quick review without RAG context (just the diff).
  """
  defdelegate quick_review(diff, opts \\ []), to: Reviewer

  @doc """
  List all indexed repositories.
  """
  defdelegate list_repositories(), to: ChromaStore, as: :list_collections

  @doc """
  Delete an indexed repository.
  """
  defdelegate delete_repository(repo_name), to: ChromaStore, as: :delete_collection

  @doc """
  Health check for all services.

  Returns a map with status of each service.
  """
  def health_check do
    %{
      chroma: check_chroma(),
      ollama: check_ollama()
    }
  end

  @doc """
  Check if all required services are running.
  """
  def ready? do
    health = health_check()
    health.chroma == :ok and health.ollama == :ok
  end

  # Private helpers

  defp check_chroma do
    case ChromaStore.health_check() do
      {:ok, _version} -> :ok
      {:error, _} -> {:error, :unreachable}
    end
  end

  defp check_ollama do
    case OllamaProvider.health_check() do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
