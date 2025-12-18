# How RAG Review Works

RAG Review improves local LLM code reviews by providing relevant codebase context before generating reviews. This document explains the architecture and data flow.

## The Problem

When reviewing code with a local LLM (like Qwen via Ollama), the model only sees the diff - it has no knowledge of:
- How the codebase is structured
- What patterns and conventions are used
- Related functions or modules
- The broader context of the change

This leads to generic, surface-level reviews that miss important issues.

## The Solution: RAG (Retrieval-Augmented Generation)

RAG Review solves this by:
1. **Indexing** your codebase into a vector database (ChromaDB)
2. **Retrieving** relevant code snippets when reviewing a diff
3. **Augmenting** the LLM prompt with this context
4. **Generating** a more informed, context-aware review

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           INDEXING PIPELINE                              │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   Git Repo ──▶ FileWalker ──▶ Chunker ──▶ Embedder ──▶ ChromaDB        │
│                    │              │            │                         │
│              (walks files,   (AST-based    (Ollama                      │
│               respects       parsing at    all-minilm                   │
│               .gitignore)    function      384-dim)                     │
│                              boundaries)                                 │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│                           REVIEW PIPELINE                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   Git Diff ──▶ DiffParser ──▶ QueryBuilder ──▶ Embedder ──▶ ChromaDB   │
│                    │               │                            │        │
│              (extracts        (generates                   (similarity   │
│               files,          semantic                      search)      │
│               hunks,          queries)                          │        │
│               symbols)                                          ▼        │
│                                                          ┌──────────┐   │
│                                                          │ Retrieved │   │
│                                                          │  Context  │   │
│                                                          └─────┬────┘   │
│                                                                │        │
│   ┌────────────────────────────────────────────────────────────┘        │
│   │                                                                      │
│   ▼                                                                      │
│  Context + Diff ──▶ PromptBuilder ──▶ Ollama LLM ──▶ Code Review        │
│                                        (qwen2.5-coder)                   │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

## Component Deep Dive

### 1. Indexing Pipeline

#### FileWalker (`lib/rag_review/indexing/file_walker.ex`)

Recursively walks the repository, respecting `.gitignore` rules:

```elixir
# Walks repo and returns list of files with metadata
files = FileWalker.walk("/path/to/repo")
# => [%{path: "/abs/path/file.ex", relative_path: "lib/file.ex"}, ...]
```

**Supported file types:** `.ex`, `.exs`, `.js`, `.jsx`, `.ts`, `.tsx`, `.py`

**Ignored by default:**
- `.git/`, `node_modules/`, `_build/`, `deps/`
- Binary files, images, compiled files
- Files matching `.gitignore` patterns

#### Chunker (`lib/rag_review/parsing/chunker.ex`)

Routes files to language-specific parsers based on extension:

```elixir
{:ok, chunks} = Chunker.chunk_file("/path/to/file.ex")
```

**Chunk struct:**
```elixir
%Chunk{
  id: "uuid-v4",           # Unique identifier
  text: "def foo...",      # Actual code content
  type: :function,         # :module, :function, :private_function
  name: "foo/2",           # Human-readable name
  file_path: "lib/a.ex",   # Relative path
  start_line: 10,          # Line numbers for reference
  end_line: 25,
  language: :elixir,
  embedding: [0.1, ...]    # Added during embedding phase
}
```

#### ElixirParser (`lib/rag_review/parsing/languages/elixir_parser.ex`)

Uses Elixir's native AST parser for semantic chunking:

```elixir
# Parses source code into semantic chunks
{:ok, ast} = Code.string_to_quoted(source, columns: true, token_metadata: true)
```

**What it extracts:**
- **Modules**: Full module definitions with docstrings
- **Functions**: Public functions (`def`) with full body
- **Private functions**: Private functions (`defp`) with full body

**Why AST-based chunking matters:**

Traditional chunking splits by line count (e.g., every 100 lines), which:
- Breaks functions in the middle
- Loses semantic meaning
- Creates overlapping, redundant chunks

AST-based chunking preserves complete units of code:
```
Traditional:              AST-based:
┌─────────────┐          ┌─────────────┐
│ lines 1-100 │          │ Module A    │
├─────────────┤          ├─────────────┤
│ lines 101-  │          │ function/2  │
│ 200 (broken │          ├─────────────┤
│ function)   │          │ helper/1    │
└─────────────┘          └─────────────┘
```

#### OllamaProvider (`lib/rag_review/embeddings/ollama_provider.ex`)

Generates vector embeddings using Ollama's embedding API:

