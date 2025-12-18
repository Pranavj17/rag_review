defmodule RagReview.Retrieval.ContextBuilder do
  @moduledoc """
  Build context from retrieved chunks for LLM consumption.

  Takes retrieved chunks from ChromaDB and formats them into
  a context string suitable for inclusion in a review prompt.
  """

  # Reserve space for diff and response in context window
  @max_context_chars 32_000
  @chars_per_token 4

  @doc """
  Build a formatted context string from retrieved chunks.

  Options:
    - max_chars: maximum characters in context (default: 32000)
    - include_metadata: include file path and line info (default: true)
  """
  def build(retrieved_chunks, opts \\ []) when is_list(retrieved_chunks) do
    max_chars = Keyword.get(opts, :max_chars, @max_context_chars)
    include_metadata = Keyword.get(opts, :include_metadata, true)

    retrieved_chunks
    |> deduplicate_by_id()
    |> sort_by_relevance()
    |> truncate_to_limit(max_chars)
    |> format_chunks(include_metadata)
  end

  @doc """
  Build context and return both the string and the chunks used.

  Useful for debugging and showing which context was retrieved.
  """
  def build_with_metadata(retrieved_chunks, opts \\ []) do
    max_chars = Keyword.get(opts, :max_chars, @max_context_chars)

    selected_chunks =
      retrieved_chunks
      |> deduplicate_by_id()
      |> sort_by_relevance()
      |> truncate_to_limit(max_chars)

    context_string = format_chunks(selected_chunks, true)

    %{
      context: context_string,
      chunks: selected_chunks,
      total_chars: String.length(context_string),
      estimated_tokens: div(String.length(context_string), @chars_per_token)
    }
  end

  @doc """
  Estimate the number of tokens in the context.
  """
  def estimate_tokens(context) when is_binary(context) do
    div(String.length(context), @chars_per_token)
  end

  # Private implementation

  defp deduplicate_by_id(chunks) do
    chunks
    |> Enum.uniq_by(& &1.id)
  end

  defp sort_by_relevance(chunks) do
    # ChromaDB returns distance where lower = more similar
    Enum.sort_by(chunks, & &1.distance)
  end

  defp truncate_to_limit(chunks, max_chars) do
    {selected, _} =
      Enum.reduce_while(chunks, {[], 0}, fn chunk, {acc, total} ->
        doc = chunk.document || ""
        chunk_size = String.length(doc) + 100 # Account for formatting

        if total + chunk_size > max_chars do
          {:halt, {acc, total}}
        else
          {:cont, {[chunk | acc], total + chunk_size}}
        end
      end)

    Enum.reverse(selected)
  end

  defp format_chunks(chunks, include_metadata) do
    if Enum.empty?(chunks) do
      "_No relevant context found._"
    else
      chunks
      |> Enum.map(&format_single_chunk(&1, include_metadata))
      |> Enum.join("\n\n---\n\n")
    end
  end

  defp format_single_chunk(chunk, true) do
    meta = chunk.metadata || %{}
    file_path = meta["file_path"] || "unknown"
    chunk_type = meta["chunk_type"] || "code"
    chunk_name = meta["chunk_name"] || "unknown"
    start_line = meta["start_line"] || "?"
    end_line = meta["end_line"] || "?"
    language = meta["language"] || "text"

    """
    ## #{file_path} (#{chunk_type}: #{chunk_name})
    Lines #{start_line}-#{end_line}

    ```#{language}
    #{chunk.document}
    ```
    """
  end

  defp format_single_chunk(chunk, false) do
    """
    ```
    #{chunk.document}
    ```
    """
  end
end
