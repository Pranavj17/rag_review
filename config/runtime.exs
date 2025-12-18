import Config

# Runtime configuration - reads environment variables at runtime
# This is important when used as a library dependency

# ChromaDB configuration
config :chroma,
  host: System.get_env("CHROMA_HOST", "http://localhost:8000"),
  api_base: "api",
  api_version: "v2"

# RAG Review configuration
config :rag_review,
  ollama_host: System.get_env("OLLAMA_HOST", "http://localhost:11434"),
  default_model: System.get_env("RAG_REVIEW_MODEL", "qwen2.5-coder:7b")
