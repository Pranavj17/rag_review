# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

RAG Review is an Elixir CLI tool that improves local LLM code reviews by providing relevant codebase context. It uses:
- **ChromaDB** for vector storage (similarity search)
- **Ollama** for embeddings (`all-minilm`) and LLM generation (`qwen2.5-coder:7b`)
- **AST-based parsing** for semantic code chunking (functions, modules)

The core insight: local LLMs give generic reviews because they only see the diff. RAG Review retrieves relevant code from the indexed codebase, so the LLM understands patterns, conventions, and related functions.

## Prerequisites

```bash
# 1. ChromaDB (vector database) - WITH PERSISTENT STORAGE
docker run -d -p 8000:8000 -v chroma_data:/chroma/chroma chromadb/chroma
# The -v flag creates a named volume so indexes survive container restarts

# 2. Ollama (local LLM server)
ollama serve

# 3. Required models
ollama pull all-minilm        # Embeddings (384 dimensions)
ollama pull qwen2.5-coder:7b  # LLM for reviews
```

> **Warning:** Without `-v chroma_data:/chroma/chroma`, all indexed data is lost when the container restarts!

## Common Commands

```bash
# Development
mix deps.get          # Install dependencies
mix compile           # Compile
mix format            # Format code
mix test              # Run tests
iex -S mix            # Interactive shell

# Build CLI
mix escript.build     # Creates ./rag_review executable

# CLI Usage
./rag_review index /path/to/repo --name my-project
./rag_review list
./rag_review health
git diff | ./rag_review review --repo my-project
git diff | ./rag_review review --quick  # No RAG context
```

## Architecture

```
Indexing:  Repo → FileWalker → Chunker → ElixirParser → OllamaProvider → ChromaDB
Review:    Diff → DiffParser → Retriever → ChromaDB → ContextBuilder → OllamaClient → Review
```

### Project Structure

```
lib/rag_review/
├── cli.ex                           # Entry point, argument parsing
├── indexing/
│   ├── pipeline.ex                  # Orchestrates: walk → chunk → embed → store
│   └── file_walker.ex               # Walks repo, respects .gitignore
├── parsing/
│   ├── chunk.ex                     # Chunk struct definition
│   ├── chunker.ex                   # Routes files to language parsers
│   └── languages/
│       └── elixir_parser.ex         # AST-based parsing via Code.string_to_quoted
├── embeddings/
│   └── ollama_provider.ex           # POST /api/embed to Ollama
├── store/
│   └── chroma_store.ex              # ChromaDB v2 API (direct HTTP, not library)
├── retrieval/
│   ├── diff_parser.ex               # Parse unified diff format
│   ├── retriever.ex                 # Generate queries, retrieve context
│   └── context_builder.ex           # Format chunks for LLM prompt
└── generation/
    ├── reviewer.ex                  # Orchestrates review pipeline
    ├── ollama_client.ex             # POST /api/chat to Ollama
    └── prompt_templates.ex          # System/user prompts
```

## Key Implementation Details

### Chunk Struct (`lib/rag_review/parsing/chunk.ex`)
```elixir
%Chunk{
  id: "uuid",              # Unique identifier
  text: "def foo...",      # Code content
  type: :function,         # :module | :function | :private_function
  name: "foo/2",           # Human-readable name
  file_path: "lib/a.ex",   # Relative path
  start_line: 10,          # Line numbers
  end_line: 25,
  language: :elixir,
  embedding: [0.1, ...]    # 384-dim vector (added during embedding)
}
```

### ChromaDB Store (`lib/rag_review/store/chroma_store.ex`)
- Uses **direct HTTP calls** to ChromaDB v2 API (the `chroma` hex library only supports v1)
- Base URL: `http://localhost:8000/api/v2/tenants/default_tenant/databases/default_database`
- Collections prefixed with `rag_review_` (e.g., `rag_review_memory`)
- Metadata stored: `file_path`, `chunk_type`, `chunk_name`, `start_line`, `end_line`, `language`

### Elixir Parser (`lib/rag_review/parsing/languages/elixir_parser.ex`)
- Uses `Code.string_to_quoted/2` with `columns: true, token_metadata: true`
- Extracts modules, public functions (`def`), private functions (`defp`)
- Error handling supports both integer and keyword list location formats (line 168-175)

### Ollama Provider (`lib/rag_review/embeddings/ollama_provider.ex`)
- Model: `all-minilm` (384 dimensions) - configured at line 13
- Embeds one text at a time (batch embedding had issues with some models)
- Truncates text to 8000 chars to avoid issues

### Default Models
- Embedding: `all-minilm` (in `ollama_provider.ex:13`)
- LLM: `qwen2.5-coder:7b` (in `ollama_client.ex:8` and `cli.ex:293`)

## Configuration

### Environment Variables
| Variable | Default | Description |
|----------|---------|-------------|
| `CHROMA_HOST` | `http://localhost:8000` | ChromaDB server |
| `OLLAMA_HOST` | `http://localhost:11434` | Ollama server |
| `RAG_REVIEW_MODEL` | `qwen2.5-coder:7b` | LLM for reviews |

### Runtime Config (`lib/rag_review/cli.ex:285-294`)
Config is set at runtime in `setup_config/0` because this runs as an escript (no Mix config available).

## Known Issues & Fixes

### 1. ChromaDB v2 API
The `chroma` hex library uses v1 API. We use direct HTTP calls to v2 endpoints.
- Fix: `chroma_store.ex` implements all operations via `Req.post/get/delete`

### 2. Ollama Batch Embedding
Some models fail with batch embedding (EOF errors).
- Fix: `ollama_provider.ex` embeds one text at a time in `embed_one/2`

### 3. Parser Error Location Format
`Code.string_to_quoted` returns errors as `{line_int, msg, token}` OR `{[line: X, column: Y], msg, token}`.
- Fix: `elixir_parser.ex:168-175` handles both formats with `format_location/1`

### 4. Escript Config
Escripts don't load `config/*.exs` files.
- Fix: `cli.ex:285-294` sets config via `Application.put_env/3` at runtime

## Testing

```bash
mix test                    # Run all tests
mix test test/specific.exs  # Run specific test file
```

Test files are in `test/` directory, mirroring the `lib/` structure.

## Adding New Features

### Adding a New Language Parser
1. Create `lib/rag_review/parsing/languages/NEW_parser.ex`
2. Implement `parse(source, file_path)` returning `{:ok, [%Chunk{}]}` or `{:error, reason}`
3. Add extension routing in `lib/rag_review/parsing/chunker.ex:23-32`

### Adding a New Review Type
1. Add prompt template in `lib/rag_review/generation/prompt_templates.ex`
2. Add type atom to `parse_review_type/1` in `lib/rag_review/cli.ex:282-283`
3. Handle new type in `Reviewer.review/3`

### Changing Default Models
- Embedding model: `lib/rag_review/embeddings/ollama_provider.ex:13`
- LLM model: `lib/rag_review/generation/ollama_client.ex:8`
- CLI default: `lib/rag_review/cli.ex:293`

## Debugging

### Check Services
```bash
./rag_review health
```

### Manual ChromaDB Check
```bash
curl http://localhost:8000/api/v2/version
curl http://localhost:8000/api/v2/tenants/default_tenant/databases/default_database/collections
```

### Manual Ollama Check
```bash
curl http://localhost:11434/api/tags  # List models
```

### Verbose Logging
The app uses `Logger`. Debug logs show during indexing/review operations.

## Documentation

- `README.md` - Quick start and usage
- `docs/how-it-works.md` - Detailed architecture and data flow
- This file - Development guidance for Claude Code
