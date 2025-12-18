defmodule RagReview.CLI do
  @moduledoc """
  Command-line interface for RAG Review.

  Usage:
    rag_review index <repo-path> [options]
    rag_review review --repo <name> [options]
    rag_review context --repo <name> [options]
    rag_review list
    rag_review health
    rag_review help
  """

  alias RagReview.Indexing.Pipeline
  alias RagReview.Generation.Reviewer
  alias RagReview.Retrieval.Retriever
  alias RagReview.Store.ChromaStore
  alias RagReview.Embeddings.OllamaProvider

  def main(args) do
    setup_config()

    case parse_args(args) do
      {:index, opts} ->
        index_repository(opts)

      {:review, opts} ->
        review_diff(opts)

      {:context, opts} ->
        get_context(opts)

      {:delete, opts} ->
        delete_repository(opts)

      {:list, _opts} ->
        list_repositories()

      {:health, _opts} ->
        health_check()

      {:help, _} ->
        print_help()

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{reason}")
        print_help()
        System.halt(1)
    end
  end

  # Command parsing

  defp parse_args(["index" | rest]), do: {:index, parse_index_opts(rest)}
  defp parse_args(["review" | rest]), do: {:review, parse_review_opts(rest)}
  defp parse_args(["context" | rest]), do: {:context, parse_context_opts(rest)}
  defp parse_args(["delete" | rest]), do: {:delete, parse_delete_opts(rest)}
  defp parse_args(["list" | _]), do: {:list, []}
  defp parse_args(["health" | _]), do: {:health, []}
  defp parse_args(["help" | _]), do: {:help, []}
  defp parse_args(["--help" | _]), do: {:help, []}
  defp parse_args(["-h" | _]), do: {:help, []}
  defp parse_args([]), do: {:help, []}
  defp parse_args(_), do: {:error, "Unknown command"}

  defp parse_index_opts(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [name: :string, reindex: :boolean],
        aliases: [n: :name, r: :reindex]
      )

    case positional do
      [path | _] -> [{:path, path} | opts]
      [] -> opts
    end
  end

  defp parse_review_opts(args) do
    {opts, _positional, _} =
      OptionParser.parse(args,
        strict: [
          repo: :string,
          file: :string,
          model: :string,
          type: :string,
          quick: :boolean
        ],
        aliases: [r: :repo, f: :file, m: :model, t: :type, q: :quick]
      )

    opts
  end

  defp parse_context_opts(args) do
    {opts, _positional, _} =
      OptionParser.parse(args,
        strict: [
          repo: :string,
          file: :string,
          format: :string,
          limit: :integer
        ],
        aliases: [r: :repo, f: :file, o: :format, l: :limit]
      )

    opts
  end

  defp parse_delete_opts(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [repo: :string],
        aliases: [r: :repo]
      )

    case {Keyword.get(opts, :repo), positional} do
      {nil, [name | _]} -> [{:repo, name} | opts]
      _ -> opts
    end
  end

  # Command implementations

  defp index_repository(opts) do
    path = Keyword.get(opts, :path)

    unless path do
      IO.puts(:stderr, "Error: Repository path required")
      IO.puts(:stderr, "Usage: rag_review index <path> [--name NAME]")
      System.halt(1)
    end

    name = Keyword.get(opts, :name, Path.basename(path))
    reindex = Keyword.get(opts, :reindex, false)

    IO.puts("Indexing repository: #{path}")
    IO.puts("Collection name: #{name}")

    progress_callback = fn
      %{phase: :scanning, total_files: n} ->
        IO.puts("Found #{n} files to index")

      %{phase: :parsing, current: c, total: t, file: f} ->
        IO.write("\rParsing: #{c}/#{t} - #{f}" <> String.duplicate(" ", 20))

      %{phase: :embedding, batch: b, total_batches: t} ->
        IO.write("\rEmbedding: batch #{b}/#{t}" <> String.duplicate(" ", 40))

      _ ->
        :ok
    end

    indexer = if reindex, do: &Pipeline.reindex/2, else: &Pipeline.run/2

    case indexer.(path, name: name, progress_callback: progress_callback) do
      {:ok, stats} ->
        IO.puts("\n")
        IO.puts("Indexing complete!")
        IO.puts("  Files processed: #{stats.files}")
        IO.puts("  Files with errors: #{stats.files_errored}")
        IO.puts("  Total chunks: #{stats.chunks}")

      {:error, reason} ->
        IO.puts(:stderr, "\nError: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp review_diff(opts) do
    repo = Keyword.get(opts, :repo)
    quick = Keyword.get(opts, :quick, false)

    if is_nil(repo) and not quick do
      IO.puts(:stderr, "Error: --repo NAME required (or use --quick for no context)")
      IO.puts(:stderr, "Usage: git diff | rag_review review --repo NAME")
      System.halt(1)
    end

    # Read diff from stdin or file
    diff =
      case Keyword.get(opts, :file) do
        nil -> IO.read(:stdio, :eof)
        path -> File.read!(path)
      end

    # Handle :eof from empty stdin
    diff = if diff == :eof, do: "", else: diff

    if String.trim(diff) == "" do
      IO.puts(:stderr, "Error: No diff provided. Pipe a diff or use --file")
      System.halt(1)
    end

    model = Keyword.get(opts, :model)
    type = parse_review_type(Keyword.get(opts, :type, "general"))

    review_opts = [type: type]
    review_opts = if model, do: [{:model, model} | review_opts], else: review_opts

    IO.puts(:stderr, "Generating #{type} review...")

    result =
      if quick do
        Reviewer.quick_review(diff, review_opts)
      else
        Reviewer.review(diff, repo, review_opts)
      end

    case result do
      {:ok, %{review: review}} ->
        IO.puts(review)

      {:error, {:repo_not_indexed, name}} ->
        IO.puts(:stderr, "Error: Repository '#{name}' not indexed")
        IO.puts(:stderr, "Run: rag_review index <path> --name #{name}")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp get_context(opts) do
    repo = Keyword.get(opts, :repo)

    unless repo do
      IO.puts(:stderr, "Error: --repo NAME required")
      IO.puts(:stderr, "Usage: git diff | rag_review context --repo NAME")
      System.halt(1)
    end

    # Read diff from stdin or file
    diff =
      case Keyword.get(opts, :file) do
        nil -> IO.read(:stdio, :eof)
        path -> File.read!(path)
      end

    diff = if diff == :eof, do: "", else: diff

    if String.trim(diff) == "" do
      IO.puts(:stderr, "Error: No diff provided. Pipe a diff or use --file")
      System.halt(1)
    end

    format = Keyword.get(opts, :format, "text")
    limit = Keyword.get(opts, :limit, 10)

    IO.puts(:stderr, "Retrieving context from '#{repo}'...")

    case Retriever.retrieve_for_diff(diff, repo, n_results: limit) do
      {:ok, result} ->
        output_context(result, format)

      {:error, {:embedding_error, reason}} ->
        IO.puts(:stderr, "Error: Failed to generate embeddings")
        IO.puts(:stderr, "Reason: #{inspect(reason)}")
        IO.puts(:stderr, "Is Ollama running? Check: rag_review health")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp output_context(result, "json") do
    chunks_json =
      result.chunks
      |> Enum.map(fn chunk ->
        %{
          id: chunk.id,
          document: chunk.document,
          file_path: chunk.metadata["file_path"],
          chunk_type: chunk.metadata["chunk_type"],
          chunk_name: chunk.metadata["chunk_name"],
          start_line: chunk.metadata["start_line"],
          end_line: chunk.metadata["end_line"],
          distance: chunk.distance
        }
      end)

    output = %{
      context: result.context,
      chunks: chunks_json,
      queries: Map.get(result, :queries, []),
      estimated_tokens: result.estimated_tokens
    }

    IO.puts(Jason.encode!(output, pretty: true))
  end

  defp output_context(result, _format) do
    # Default text format - just output the context string
    IO.puts(result.context)
  end

  defp list_repositories do
    case ChromaStore.list_collections() do
      {:ok, repos} ->
        if Enum.empty?(repos) do
          IO.puts("No repositories indexed yet.")
          IO.puts("Run: rag_review index <path>")
        else
          IO.puts("Indexed repositories:\n")

          Enum.each(repos, fn repo ->
            IO.puts("  - #{repo.name}")
          end)
        end

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{inspect(reason)}")
        IO.puts(:stderr, "Is ChromaDB running?")
        System.halt(1)
    end
  end

  defp delete_repository(opts) do
    repo = Keyword.get(opts, :repo)

    unless repo do
      IO.puts(:stderr, "Error: Repository name required")
      IO.puts(:stderr, "Usage: rag_review delete <name>")
      System.halt(1)
    end

    # If user passes a path, use the basename as the collection name
    repo = Path.basename(repo)

    IO.puts("Deleting repository: #{repo}")

    case ChromaStore.delete_collection(repo) do
      {:ok, :deleted} ->
        IO.puts("Repository '#{repo}' deleted successfully.")

      {:error, :not_found} ->
        IO.puts(:stderr, "Error: Repository '#{repo}' not found")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp health_check do
    IO.puts("Checking services...\n")

    # Check ChromaDB
    IO.write("ChromaDB: ")

    case ChromaStore.health_check() do
      {:ok, version} ->
        IO.puts("✓ Running (version #{version})")

      {:error, _} ->
        IO.puts("✗ Not reachable")
        IO.puts("  Run: docker run -p 8000:8000 chromadb/chroma")
    end

    # Check Ollama
    IO.write("Ollama: ")

    case OllamaProvider.health_check() do
      :ok ->
        IO.puts("✓ Running with embedding model")

      {:error, {:model_not_found, model, available}} ->
        IO.puts("✗ Missing embedding model '#{model}'")
        IO.puts("  Available: #{Enum.join(available, ", ")}")
        IO.puts("  Run: ollama pull #{model}")

      {:error, _} ->
        IO.puts("✗ Not reachable")
        IO.puts("  Run: ollama serve")
    end
  end

  defp print_help do
    IO.puts("""
    RAG Review - Context-aware code review using local LLMs

    Usage:
      rag_review <command> [options]

    Commands:
      index <path>     Index a git repository for review
      review           Generate a code review from a git diff
      context          Retrieve relevant context for a diff (no LLM call)
      delete <name>    Delete an indexed repository
      list             List indexed repositories
      health           Check service health (ChromaDB, Ollama)
      help             Show this help message

    Index Options:
      --name, -n NAME      Collection name (default: directory name)
      --reindex, -r        Delete existing index and re-index

    Review Options:
      --repo, -r NAME      Repository to query (required unless --quick)
      --file, -f PATH      Read diff from file instead of stdin
      --model, -m MODEL    LLM model to use (default: qwen2.5:14b)
      --type, -t TYPE      Review type: general, security (default: general)
      --quick, -q          Skip RAG context (faster but less context-aware)

    Context Options:
      --repo, -r NAME      Repository to query (required)
      --file, -f PATH      Read diff from file instead of stdin
      --format, -o FORMAT  Output format: text, json (default: text)
      --limit, -l N        Max chunks to retrieve (default: 10)

    Examples:
      # Index a repository
      rag_review index /path/to/repo
      rag_review index /path/to/repo --name my-project

      # Delete a repository
      rag_review delete my-project

      # Review a diff
      git diff HEAD~1 | rag_review review --repo my-project
      git diff main | rag_review review --repo my-project --type security

      # Quick review without context
      git diff | rag_review review --quick

      # Get context only (for shell script integration)
      git diff | rag_review context --repo my-project
      git diff | rag_review context --repo my-project --format json

    Prerequisites:
      1. ChromaDB: docker run -p 8000:8000 chromadb/chroma
      2. Ollama: ollama serve
      3. Embedding model: ollama pull nomic-embed-text
    """)
  end

  defp parse_review_type("security"), do: :security
  defp parse_review_type(_), do: :general

  defp setup_config do
    # Set ChromaDB config
    Application.put_env(:chroma, :host, System.get_env("CHROMA_HOST", "http://localhost:8000"))
    Application.put_env(:chroma, :api_base, "api")
    Application.put_env(:chroma, :api_version, "v2")

    # Set RAG Review config
    Application.put_env(:rag_review, :ollama_host, System.get_env("OLLAMA_HOST", "http://localhost:11434"))
    Application.put_env(:rag_review, :default_model, System.get_env("RAG_REVIEW_MODEL", "qwen2.5-coder:7b"))
  end
end
