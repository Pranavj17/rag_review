defmodule RagReview.Indexing.FileWalker do
  @moduledoc """
  Walk through a repository and yield files for indexing.

  Respects .gitignore and filters by supported extensions.
  """

  alias RagReview.Parsing.Chunker

  @doc """
  Walk a directory and return all indexable files.

  Options:
    - extensions: list of extensions to include (default: all supported)
    - ignore_patterns: additional patterns to ignore
  """
  def walk(repo_path, opts \\ []) do
    extensions = Keyword.get(opts, :extensions, Chunker.supported_extensions())
    extra_ignores = Keyword.get(opts, :ignore_patterns, [])
    ignore_patterns = default_ignore_patterns() ++ extra_ignores

    gitignore_patterns = load_gitignore(repo_path)
    all_ignores = ignore_patterns ++ gitignore_patterns

    repo_path
    |> Path.expand()
    |> do_walk(extensions, all_ignores, repo_path)
  end

  @doc """
  Stream files from a directory.
  More memory efficient for large repositories.
  """
  def stream(repo_path, opts \\ []) do
    Stream.resource(
      fn -> walk(repo_path, opts) end,
      fn
        [] -> {:halt, []}
        [file | rest] -> {[file], rest}
      end,
      fn _ -> :ok end
    )
  end

  @doc """
  Count files that would be indexed.
  """
  def count(repo_path, opts \\ []) do
    repo_path
    |> walk(opts)
    |> length()
  end

  # Private implementation

  defp do_walk(dir_path, extensions, ignores, repo_root) do
    case File.ls(dir_path) do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(fn entry ->
          full_path = Path.join(dir_path, entry)
          relative_path = Path.relative_to(full_path, repo_root)

          cond do
            should_ignore?(relative_path, ignores) ->
              []

            File.dir?(full_path) ->
              do_walk(full_path, extensions, ignores, repo_root)

            File.regular?(full_path) and has_extension?(entry, extensions) ->
              [%{path: full_path, relative_path: relative_path}]

            true ->
              []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp should_ignore?(path, patterns) do
    Enum.any?(patterns, fn
      %Regex{} = pattern -> Regex.match?(pattern, path)
      pattern when is_binary(pattern) -> String.contains?(path, pattern)
    end)
  end

  defp has_extension?(filename, extensions) do
    ext = Path.extname(filename)
    ext in extensions
  end

  defp load_gitignore(repo_path) do
    gitignore_path = Path.join(repo_path, ".gitignore")

    case File.read(gitignore_path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
        |> Enum.map(&gitignore_to_regex/1)
        |> Enum.filter(& &1)

      {:error, _} ->
        []
    end
  end

  defp gitignore_to_regex(pattern) do
    # Simple gitignore to regex conversion
    # This handles basic patterns, not full gitignore spec
    try do
      regex_pattern =
        pattern
        |> String.replace(".", "\\.")
        |> String.replace("**/", "(.*/)?")
        |> String.replace("*", "[^/]*")
        |> String.replace("?", ".")

      regex_pattern =
        if String.ends_with?(pattern, "/") do
          "^" <> regex_pattern
        else
          "^" <> regex_pattern <> "(/|$)"
        end

      Regex.compile!(regex_pattern)
    rescue
      _ -> nil
    end
  end

  defp default_ignore_patterns do
    [
      ~r/^\.git\//,
      ~r/^_build\//,
      ~r/^deps\//,
      ~r/^node_modules\//,
      ~r/^\.elixir_ls\//,
      ~r/^cover\//,
      ~r/^doc\//,
      ~r/^\.cache\//,
      ~r/^vendor\//,
      ~r/^dist\//,
      ~r/^build\//,
      ~r/^__pycache__\//,
      ~r/\.pyc$/,
      ~r/\.beam$/,
      ~r/\.ez$/,
      ~r/\.min\.js$/,
      ~r/\.bundle\.js$/
    ]
  end
end