```elixir
{:ok, embeddings} = OllamaProvider.embed(["code snippet 1", "code snippet 2"])
# => {:ok, [[0.1, 0.2, ...], [0.3, 0.4, ...]]}
```

**Model:** `all-minilm` (384 dimensions)
- Fast inference
- Good quality for code similarity
- Runs locally via Ollama

**API endpoint:** `POST http://localhost:11434/api/embed`

#### ChromaStore (`lib/rag_review/store/chroma_store.ex`)

Stores and queries vectors in ChromaDB:

```elixir
# Store chunks
{:ok, collection} = ChromaStore.get_or_create_collection("my-repo")
ChromaStore.upsert_chunks(collection, chunks_with_embeddings)

# Query for similar code
{:ok, results} = ChromaStore.query(collection, query_embedding, n_results: 10)
```

**Collection naming:** `rag_review_{repo_name}` (sanitized)

**Stored metadata per chunk:**
- `file_path`: For showing source location
- `chunk_type`: module/function/private_function
- `chunk_name`: Human-readable identifier
- `start_line`, `end_line`: Line numbers
- `language`: Programming language

### 2. Review Pipeline

#### DiffParser (`lib/rag_review/retrieval/diff_parser.ex`)

Parses unified diff format into structured analysis:

```elixir
{:ok, analysis} = DiffParser.parse(diff_string)
# => %DiffAnalysis{
#      files: [%{path: "lib/foo.ex", status: :modified}],
#      hunks: [%{file: "lib/foo.ex", old_start: 10, ...}],
#      added_lines: ["  def new_function..."],
#      removed_lines: ["  def old_function..."],
#      modified_symbols: ["new_function", "old_function"]
#    }
```

**Extracts:**
- Changed files and their status (added/modified/deleted)
- Individual hunks with line ranges
- Added and removed lines
- Modified symbols (function/class names from hunk headers)

#### Retriever (`lib/rag_review/retrieval/retriever.ex`)

Generates queries and retrieves relevant context:

```elixir
{:ok, context} = Retriever.retrieve_context(diff, "repo-name")
```

**Query generation strategy:**

1. **File-based queries**: "Functions in lib/foo.ex"
2. **Symbol-based queries**: Extract modified function names
3. **Content-based queries**: Key lines from the diff

**Retrieval process:**
1. Generate 5-10 semantic queries from diff analysis
2. Embed each query using Ollama
3. Query ChromaDB for top-K similar chunks per query
4. Deduplicate results (same chunk may match multiple queries)
5. Rank by relevance score (cosine similarity)

#### ContextBuilder (`lib/rag_review/retrieval/context_builder.ex`)

Formats retrieved chunks for LLM consumption:

```elixir
context_string = ContextBuilder.build(retrieved_chunks)
```

**Output format:**
```
## Relevant Codebase Context

### lib/memory/storage.ex (lines 45-67)
Type: function | Name: get/1

def get(key) do
  Repo.get_by(Memory, key: key)
end

---

### lib/memory/storage.ex (lines 70-85)
Type: function | Name: store/2
...
```

#### Reviewer (`lib/rag_review/generation/reviewer.ex`)

Orchestrates the full review pipeline:

```elixir
# Full RAG review
{:ok, result} = Reviewer.review(diff, "repo-name", type: :security)

# Quick review (no RAG context)
{:ok, result} = Reviewer.quick_review(diff, type: :general)
```

**Review types:**
- `:general` - Comprehensive code review
- `:security` - Security-focused analysis

#### PromptTemplates (`lib/rag_review/generation/prompt_templates.ex`)

Constructs prompts for the LLM:

**System prompt (general):**
```
You are an expert code reviewer. Analyze the provided git diff
and relevant codebase context to provide a thorough code review.

Focus on:
- Code correctness and potential bugs
- Code style and best practices
- Performance implications
- Maintainability and readability
...
```

**User prompt structure:**
```
## Codebase Context
{retrieved_context}

## Git Diff to Review
{diff}

Please provide a detailed code review.
```

#### OllamaClient (`lib/rag_review/generation/ollama_client.ex`)

Sends chat requests to Ollama:

```elixir
messages = [
  %{role: :system, content: system_prompt},
  %{role: :user, content: user_prompt}
]
{:ok, response} = OllamaClient.chat(messages, model: "qwen2.5-coder:7b")
```

**API endpoint:** `POST http://localhost:11434/api/chat`

**Default settings:**
- Model: `qwen2.5-coder:7b`
- Temperature: `0.3` (more focused/deterministic)
- Timeout: `300 seconds` (5 minutes for long reviews)

## Data Flow Example

Let's trace a complete review:

### Step 1: Index Repository

