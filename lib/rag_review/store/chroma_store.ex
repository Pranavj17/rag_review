defmodule RagReview.Store.ChromaStore do
  @moduledoc """
  ChromaDB wrapper for storing and querying code chunks.
  Uses direct HTTP calls to ChromaDB v2 API.
  """

  require Logger

  @tenant "default_tenant"
  @database "default_database"

  defp chroma_host do
    Application.get_env(:chroma, :host, "http://localhost:8000")
  end

  defp base_url do
    "#{chroma_host()}/api/v2/tenants/#{@tenant}/databases/#{@database}"
  end

  @doc """
  Get or create a collection for a repository.
  """
  def get_or_create_collection(repo_name) do
    collection_name = sanitize_collection_name(repo_name)

    # Try to get existing collection
    case get_collection_by_name(collection_name) do
      {:ok, collection} ->
        {:ok, collection}

      {:error, :not_found} ->
        create_collection(collection_name)

      error ->
        error
    end
  end

  @doc """
  Get an existing collection by repository name.
  """
  def get_collection(repo_name) do
    collection_name = sanitize_collection_name(repo_name)
    get_collection_by_name(collection_name)
  end

  defp get_collection_by_name(collection_name) do
    url = "#{base_url()}/collections/#{collection_name}"

    case Req.get(url, retry: false) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, body: body}} ->
        Logger.error("ChromaDB get collection error: #{status} - #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("ChromaDB connection error: #{inspect(reason)}")
        {:error, {:connection_error, reason}}
    end
  end

  defp create_collection(collection_name) do
    url = "#{base_url()}/collections"

    body = %{
      name: collection_name,
      metadata: %{"hnsw:space" => "cosine"}
    }

    case Req.post(url, json: body, retry: false) do
      {:ok, %{status: status, body: response_body}} when status in [200, 201] ->
        {:ok, response_body}

      {:ok, %{status: status, body: body}} ->
        Logger.error("ChromaDB create collection error: #{status} - #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  @doc """
  Store chunks with their embeddings in ChromaDB.
  """
  def upsert_chunks(collection, chunks) when is_list(chunks) do
    collection_id = collection["id"]
    url = "#{base_url()}/collections/#{collection_id}/upsert"

    body = %{
      ids: Enum.map(chunks, & &1.id),
      embeddings: Enum.map(chunks, & &1.embedding),
      documents: Enum.map(chunks, & &1.text),
      metadatas: Enum.map(chunks, &chunk_to_metadata/1)
    }

    case Req.post(url, json: body, retry: false, receive_timeout: 60_000) do
      {:ok, %{status: status}} when status in [200, 201] ->
        Logger.debug("Upserted #{length(chunks)} chunks")
        {:ok, :success}

      {:ok, %{status: status, body: response_body}} ->
        Logger.error("ChromaDB upsert error: #{status} - #{inspect(response_body)}")
        {:error, {:api_error, status, response_body}}

      {:error, reason} ->
        Logger.error("ChromaDB connection error: #{inspect(reason)}")
        {:error, {:connection_error, reason}}
    end
  end

  @doc """
  Query for similar chunks given an embedding.

  Options:
    - n_results: number of results to return (default: 10)
    - where: metadata filter (default: %{})
  """
  def query(collection, embedding, opts \\ []) do
    collection_id = collection["id"]
    n_results = Keyword.get(opts, :n_results, 10)
    where = Keyword.get(opts, :where, nil)

    url = "#{base_url()}/collections/#{collection_id}/query"

    body = %{
      query_embeddings: [embedding],
      n_results: n_results,
      include: ["documents", "metadatas", "distances"]
    }

    body = if where, do: Map.put(body, :where, where), else: body

    case Req.post(url, json: body, retry: false, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: result}} ->
        {:ok, parse_query_result(result)}

      {:ok, %{status: status, body: response_body}} ->
        Logger.error("ChromaDB query error: #{status} - #{inspect(response_body)}")
        {:error, {:api_error, status, response_body}}

      {:error, reason} ->
        Logger.error("ChromaDB query connection error: #{inspect(reason)}")
        {:error, {:connection_error, reason}}
    end
  end

  @doc """
  List all collections (indexed repositories).
  """
  def list_collections do
    url = "#{base_url()}/collections"

    case Req.get(url, retry: false) do
      {:ok, %{status: 200, body: collections}} ->
        repos =
          collections
          |> Enum.filter(&String.starts_with?(&1["name"], "rag_review_"))
          |> Enum.map(fn col ->
            %{
              name: String.replace_prefix(col["name"], "rag_review_", ""),
              id: col["id"]
            }
          end)

        {:ok, repos}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  @doc """
  Delete a collection by repository name.
  """
  def delete_collection(repo_name) do
    collection_name = sanitize_collection_name(repo_name)
    url = "#{base_url()}/collections/#{collection_name}"

    case Req.delete(url, retry: false) do
      {:ok, %{status: status}} when status in [200, 204] ->
        {:ok, :deleted}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  @doc """
  Check if ChromaDB is reachable.
  """
  def health_check do
    url = "#{chroma_host()}/api/v2/version"

    case Req.get(url, retry: false) do
      {:ok, %{status: 200, body: version}} ->
        {:ok, version}

      {:ok, %{status: status}} ->
        {:error, {:api_error, status}}

      {:error, _} ->
        {:error, :unreachable}
    end
  end

  # Private helpers

  defp sanitize_collection_name(repo_name) do
    safe_name =
      repo_name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]/, "_")
      |> String.slice(0, 50)

    "rag_review_#{safe_name}"
  end

  defp chunk_to_metadata(chunk) do
    %{
      "file_path" => chunk.file_path,
      "chunk_type" => to_string(chunk.type),
      "chunk_name" => chunk.name,
      "start_line" => chunk.start_line,
      "end_line" => chunk.end_line,
      "language" => to_string(chunk.language)
    }
  end

  defp parse_query_result(%{
         "ids" => [ids],
         "documents" => [docs],
         "metadatas" => [metas],
         "distances" => [distances]
       }) do
    [ids, docs, metas, distances]
    |> Enum.zip()
    |> Enum.map(fn {id, doc, meta, distance} ->
      %{
        id: id,
        document: doc,
        metadata: meta,
        distance: distance
      }
    end)
  end

  defp parse_query_result(_), do: []
end
