defmodule RagReview.Parsing.Chunk do
  @moduledoc """
  Represents a semantic code chunk extracted from source code.

  Chunks are the fundamental unit for embedding and retrieval.
  They represent meaningful code units like functions, modules, or classes.
  """

  @enforce_keys [:id, :text, :type, :name, :file_path, :language]
  defstruct [
    :id,
    :text,
    :type,
    :name,
    :file_path,
    :start_line,
    :end_line,
    :language,
    :embedding,
    :metadata
  ]

  @type chunk_type :: :module | :function | :private_function | :class | :method | :unknown
  @type language :: :elixir | :javascript | :typescript | :python | :unknown

  @type t :: %__MODULE__{
          id: String.t(),
          text: String.t(),
          type: chunk_type(),
          name: String.t(),
          file_path: String.t(),
          start_line: pos_integer() | nil,
          end_line: pos_integer() | nil,
          language: language(),
          embedding: list(float()) | nil,
          metadata: map() | nil
        }

  @doc """
  Create a new chunk with a generated ID.
  """
  def new(attrs) do
    id = generate_id(attrs[:file_path], attrs[:type], attrs[:name], attrs[:start_line])

    struct!(__MODULE__, Map.put(attrs, :id, id))
  end

  @doc """
  Generate a unique ID for a chunk.
  """
  def generate_id(file_path, type, name, start_line) do
    data = "#{file_path}:#{type}:#{name}:#{start_line}"
    :crypto.hash(:md5, data) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  end

  @doc """
  Add embedding to a chunk.
  """
  def with_embedding(%__MODULE__{} = chunk, embedding) when is_list(embedding) do
    %{chunk | embedding: embedding}
  end

  @doc """
  Check if chunk has an embedding.
  """
  def has_embedding?(%__MODULE__{embedding: nil}), do: false
  def has_embedding?(%__MODULE__{embedding: emb}) when is_list(emb), do: true

  @doc """
  Convert chunk to a format suitable for display.
  """
  def to_display_string(%__MODULE__{} = chunk) do
    """
    ## #{chunk.file_path} (#{chunk.type}: #{chunk.name})
    Lines #{chunk.start_line}-#{chunk.end_line}

    ```#{chunk.language}
    #{chunk.text}
    ```
    """
  end
end