```bash
./rag_review index /path/to/my-app --name my-app
```

```
my-app/
├── lib/
│   ├── auth.ex        ──▶ 5 chunks (module + 4 functions)
│   ├── user.ex        ──▶ 8 chunks (module + 7 functions)
│   └── api/
│       └── handler.ex ──▶ 12 chunks
└── test/
    └── auth_test.exs  ──▶ 6 chunks

Total: 31 chunks stored in ChromaDB collection "rag_review_my-app"
```

### Step 2: Generate Review

```bash
git diff HEAD~1 | ./rag_review review --repo my-app
```

**Diff content:**
```diff
diff --git a/lib/auth.ex b/lib/auth.ex
@@ -45,6 +45,12 @@ defmodule MyApp.Auth do
+  def verify_token(token) do
+    # TODO: implement
+    :ok
+  end
```

**Query generation:**
1. "Functions in lib/auth.ex"
2. "Token verification authentication"
3. "verify_token implementation"

**Retrieved context (3 most relevant chunks):**
1. `MyApp.Auth` module definition (similarity: 0.92)
2. `MyApp.Auth.create_token/1` function (similarity: 0.87)
3. `MyApp.User.authenticate/2` function (similarity: 0.81)

**Final prompt to LLM:**
```
[System: You are an expert code reviewer...]

## Codebase Context

### lib/auth.ex (lines 1-20)
Type: module | Name: MyApp.Auth
defmodule MyApp.Auth do
  @moduledoc "Authentication functions"
  ...

### lib/auth.ex (lines 22-35)
Type: function | Name: create_token/1
def create_token(user) do
  ...

## Git Diff to Review
[the diff]

Please provide a detailed code review.
```

**LLM Response:**
```
## Code Review

### Issues Found

1. **Incomplete Implementation**
   The `verify_token/1` function returns `:ok` without actually
   verifying anything. Based on the existing `create_token/1`
   function in this module, token verification should:
   - Decode the token
   - Validate the signature
   - Check expiration

2. **Missing Error Handling**
   The existing auth functions return `{:ok, result}` or
   `{:error, reason}` tuples. This function should follow
   the same pattern.
...
```

## Why This Improves Reviews

### Without RAG (Quick Mode)

The LLM only sees the diff:
- Doesn't know the codebase conventions
- Can't see related functions
- Gives generic advice

**Example output:** "Consider adding error handling"

### With RAG

The LLM sees diff + relevant context:
- Understands existing patterns
- Sees related implementations
- Gives specific, actionable advice

**Example output:** "The existing `create_token/1` returns `{:ok, token}` or `{:error, reason}`. This function should follow the same pattern and actually decode/validate the token."

## Performance Characteristics

| Operation | Time | Notes |
|-----------|------|-------|
| Index 100 files | ~30s | Dominated by embedding time |
| Index 1000 files | ~5min | Batched in groups of 10 |
| Review (with RAG) | 15-60s | Depends on LLM model |
| Review (quick) | 10-30s | No retrieval step |

**Memory usage:**
- ChromaDB: ~100MB per 10K chunks
- Ollama embedding: ~500MB (all-minilm model)
- Ollama LLM: 4-8GB (qwen2.5-coder:7b)

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CHROMA_HOST` | `http://localhost:8000` | ChromaDB server URL |
| `OLLAMA_HOST` | `http://localhost:11434` | Ollama server URL |
| `RAG_REVIEW_MODEL` | `qwen2.5-coder:7b` | LLM model for reviews |

### Embedding Model

The system uses `all-minilm` for embeddings:
- 384 dimensions
- Fast inference (~50ms per text)
- Good code similarity

To use a different model, modify `@default_model` in:
`lib/rag_review/embeddings/ollama_provider.ex`

### LLM Model

Default: `qwen2.5-coder:7b`

Other recommended models:
- `qwen2.5-coder:14b` - Better quality, slower
- `deepseek-coder:6.7b` - Fast, good for code
- `codellama:13b` - Meta's code model

## Limitations

1. **Language support**: Full AST parsing only for Elixir. JavaScript/Python use line-based chunking.

2. **Context window**: Retrieved context is limited to ~8K tokens to leave room for the diff and response.

3. **Embedding quality**: Code embeddings are less mature than text embeddings. Some semantic relationships may be missed.

4. **Cold start**: First review after indexing requires loading the embedding model (~5s).

## Future Improvements

- [ ] Tree-sitter parsing for JavaScript/TypeScript/Python
- [ ] Incremental indexing (only re-index changed files)
- [ ] Multi-repo support (cross-reference between repositories)
- [ ] Caching for repeated queries
- [ ] Streaming LLM responses
