defmodule RagReview.Retrieval.DiffParser do
  @moduledoc """
  Parse git diffs (unified format) and extract semantic information
  for context retrieval.
  """

  defmodule DiffAnalysis do
    @moduledoc "Analysis result from parsing a diff."
    defstruct [
      :files,
      :hunks,
      :added_lines,
      :removed_lines,
      :modified_symbols
    ]
  end

  defmodule ChangedFile do
    @moduledoc "Represents a changed file in a diff."
    defstruct [:path, :old_path, :status, :hunks, :language]
  end

  defmodule Hunk do
    @moduledoc "Represents a hunk (change block) in a diff."
    defstruct [:old_start, :old_count, :new_start, :new_count, :lines, :context, :file_path]
  end

  @doc """
  Parse a unified diff format string.

  Returns %DiffAnalysis{} with parsed information.
  """
  def parse(diff_string) when is_binary(diff_string) do
    files =
      diff_string
      |> String.split(~r/^diff --git /m)
      |> Enum.drop(1)
      |> Enum.map(&parse_file_diff/1)

    %DiffAnalysis{
      files: files,
      hunks: Enum.flat_map(files, & &1.hunks),
      added_lines: count_lines(files, "+"),
      removed_lines: count_lines(files, "-"),
      modified_symbols: extract_modified_symbols(files)
    }
  end

  @doc """
  Generate query strings for context retrieval from a diff analysis.

  These queries will be embedded and used to search the vector store.
  """
  def generate_queries(%DiffAnalysis{} = analysis) do
    # Query 1: File paths (helpful for finding related code)
    file_queries =
      analysis.files
      |> Enum.map(fn file ->
        "File: #{file.path}"
      end)

    # Query 2: Function/method names from hunk context headers
    symbol_queries =
      analysis.modified_symbols
      |> Enum.map(fn symbol ->
        "Function: #{symbol.name} in #{symbol.file}"
      end)

    # Query 3: Actual changed code snippets (most relevant)
    code_queries =
      analysis.hunks
      |> Enum.flat_map(fn hunk ->
        # Extract added lines as queries
        hunk.lines
        |> Enum.filter(&String.starts_with?(&1, "+"))
        |> Enum.map(&String.trim_leading(&1, "+"))
        |> Enum.filter(&(String.length(&1) > 20))
        |> Enum.take(3)
      end)
      |> Enum.take(5)

    # Query 4: Context lines from hunk headers (often contain function names)
    context_queries =
      analysis.hunks
      |> Enum.map(& &1.context)
      |> Enum.filter(&(&1 && String.length(&1) > 5))
      |> Enum.uniq()

    (file_queries ++ symbol_queries ++ code_queries ++ context_queries)
    |> Enum.uniq()
    |> Enum.take(10)
  end

  @doc """
  Get a summary of the diff for display.
  """
  def summary(%DiffAnalysis{} = analysis) do
    """
    Files changed: #{length(analysis.files)}
    Lines added: #{analysis.added_lines}
    Lines removed: #{analysis.removed_lines}
    Hunks: #{length(analysis.hunks)}
    Modified symbols: #{length(analysis.modified_symbols)}
    """
  end

  # Private implementation

  defp parse_file_diff(file_block) do
    lines = String.split(file_block, "\n")

    # Extract file paths from first line: "a/path b/path"
    {old_path, new_path} = extract_paths(List.first(lines, ""))

    # Detect language from extension
    language = detect_language(new_path || old_path || "")

    # Parse hunks
    hunks =
      file_block
      |> String.split(~r/^@@/m)
      |> Enum.drop(1)
      |> Enum.map(&parse_hunk(&1, new_path || old_path))

    %ChangedFile{
      path: new_path || old_path,
      old_path: old_path,
      status: determine_status(old_path, new_path),
      hunks: hunks,
      language: language
    }
  end

  defp extract_paths(line) do
    case Regex.run(~r/a\/(.+?)\s+b\/(.+)/, line) do
      [_, old_path, new_path] -> {old_path, new_path}
      _ -> {nil, nil}
    end
  end

  defp parse_hunk(hunk_text, file_path) do
    parts = String.split(hunk_text, "\n", parts: 2)
    header = List.first(parts, "")
    body = List.last(parts, "")

    # Parse "@@ -old_start,old_count +new_start,new_count @@ context"
    {old_start, old_count, new_start, new_count, context} =
      case Regex.run(~r/-(\d+),?(\d*)\s+\+(\d+),?(\d*)\s*@@(.*)/, header) do
        [_, os, oc, ns, nc, ctx] ->
          {
            parse_int(os),
            parse_int(oc, 1),
            parse_int(ns),
            parse_int(nc, 1),
            String.trim(ctx)
          }

        _ ->
          {1, 0, 1, 0, ""}
      end

    %Hunk{
      old_start: old_start,
      old_count: old_count,
      new_start: new_start,
      new_count: new_count,
      lines: String.split(body, "\n"),
      context: context,
      file_path: file_path
    }
  end

  defp parse_int("", default), do: default
  defp parse_int(str, _default), do: String.to_integer(str)
  defp parse_int(str), do: parse_int(str, 0)

  defp determine_status(nil, _new), do: :added
  defp determine_status(_old, nil), do: :deleted
  defp determine_status(old, new) when old == new, do: :modified
  defp determine_status(_old, _new), do: :renamed

  defp detect_language(path) do
    case Path.extname(path) do
      ".ex" -> :elixir
      ".exs" -> :elixir
      ".js" -> :javascript
      ".jsx" -> :javascript
      ".ts" -> :typescript
      ".tsx" -> :typescript
      ".py" -> :python
      _ -> :unknown
    end
  end

  defp count_lines(files, prefix) do
    files
    |> Enum.flat_map(& &1.hunks)
    |> Enum.flat_map(& &1.lines)
    |> Enum.count(&String.starts_with?(&1, prefix))
  end

  defp extract_modified_symbols(files) do
    files
    |> Enum.flat_map(fn file ->
      file.hunks
      |> Enum.filter(&(&1.context && &1.context != ""))
      |> Enum.map(fn hunk ->
        %{file: file.path, name: hunk.context}
      end)
    end)
    |> Enum.uniq_by(&{&1.file, &1.name})
  end
end
