import Config

# Default configuration (can be overridden by runtime.exs or parent app config)

# ChromaDB configuration
config :chroma,
  host: "http://localhost:8000",
  api_base: "api",
  api_version: "v2"

# RAG Review configuration
config :rag_review,
  ollama_host: "http://localhost:11434",
  default_model: "qwen2.5-coder:7b"

# Import environment specific config
import_config "#{config_env()}.exs"
