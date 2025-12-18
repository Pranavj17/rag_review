defmodule RagReview.Embeddings.OllamaProvider do
  @moduledoc """
  Generate embeddings using Ollama's embedding endpoint.

  Supported models:
    - nomic-embed-text (768 dimensions, recommended)
    - mxbai-embed-large (1024 dimensions, higher quality)
    - all-minilm (384 dimensions, faster)
  """

  require Logger

  @default_model "all-minilm"
  @timeout 120_000

  @doc """
  Generate embeddings for a list of texts.
  Embeds one at a time to avoid Ollama batch issues.

  Options:
    - model: embedding model to use (default: "nomic-embed-text")
  """
  def embed(texts, opts \\ []) when is_list(texts) do
    # Embed one at a time to avoid Ollama issues with batching
    texts
    |> Enum.reduce_while({:ok, []}, fn text, {:ok, acc} ->
      case embed_one(text, opts) do
        {:ok, embedding} -> {:cont, {:ok, acc ++ [embedding]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp embed_one(text, opts) do
    model = Keyword.get(opts, :model, @default_model)
    host = ollama_host()
    url = "#{host}/api/embed"

    # Truncate very long texts to avoid issues
    truncated_text = String.slice(text, 0, 8000)

    body = %{
      model: model,
      input: truncated_text
    }

    case Req.post(url, json: body, receive_timeout: @timeout) do
      {:ok, %{status: 200, body: %{"embeddings" => [embedding | _]}}} ->
        {:ok, embedding}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Ollama API error: status=#{status}, body=#{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        Logger.error("Ollama not reachable at #{host}. Is it running?")
        {:error, {:connection_error, :econnrefused}}

      {:error, reason} ->
        Logger.error("Ollama request failed: #{inspect(reason)}")
        {:error, {:connection_error, reason}}
    end
  end

  @doc """
  Generate embedding for a single text.
  """
  def embed_single(text, opts \\ []) do
    case embed([text], opts) do
      {:ok, [embedding]} -> {:ok, embedding}
      {:ok, []} -> {:error, :no_embedding_returned}
      error -> error
    end
  end

  @doc """
  Embed texts in batches to avoid overwhelming Ollama.
  Returns {:ok, embeddings} or {:error, reason}.
  """
  def embed_batch(texts, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 50)

    texts
    |> Enum.chunk_every(batch_size)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      case embed(batch, opts) do
        {:ok, embeddings} ->
          {:cont, {:ok, acc ++ embeddings}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Check if Ollama is running and the embedding model is available.
  """
  def health_check do
    host = ollama_host()

    case Req.get("#{host}/api/tags") do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        model_names = Enum.map(models, & &1["name"])

        if Enum.any?(model_names, &String.contains?(&1, @default_model)) do
          :ok
        else
          {:error, {:model_not_found, @default_model, model_names}}
        end

      {:ok, %{status: status}} ->
        {:error, {:api_error, status}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  @doc """
  Get the configured Ollama host.
  """
  def ollama_host do
    Application.get_env(:rag_review, :ollama_host, "http://localhost:11434")
  end
end
