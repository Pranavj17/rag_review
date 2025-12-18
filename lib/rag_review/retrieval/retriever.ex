defmodule RagReview.Retrieval.Retriever do
  @moduledoc """
  Main retrieval interface that combines diff parsing,
  embedding, and context building.
  """

  require Logger

  alias RagReview.Retrieval.{DiffParser, ContextBuilder}
  alias RagReview.Embeddings.OllamaProvider
  alias RagReview.Store.ChromaStore

  @doc """
  Retrieve relevant context for a git diff.

  Returns {:ok, context_result} or {:error, reason}.
  """
  def retrieve_for_diff(diff_string, collection, opts \\ []) do
    n_results = Keyword.get(opts, :n_results, 10)

    # Parse the diff
    analysis = DiffParser.parse(diff_string)

    Logger.debug(
      "Diff analysis: #{length(analysis.files)} files, #{length(analysis.hunks)} hunks"
    )

    # Generate queries from diff
    queries = DiffParser.generate_queries(analysis)
    Logger.debug("Generated #{length(queries)} queries")

    if Enum.empty?(queries) do
      {:ok,
       %{
         context: "_No context queries generated from diff._",
         chunks: [],
         analysis: analysis
       }}
    else
      # Embed queries
      case OllamaProvider.embed(queries) do
        {:ok, embeddings} ->
          # Query ChromaDB for each embedding
          results = retrieve_for_embeddings(embeddings, collection, n_results)

          # Build context
          context_result = ContextBuilder.build_with_metadata(results)

          {:ok,
           %{
             context: context_result.context,
             chunks: context_result.chunks,
             analysis: analysis,
             queries: queries,
             estimated_tokens: context_result.estimated_tokens
           }}

        {:error, reason} ->
          Logger.error("Failed to embed queries: #{inspect(reason)}")
          {:error, {:embedding_error, reason}}
      end
    end
  end

  @doc """
  Retrieve context using a direct text query.
  """
  def retrieve_for_query(query_text, collection, opts \\ []) when is_binary(query_text) do
    n_results = Keyword.get(opts, :n_results, 10)

    case OllamaProvider.embed_single(query_text) do
      {:ok, embedding} ->
        results =
          case ChromaStore.query(collection, embedding, n_results: n_results) do
            {:ok, chunks} -> chunks
            {:error, _} -> []
          end

        context_result = ContextBuilder.build_with_metadata(results)

        {:ok,
         %{
           context: context_result.context,
           chunks: context_result.chunks,
           query: query_text,
           estimated_tokens: context_result.estimated_tokens
         }}

      {:error, reason} ->
        {:error, {:embedding_error, reason}}
    end
  end

  # Private helpers

  defp retrieve_for_embeddings(embeddings, collection, n_results) do
    embeddings
    |> Enum.flat_map(fn embedding ->
      case ChromaStore.query(collection, embedding, n_results: n_results) do
        {:ok, chunks} -> chunks
        {:error, _} -> []
      end
    end)
    |> Enum.uniq_by(& &1.id)
  end
end
