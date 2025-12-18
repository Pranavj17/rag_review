defmodule RagReview.Generation.Reviewer do
  @moduledoc """
  Main code review generation module.

  Orchestrates:
  1. Diff parsing
  2. Context retrieval from ChromaDB
  3. Prompt building
  4. LLM review generation
  """

  require Logger

  alias RagReview.Generation.{OllamaClient, PromptTemplates}
  alias RagReview.Retrieval.Retriever
  alias RagReview.Store.ChromaStore

  @doc """
  Generate a code review for a git diff.

  Options:
    - model: LLM model to use (default: from config)
    - type: review type (:general, :security) (default: :general)
    - repo_name: name to display in review
    - focus_areas: list of areas to focus on
    - n_results: number of context chunks to retrieve (default: 10)
  """
  def review(diff_string, repo_name, opts \\ []) do
    review_type = Keyword.get(opts, :type, :general)
    model = Keyword.get(opts, :model)

    Logger.info("Generating #{review_type} review for #{repo_name}")

    with {:ok, collection} <- ChromaStore.get_collection(repo_name),
         {:ok, retrieval_result} <- Retriever.retrieve_for_diff(diff_string, collection, opts),
         {:ok, review_text} <- generate_review(diff_string, retrieval_result, review_type, opts) do
      {:ok,
       %{
         review: review_text,
         context_chunks: retrieval_result.chunks,
         analysis: retrieval_result.analysis,
         queries_used: retrieval_result.queries,
         model: model || default_model()
       }}
    else
      {:error, {:not_found, _}} ->
        {:error, {:repo_not_indexed, repo_name}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generate a review using provided context (skip retrieval).
  """
  def review_with_context(diff_string, context, opts \\ []) do
    review_type = Keyword.get(opts, :type, :general)

    case generate_review(diff_string, %{context: context}, review_type, opts) do
      {:ok, review_text} ->
        {:ok, %{review: review_text}}

      error ->
        error
    end
  end

  @doc """
  Quick review without RAG context (just the diff).
  """
  def quick_review(diff_string, opts \\ []) do
    review_type = Keyword.get(opts, :type, :general)
    model = Keyword.get(opts, :model)

    {system_prompt, user_prompt} =
      PromptTemplates.get_prompts(
        review_type,
        diff_string,
        "_No codebase context available._",
        opts
      )

    messages = [
      %{role: :system, content: system_prompt},
      %{role: :user, content: user_prompt}
    ]

    model_opts = if model, do: [model: model], else: []

    case OllamaClient.chat(messages, model_opts) do
      {:ok, review_text} ->
        {:ok, %{review: review_text, model: model || default_model()}}

      error ->
        error
    end
  end

  # Private implementation

  defp generate_review(diff_string, retrieval_result, review_type, opts) do
    model = Keyword.get(opts, :model)
    context = retrieval_result.context

    {system_prompt, user_prompt} =
      PromptTemplates.get_prompts(review_type, diff_string, context, opts)

    Logger.debug("Context tokens: ~#{retrieval_result[:estimated_tokens] || "unknown"}")

    messages = [
      %{role: :system, content: system_prompt},
      %{role: :user, content: user_prompt}
    ]

    model_opts = if model, do: [model: model], else: []

    OllamaClient.chat(messages, model_opts)
  end

  defp default_model do
    Application.get_env(:rag_review, :default_model, "qwen2.5:14b")
  end
end
