defmodule RagReview.Parsing.Languages.ElixirParser do
  @moduledoc """
  Parse Elixir source code using the native AST.

  Uses Code.string_to_quoted/2 to parse Elixir source and extract
  semantic chunks at function and module boundaries.
  """

  alias RagReview.Parsing.Chunk

  @doc """
  Parse an Elixir source file and extract semantic chunks.

  Returns {:ok, chunks} or {:error, reason}.
  """
  def parse(source, file_path) when is_binary(source) do
    case Code.string_to_quoted(source,
           columns: true,
           token_metadata: true,
           file: file_path
         ) do
      {:ok, ast} ->
        lines = String.split(source, "\n")
        chunks = extract_chunks(ast, lines, file_path)
        {:ok, chunks}

      {:error, {location, error, _token}} ->
        line_info = format_location(location)
        {:error, "Parse error at #{line_info}: #{inspect(error)}"}
    end
  end

  @doc """
  Parse a file from disk.
  """
  def parse_file(file_path) do
    case File.read(file_path) do
      {:ok, source} -> parse(source, file_path)
      {:error, reason} -> {:error, {:file_error, reason}}
    end
  end

  # Extract chunks from AST

  defp extract_chunks(ast, lines, file_path) do
    {_ast, definitions} = Macro.prewalk(ast, [], &collect_definitions/2)

    definitions
    |> Enum.reverse()
    |> Enum.map(fn def_info ->
      create_chunk(def_info, lines, file_path)
    end)
    |> Enum.filter(& &1)
  end

  # Collect module definitions
  defp collect_definitions(
         {:defmodule, meta, [{:__aliases__, _, parts}, [do: _body]]} = node,
         acc
       ) do
    module_name = Enum.map_join(parts, ".", &to_string/1)

    def_info = %{
      type: :module,
      name: module_name,
      line: meta[:line],
      end_line: meta[:end][:line]
    }

    {node, [def_info | acc]}
  end

  # Collect public function definitions
  defp collect_definitions(
         {:def, meta, [{name, _name_meta, args} | _rest]} = node,
         acc
       )
       when is_atom(name) do
    arity = length(args || [])

    def_info = %{
      type: :function,
      name: "#{name}/#{arity}",
      line: meta[:line],
      end_line: meta[:end][:line]
    }

    {node, [def_info | acc]}
  end

  # Collect private function definitions
  defp collect_definitions(
         {:defp, meta, [{name, _name_meta, args} | _rest]} = node,
         acc
       )
       when is_atom(name) do
    arity = length(args || [])

    def_info = %{
      type: :private_function,
      name: "#{name}/#{arity}",
      line: meta[:line],
      end_line: meta[:end][:line]
    }

    {node, [def_info | acc]}
  end

  # Skip other nodes
  defp collect_definitions(node, acc), do: {node, acc}

  # Create a chunk from definition info

  defp create_chunk(%{line: nil}, _lines, _file_path), do: nil

  defp create_chunk(def_info, lines, file_path) do
    start_line = def_info.line
    # If no end line, estimate based on next non-empty line or end of file
    end_line = def_info.end_line || estimate_end_line(lines, start_line)

    text =
      lines
      |> Enum.slice((start_line - 1)..(end_line - 1))
      |> Enum.join("\n")

    # Skip very short chunks (likely just declaration)
    if String.length(text) < 10 do
      nil
    else
      Chunk.new(%{
        text: text,
        type: def_info.type,
        name: def_info.name,
        file_path: file_path,
        start_line: start_line,
        end_line: end_line,
        language: :elixir
      })
    end
  end

  defp estimate_end_line(lines, start_line) do
    # Simple heuristic: look for 'end' at same or lower indentation
    start_indent = get_indent(Enum.at(lines, start_line - 1, ""))

    lines
    |> Enum.with_index(1)
    |> Enum.drop(start_line)
    |> Enum.find_value(length(lines), fn {line, idx} ->
      trimmed = String.trim(line)
      indent = get_indent(line)

      if trimmed == "end" and indent <= start_indent do
        idx
      else
        nil
      end
    end)
  end

  defp get_indent(line) do
    case Regex.run(~r/^(\s*)/, line) do
      [_, spaces] -> String.length(spaces)
      _ -> 0
    end
  end

  # Format error location - handles both integer and keyword list formats
  defp format_location(location) when is_integer(location), do: "line #{location}"
  defp format_location(location) when is_list(location) do
    line = Keyword.get(location, :line, "?")
    column = Keyword.get(location, :column)
    if column, do: "line #{line}, column #{column}", else: "line #{line}"
  end
  defp format_location(location), do: "location #{inspect(location)}"
end
