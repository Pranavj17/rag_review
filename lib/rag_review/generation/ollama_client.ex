defmodule RagReview.Generation.OllamaClient do
  @moduledoc """
  Ollama client for LLM chat/generation.
  """

  require Logger

  @default_model "qwen2.5-coder:7b"
  @timeout 300_000  # 5 minutes for complex reviews

  @doc """
  Send a chat completion request to Ollama.

  Options:
    - model: LLM model to use (default: "qwen2.5:14b")
    - temperature: sampling temperature (default: 0.3)
    - max_tokens: maximum tokens in response (default: 4000)
  """
  def chat(messages, opts \\ []) when is_list(messages) do
    model = Keyword.get(opts, :model, @default_model)
    temperature = Keyword.get(opts, :temperature, 0.3)

    host = ollama_host()
    url = "#{host}/api/chat"

    body = %{
      model: model,
      messages: format_messages(messages),
      stream: false,
      options: %{
        temperature: temperature
      }
    }

    case Req.post(url, json: body, receive_timeout: @timeout) do
      {:ok, %{status: 200, body: %{"message" => %{"content" => content}}}} ->
        {:ok, content}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Ollama chat error: status=#{status}")
        {:error, {:api_error, status, body}}

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        Logger.error("Ollama not reachable at #{host}")
        {:error, {:connection_error, :econnrefused}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        Logger.error("Ollama request timed out after #{@timeout}ms")
        {:error, {:timeout, @timeout}}

      {:error, reason} ->
        Logger.error("Ollama request failed: #{inspect(reason)}")
        {:error, {:connection_error, reason}}
    end
  end

  @doc """
  Send a simple generate request (no chat history).
  """
  def generate(prompt, opts \\ []) when is_binary(prompt) do
    model = Keyword.get(opts, :model, @default_model)
    system = Keyword.get(opts, :system, nil)
    temperature = Keyword.get(opts, :temperature, 0.3)

    host = ollama_host()
    url = "#{host}/api/generate"

    body =
      %{
        model: model,
        prompt: prompt,
        stream: false,
        options: %{
          temperature: temperature
        }
      }
      |> maybe_add_system(system)

    case Req.post(url, json: body, receive_timeout: @timeout) do
      {:ok, %{status: 200, body: %{"response" => response}}} ->
        {:ok, response}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  @doc """
  List available models on the Ollama server.
  """
  def list_models do
    host = ollama_host()

    case Req.get("#{host}/api/tags") do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        model_names = Enum.map(models, & &1["name"])
        {:ok, model_names}

      {:ok, %{status: status}} ->
        {:error, {:api_error, status}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  @doc """
  Check if a specific model is available.
  """
  def model_available?(model_name) do
    case list_models() do
      {:ok, models} ->
        Enum.any?(models, &String.contains?(&1, model_name))

      {:error, _} ->
        false
    end
  end

  @doc """
  Get recommended models for code review.
  """
  def recommended_models do
    [
      %{name: "qwen2.5:14b", description: "Balanced quality and speed"},
      %{name: "qwen2.5-coder:14b", description: "Optimized for code"},
      %{name: "deepseek-coder:6.7b", description: "Fast, good for code"},
      %{name: "codellama:13b", description: "Meta's code model"},
      %{name: "llama3.2:latest", description: "General purpose"}
    ]
  end

  # Private helpers

  defp ollama_host do
    Application.get_env(:rag_review, :ollama_host, "http://localhost:11434")
  end

  defp format_messages(messages) do
    Enum.map(messages, fn
      %{role: role, content: content} ->
        %{"role" => to_string(role), "content" => content}

      {role, content} ->
        %{"role" => to_string(role), "content" => content}
    end)
  end

  defp maybe_add_system(body, nil), do: body
  defp maybe_add_system(body, system), do: Map.put(body, :system, system)
end
