defmodule RagReview.Parsing.Chunker do
  @moduledoc """
  Language-agnostic code chunker that dispatches to language-specific parsers.
  """

  alias RagReview.Parsing.Languages.ElixirParser
  alias RagReview.Parsing.Chunk

  @supported_extensions %{
    ".ex" => :elixir,
    ".exs" => :elixir,
    ".js" => :javascript,
    ".jsx" => :javascript,
    ".ts" => :typescript,
    ".tsx" => :typescript,
    ".py" => :python
  }

  @doc """
  Chunk a file based on its extension.

  Returns {:ok, chunks} or {:error, reason}.
  """
  def chunk_file(file_path) do
    ext = Path.extname(file_path)

    case Map.get(@supported_extensions, ext) do
      nil ->
        {:error, {:unsupported_extension, ext}}

      language ->
        chunk_file(file_path, language)
    end
  end

  @doc """
  Chunk a file with explicit language.
  """
  def chunk_file(file_path, :elixir) do
    ElixirParser.parse_file(file_path)
  end

  def chunk_file(file_path, language) when language in [:javascript, :typescript, :python] do
    # For now, fall back to simple line-based chunking for non-Elixir files
    # TODO: Add tree-sitter based parsing
    chunk_file_simple(file_path, language)
  end

  def chunk_file(_file_path, language) do
    {:error, {:unsupported_language, language}}
  end

  @doc """
  Chunk source code directly (without reading from file).
  """
  def chunk_source(source, file_path, language) do
    case language do
      :elixir ->
        ElixirParser.parse(source, file_path)

      lang when lang in [:javascript, :typescript, :python] ->
        chunk_source_simple(source, file_path, lang)

      _ ->
        {:error, {:unsupported_language, language}}
    end
  end

  @doc """
  Get the language for a file based on extension.
  """
  def detect_language(file_path) do
    ext = Path.extname(file_path)
    Map.get(@supported_extensions, ext, :unknown)
  end

  @doc """
  Check if a file extension is supported.
  """
  def supported?(file_path) do
    ext = Path.extname(file_path)
    Map.has_key?(@supported_extensions, ext)
  end

  @doc """
  List all supported extensions.
  """
  def supported_extensions, do: Map.keys(@supported_extensions)

  # Simple line-based chunking for non-Elixir files

  defp chunk_file_simple(file_path, language) do
    case File.read(file_path) do
      {:ok, source} ->
        chunk_source_simple(source, file_path, language)

      {:error, reason} ->
        {:error, {:file_error, reason}}
    end
  end

  defp chunk_source_simple(source, file_path, language) do
    # Split into chunks of ~100 lines with 20 line overlap
    chunk_size = 100
    overlap = 20

    lines = String.split(source, "\n")
    total_lines = length(lines)

    chunks =
      if total_lines <= chunk_size do
        # Small file - one chunk
        [create_simple_chunk(lines, 1, total_lines, file_path, language, 0)]
      else
        # Split into overlapping chunks
        0..div(total_lines, chunk_size - overlap)
        |> Enum.map(fn i ->
          start_idx = i * (chunk_size - overlap)
          end_idx = min(start_idx + chunk_size, total_lines)

          chunk_lines = Enum.slice(lines, start_idx, end_idx - start_idx)
          create_simple_chunk(chunk_lines, start_idx + 1, end_idx, file_path, language, i)
        end)
        |> Enum.filter(&(&1 != nil))
      end

    {:ok, chunks}
  end

  defp create_simple_chunk(lines, start_line, end_line, file_path, language, index) do
    text = Enum.join(lines, "\n")

    if String.trim(text) == "" do
      nil
    else
      Chunk.new(%{
        text: text,
        type: :unknown,
        name: "chunk_#{index}",
        file_path: file_path,
        start_line: start_line,
        end_line: end_line,
        language: language
      })
    end
  end
end
