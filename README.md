# RAG Review

Context-aware code review using local LLMs. Improves code review quality by retrieving relevant codebase context before generating reviews.

## How It Works

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│   Git Repo   │────▶│   Chunker    │────▶│   ChromaDB   │
│              │     │  (AST-based) │     │  (vectors)   │
└──────────────┘     └──────────────┘     └──────┬───────┘
                                                 │
┌──────────────┐     ┌──────────────┐            │
│   Git Diff   │────▶│  DiffParser  │────────────┤
│              │     │              │            │
└──────────────┘     └──────────────┘            ▼
                                          ┌──────────────┐
                     ┌──────────────┐     │  Retrieved   │
                     │  Ollama LLM  │◀────│   Context    │
                     │              │     └──────────────┘
                     └──────┬───────┘
                            │
                            ▼
                     ┌──────────────┐
                     │ Code Review  │
                     └──────────────┘
```

1. **Index** your codebase into ChromaDB (semantic chunks at function boundaries)
2. **Retrieve** relevant code when reviewing a diff (vector similarity search)
3. **Generate** context-aware reviews using local LLMs (Ollama)

For detailed architecture and data flow, see [How It Works](docs/how-it-works.md).

## Prerequisites

```bash
# 1. Start ChromaDB with persistent storage
docker run -d -p 8000:8000 -v chroma_data:/chroma/chroma chromadb/chroma

# 2. Start Ollama
ollama serve

# 3. Pull required models
ollama pull all-minilm        # Embeddings (384 dim)
ollama pull qwen2.5-coder:7b  # Code review LLM
```

> **Important:** The `-v chroma_data:/chroma/chroma` flag persists your indexes. Without it, all indexed data is lost when the container restarts.

## Installation

### Option 1: As a Dependency (Recommended)

Add to your `mix.exs`:

```elixir
defp deps do
  [
    {:rag_review, github: "Pranavj17/rag_review"}
  ]
end
```

Then run setup:

```bash
mix deps.get
mix compile
```

**Usage as library:**

```elixir
# Index a repository
RagReview.Indexing.Pipeline.run("/path/to/repo", name: "my-project")

# Retrieve context for a diff
{:ok, result} = RagReview.Retrieval.Retriever.retrieve_for_diff(diff, "my-project")
IO.puts(result.context)

# Full review
{:ok, %{review: review}} = RagReview.Generation.Reviewer.review(diff, "my-project")
```

### Option 2: Standalone CLI

```bash
# Clone and build
git clone https://github.com/Pranavj17/rag_review.git
cd rag_review
mix deps.get
mix escript.build

# Binary is at ./rag_review
```

## Usage

### Index a Repository

```bash
# Index with auto-detected name
./rag_review index /path/to/repo

# Index with custom name
./rag_review index /path/to/repo --name my-project

# Re-index (delete and rebuild)
./rag_review index /path/to/repo --name my-project --reindex
```

### Review a Diff

```bash
# Review with RAG context
git diff HEAD~1 | ./rag_review review --repo my-project

# Security-focused review
git diff main | ./rag_review review --repo my-project --type security

# Quick review (no RAG context, faster)
git diff | ./rag_review review --quick

# Review from file
./rag_review review --repo my-project --file changes.diff
```

### Get Context Only (Shell Script Integration)

```bash
# Get relevant context without LLM call
git diff | ./rag_review context --repo my-project

# JSON output for parsing
git diff | ./rag_review context --repo my-project --format json

# Limit number of chunks
git diff | ./rag_review context --repo my-project --limit 15
```

This is useful for integrating with existing review scripts (e.g., `ollama_review.sh`).

### Other Commands

```bash
# List indexed repositories
./rag_review list

# Check service health
./rag_review health

# Help
./rag_review help
```

## Example

```bash
# Index the memory project
$ ./rag_review index ~/Documents/memory --name memory
Indexing repository: /Users/pranav/Documents/memory
Collection name: memory
Found 119 files to index
Parsing: 119/119 - .formatter.exs
Extracted 661 chunks from 118 files
Embedding: batch 67/67

Indexing complete!
  Files processed: 118
  Files with errors: 1
  Total chunks: 661

# Review a security-sensitive change
$ git diff HEAD~1 | ./rag_review review --repo memory --type security
Generating security review...

### Security-Focused Code Review

#### 1. **Hardcoded Credentials**
The configuration includes database passwords directly in code:
```elixir
password: "dyN2j47yymsHnCErymNwzuKme"
```
This should use environment variables instead.
...
```

## Configuration

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `CHROMA_HOST` | `http://localhost:8000` | ChromaDB URL |
| `OLLAMA_HOST` | `http://localhost:11434` | Ollama URL |
| `RAG_REVIEW_MODEL` | `qwen2.5-coder:7b` | LLM for reviews |

## Project Structure

```
lib/rag_review/
├── cli.ex                    # Command-line interface
├── indexing/
│   ├── pipeline.ex           # Orchestrates indexing
│   └── file_walker.ex        # Repository traversal
├── parsing/
│   ├── chunk.ex              # Chunk data structure
│   ├── chunker.ex            # Routes to language parsers
│   └── languages/
│       └── elixir_parser.ex  # AST-based Elixir parsing
├── embeddings/
│   └── ollama_provider.ex    # Vector embeddings via Ollama
├── store/
│   └── chroma_store.ex       # ChromaDB operations
├── retrieval/
│   ├── diff_parser.ex        # Parse unified diffs
│   ├── retriever.ex          # Query generation + retrieval
│   └── context_builder.ex    # Format context for LLM
└── generation/
    ├── reviewer.ex           # Orchestrates review pipeline
    ├── ollama_client.ex      # LLM chat API
    └── prompt_templates.ex   # System/user prompts
```

## Why RAG Improves Reviews

**Without RAG:**
- LLM only sees the diff
- Generic, surface-level feedback
- Misses codebase conventions

**With RAG:**
- LLM sees diff + relevant context
- Specific, actionable feedback
- Understands existing patterns

See [detailed comparison](docs/how-it-works.md#why-this-improves-reviews) in the docs.

## Language Support

| Language | Parsing Method | Quality |
|----------|---------------|---------|
| Elixir (.ex, .exs) | AST-based | Semantic chunks at function boundaries |
| JavaScript/TypeScript | Line-based | Fixed-size chunks (TODO: tree-sitter) |
| Python | Line-based | Fixed-size chunks (TODO: tree-sitter) |

## License

MIT
