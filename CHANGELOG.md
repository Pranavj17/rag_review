# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2024-12-18

### Added

- Initial release
- CLI commands: `index`, `review`, `context`, `list`, `delete`, `health`
- AST-based Elixir parser for semantic code chunking
- ChromaDB integration for vector storage
- Ollama integration for embeddings (`all-minilm`) and LLM (`qwen2.5-coder:7b`)
- Diff parsing and query generation
- Context retrieval with similarity search
- Review prompt templates (general and security-focused)
- `context` command for shell script integration
