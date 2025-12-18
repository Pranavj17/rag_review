defmodule RagReview.Indexing.Pipeline do
  @moduledoc """
  Orchestrates the full indexing pipeline:
  1. Walk repository files
  2. Parse and chunk each file
  3. Generate embeddings for chunks
  4. Store in ChromaDB
  """

  require Logger

  alias RagReview.Indexing.FileWalker
  alias RagReview.Parsing.Chunker
  alias RagReview.Embeddings.OllamaProvider
  alias RagReview.Store.ChromaStore

  @batch_size 10

  @doc """
  Index a repository.

  Options:
    - name: repository name (default: basename of path)
    - batch_size: chunks per embedding batch (default: 50)
    - progress_callback: function called with progress updates
  """
  def run(repo_path, opts \\ []) do
    repo_path = Path.expand(repo_path)
    repo_name = Keyword.get(opts, :name, Path.basename(repo_path))
    batch_size = Keyword.get(opts, :batch_size, @batch_size)
    progress_cb = Keyword.get(opts, :progress_callback, fn _ -> :ok end)

    Logger.info("Starting indexing for #{repo_name} at #{repo_path}")

    with :ok <- validate_repo(repo_path),
         {:ok, collection} <- ChromaStore.get_or_create_collection(repo_name),
         {:ok, stats} <- index_files(repo_path, collection, batch_size, progress_cb) do
      Logger.info("Indexing complete: #{stats.chunks} chunks from #{stats.files} files")
      {:ok, Map.put(stats, :repo_name, repo_name)}
    end
  end

  @doc """
  Re-index a repository (deletes existing and re-indexes).
  """
  def reindex(repo_path, opts \\ []) do
    repo_name = Keyword.get(opts, :name, Path.basename(repo_path))

    Logger.info("Deleting existing index for #{repo_name}")
    ChromaStore.delete_collection(repo_name)

    run(repo_path, opts)
  end

  # Private implementation

  defp validate_repo(repo_path) do
    cond do
      not File.exists?(repo_path) ->
        {:error, {:not_found, repo_path}}

      not File.dir?(repo_path) ->
        {:error, {:not_directory, repo_path}}

      true ->
        :ok
    end
  end

  defp index_files(repo_path, collection, batch_size, progress_cb) do
    files = FileWalker.walk(repo_path)
    total_files = length(files)

    Logger.info("Found #{total_files} files to index")
    progress_cb.(%{phase: :scanning, total_files: total_files})

    # Process files and collect chunks
    {chunks, file_stats} =
      files
      |> Enum.with_index(1)
      |> Enum.reduce({[], %{processed: 0, errors: 0}}, fn {file, idx}, {chunks_acc, stats} ->
        progress_cb.(%{
          phase: :parsing,
          current: idx,
          total: total_files,
          file: file.relative_path
        })

        case Chunker.chunk_file(file.path) do
          {:ok, file_chunks} ->
            # Update relative paths
            file_chunks =
              Enum.map(file_chunks, fn chunk ->
                %{chunk | file_path: file.relative_path}
              end)

            {chunks_acc ++ file_chunks, %{stats | processed: stats.processed + 1}}

          {:error, reason} ->
            Logger.warning("Failed to parse #{file.relative_path}: #{inspect(reason)}")
            {chunks_acc, %{stats | errors: stats.errors + 1}}
        end
      end)

    total_chunks = length(chunks)
    Logger.info("Extracted #{total_chunks} chunks from #{file_stats.processed} files")

    # Embed and store chunks in batches
    case embed_and_store_chunks(chunks, collection, batch_size, progress_cb) do
      :ok ->
        {:ok,
         %{
           files: file_stats.processed,
           files_errored: file_stats.errors,
           chunks: total_chunks
         }}

      {:error, _} = error ->
        error
    end
  end

  defp embed_and_store_chunks(chunks, collection, batch_size, progress_cb) do
    chunks
    |> Enum.chunk_every(batch_size)
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {batch, batch_num}, :ok ->
      total_batches = ceil(length(chunks) / batch_size)

      progress_cb.(%{
        phase: :embedding,
        batch: batch_num,
        total_batches: total_batches,
        chunks_in_batch: length(batch)
      })

      texts = Enum.map(batch, & &1.text)

      case OllamaProvider.embed(texts) do
        {:ok, embeddings} ->
          # Add embeddings to chunks
          chunks_with_embeddings =
            batch
            |> Enum.zip(embeddings)
            |> Enum.map(fn {chunk, embedding} ->
              %{chunk | embedding: embedding}
            end)

          # Store in ChromaDB
          case ChromaStore.upsert_chunks(collection, chunks_with_embeddings) do
            {:ok, _} ->
              {:cont, :ok}

            {:error, reason} ->
              Logger.error("Failed to store batch #{batch_num}: #{inspect(reason)}")
              {:halt, {:error, {:storage_error, reason}}}
          end

        {:error, reason} ->
          Logger.error("Failed to embed batch #{batch_num}: #{inspect(reason)}")
          {:halt, {:error, {:embedding_error, reason}}}
      end
    end)
  end
end
