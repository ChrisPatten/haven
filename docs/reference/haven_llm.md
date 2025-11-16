# Haven LLM Provider Abstraction

The `haven_llm` module provides a unified, provider-agnostic interface for interacting with multiple LLM backends. This abstraction allows seamless switching between local (Ollama) and cloud-based (OpenAI) LLM providers without changing application code.

## Overview

**Location:** `shared/haven_llm.py`

**Supported Providers:**
- **Ollama**: Local, self-hosted open-source models (Llama, Mistral, Neural Chat, etc.)
- **OpenAI**: Cloud-based proprietary models (GPT-4, GPT-3.5-turbo, etc.)

**Key Features:**
- Unified `LLMProvider` interface for all providers
- Automatic provider selection from environment variables
- Support for both text generation and embeddings
- JSON-formatted responses
- System prompts and streaming-ready architecture
- Health checks for provider availability
- Comprehensive error handling
- Built-in logging and debugging support

## Installation

The module uses `httpx` for HTTP communication, which should already be available in the Haven environment:

```bash
# Typically already installed
pip install httpx
```

For local development with Ollama:
```bash
# Install Ollama from https://ollama.ai
ollama pull llama3.2
ollama serve
```

For OpenAI support, set the environment variable:
```bash
export OPENAI_API_KEY="sk-..."
```

## Quick Start

### Basic Usage with Automatic Provider Selection

```python
from shared.haven_llm import get_llm_provider

# Automatically selects provider from LLM_PROVIDER env var (default: Ollama)
provider = get_llm_provider()

response = provider.generate(
    prompt="What is machine learning?",
)
print(response.text)
```

### Explicit Ollama Provider

```python
from shared.haven_llm import OllamaProvider, OllamaSettings

settings = OllamaSettings(
    base_url="http://localhost:11434",
    model="llama3.2",
    temperature=0.7,
)
provider = OllamaProvider(settings=settings)

response = provider.generate(
    prompt="Explain neural networks.",
)
```

### Explicit OpenAI Provider

```python
from shared.haven_llm import OpenAIProvider, OpenAISettings

settings = OpenAISettings(
    model="gpt-4",
    temperature=0.8,
    max_tokens=2000,
)
provider = OpenAIProvider(settings=settings)

response = provider.generate(
    prompt="Write a poem about AI.",
)
```

## Core Components

### LLMProvider (Abstract Base Class)

The `LLMProvider` abstract base class defines the interface all providers must implement:

```python
class LLMProvider(abc.ABC):
    def generate(
        self,
        prompt: str,
        *,
        model: Optional[str] = None,
        temperature: Optional[float] = None,
        format: str = "text",
        system_prompt: Optional[str] = None,
        **kwargs: Any,
    ) -> LLMResponse:
        """Generate a response from the LLM."""
        ...

    def embed(
        self,
        text: str,
        *,
        model: Optional[str] = None,
        **kwargs: Any,
    ) -> list[float]:
        """Generate embeddings for text."""
        ...

    def health_check(self) -> bool:
        """Check if the provider is accessible."""
        ...
```

### LLMResponse

All `generate()` calls return an `LLMResponse` object:

```python
@dataclass
class LLMResponse:
    text: str                           # The generated response
    model: str                          # Model that generated it
    provider: str                       # Provider name ('ollama', 'openai')
    raw_response: Dict[str, Any]        # Raw API response
    usage: Optional[Dict[str, int]]     # Token usage {input, output, total}
```

**Usage:**

```python
response = provider.generate(prompt="Hello")
print(response.text)           # The actual response
print(response.model)          # Which model was used
print(response.usage)          # Token counts (if available)
print(response.raw_response)   # Raw API response for debugging
```

### Settings Classes

#### OllamaSettings

```python
@dataclass
class OllamaSettings(LLMSettings):
    base_url: str = "http://localhost:11434"  # Ollama API endpoint
    model: str = "llama3.2"                   # Default model
    temperature: float = 0.7                  # Creativity level (0.0-1.0)
    top_p: float = 0.95                       # Nucleus sampling
    top_k: int = 40                           # Top-k sampling
    timeout: float = 60.0                     # Request timeout
    max_retries: int = 3                      # Retry attempts
    retry_delay: float = 1.0                  # Initial retry delay
```

#### OpenAISettings

```python
@dataclass
class OpenAISettings(LLMSettings):
    api_key: str = ""                         # API key (from env if empty)
    model: str = "gpt-5-nano-2025-08-07"      # Default model
    temperature: float = 0.7                  # Creativity level (not supported by all models)
    max_tokens: Optional[int] = None          # Max response length
    timeout: float = 60.0                     # Request timeout
    max_retries: int = 3                      # Retry attempts
    retry_delay: float = 1.0                  # Initial retry delay
```

## Providers

### OllamaProvider

Local, self-hosted LLM provider using the Ollama API.

**Supported Operations:**
- `generate()`: Text generation with `/api/generate` endpoint
- `embed()`: Embeddings with `/api/embeddings` endpoint
- `health_check()`: Check `/api/tags` endpoint

**Example:**

```python
from shared.haven_llm import OllamaProvider

provider = OllamaProvider()

# Text generation
response = provider.generate(
    prompt="What is the Python GIL?",
    temperature=0.5,
)
print(response.text)

# JSON format
response = provider.generate(
    prompt="Extract emails from: John@example.com, Jane@test.org",
    format="json",
)

# Embeddings
embedding = provider.embed("The quick brown fox")
print(len(embedding))  # e.g., 1024 dimensions
```

**Configuration via Environment:**

```bash
export OLLAMA_BASE_URL="http://localhost:11434"
export OLLAMA_MODEL="llama3.2"
```

### OpenAIProvider

Cloud-based OpenAI models (GPT family) via the OpenAI API.

**Supported Operations:**
- `generate()`: Text generation via Responses API (`/v1/responses`)
- `embed()`: Embeddings via Embeddings API (`/v1/embeddings`)
- `health_check()`: Check Models endpoint (`/v1/models`)

**Example:**

```python
from shared.haven_llm import OpenAIProvider

provider = OpenAIProvider()

# Text generation
response = provider.generate(
    prompt="Write a Python decorator tutorial.",
    model="gpt-5-nano-2025-08-07",
    temperature=0.8,
    max_tokens=2000,
)
print(response.text)

# With system prompt
response = provider.generate(
    prompt="What is 2+2?",
    system_prompt="You are a math tutor. Be clear and concise.",
)

# Note: Some models (e.g., gpt-5-nano) don't support temperature parameter
# The provider will automatically skip temperature for unsupported models

# Embeddings
embedding = provider.embed("The quick brown fox")
print(len(embedding))  # 1536 for text-embedding-3-small
```

**Configuration via Environment:**

```bash
export OPENAI_API_KEY="sk-..."
export OPENAI_MODEL="gpt-5-nano-2025-08-07"  # or gpt-5-mini, gpt-5.1, etc.
```

## Common Usage Patterns

### Pattern 1: Text Generation with Custom Temperature

```python
provider = get_llm_provider()

# Deterministic responses (temperature closer to 0)
factual = provider.generate(
    prompt="What is the capital of France?",
    temperature=0.1,
)

# Creative responses (temperature closer to 1)
creative = provider.generate(
    prompt="Write a creative short story about cats.",
    temperature=0.9,
)
```

### Pattern 2: JSON-Formatted Extraction

```python
provider = get_llm_provider()

response = provider.generate(
    prompt="""Extract structured data from:
"Alice works at Google as a Software Engineer with 5 years experience."

Return JSON: {name, company, title, years_experience}""",
    format="json",
)

import json
data = json.loads(response.text)
print(data['name'])  # Alice
```

### Pattern 3: System Prompts for Context

```python
provider = get_llm_provider()

response = provider.generate(
    prompt="What programming languages should I learn?",
    system_prompt="""You are an expert Python developer and open-source advocate.
Prioritize Python and open-source technologies in your recommendations.""",
)
```

### Pattern 4: Provider Detection and Fallback

```python
from shared.haven_llm import get_llm_provider, OllamaProvider, LLMProviderError

# Try to use preferred provider
try:
    provider = get_llm_provider("openai")
except LLMProviderError:
    print("OpenAI not available, falling back to Ollama")
    provider = get_llm_provider("ollama")

response = provider.generate(prompt="Hello!")
```

### Pattern 5: Health Checks Before Processing

```python
from shared.haven_llm import get_llm_provider

provider = get_llm_provider()

if not provider.health_check():
    print("LLM provider is not available!")
    # Handle gracefully, skip processing, etc.
else:
    response = provider.generate(prompt="Process this...")
```

### Pattern 6: Embeddings for Semantic Search

```python
from shared.haven_llm import get_llm_provider

provider = get_llm_provider()

# Generate embeddings for documents
documents = [
    "Python is a programming language",
    "The capital of France is Paris",
    "Machine learning is part of AI",
]

embeddings = [provider.embed(doc) for doc in documents]

# Store in vector database (e.g., Qdrant)
for doc, embedding in zip(documents, embeddings):
    # vector_store.add(doc, embedding)
    pass
```

## Environment Variables

### Provider Selection

```bash
# Choose provider (default: 'ollama')
export LLM_PROVIDER="ollama"  # or "openai"
```

### Ollama Configuration

```bash
# Ollama API endpoint (default: http://localhost:11434)
export OLLAMA_BASE_URL="http://localhost:11434"

# Default model for Ollama
export OLLAMA_MODEL="llama3.2"  # or neural-chat, mistral, etc.
```

### OpenAI Configuration

```bash
# Required: OpenAI API key
export OPENAI_API_KEY="sk-..."

# Default model (default: gpt-5-nano-2025-08-07)
export OPENAI_MODEL="gpt-5-mini"  # or gpt-5.1, etc.
```

## Error Handling

The module defines three exception types:

```python
from shared.haven_llm import (
    LLMError,           # Base exception
    LLMProviderError,   # Network, API, etc.
    LLMConfigError,     # Missing config, invalid settings
)

try:
    response = provider.generate(prompt="test")
except LLMConfigError as e:
    print(f"Configuration error: {e}")
except LLMProviderError as e:
    print(f"Provider error: {e}")
except LLMError as e:
    print(f"Unexpected LLM error: {e}")
```

## Integration Examples

### Integration with Intents Classification

```python
from shared.haven_llm import get_llm_provider
from src.haven.intents.classifier import classify_artifact

provider = get_llm_provider()

response = provider.generate(
    prompt="Classify this as work or personal: 'Meeting at 3pm'",
    format="json",
)
```

### Integration with Slot Extraction

```python
from shared.haven_llm import get_llm_provider

provider = get_llm_provider()

response = provider.generate(
    prompt="Extract: name, phone, email from contact info...",
    format="json",
)
```

### Integration with Document Processing

```python
from shared.haven_llm import get_llm_provider

provider = get_llm_provider()

# Summarize documents
summary = provider.generate(
    prompt=f"Summarize: {document_text}",
    temperature=0.3,
)

# Extract entities
entities = provider.generate(
    prompt=f"Extract entities: {document_text}",
    format="json",
)
```

## Performance Considerations

### Ollama (Local)

- **Advantages**: Privacy, no API costs, works offline
- **Trade-offs**: Requires local computational resources
- **Model Selection**:
  - `llama3.2` (3B): Fast, lightweight
  - `llama3` (8B): Balance of speed and quality
  - `mistral`: Good for instruction following
  - `neural-chat`: Optimized for conversations

### OpenAI (Cloud)

- **Advantages**: No local setup, latest models, managed
- **Trade-offs**: API costs, network latency, data privacy
- **Model Selection**:
  - `gpt-5-nano-2025-08-07`: Fast, cost-effective (doesn't support temperature)
  - `gpt-5-mini`: Balanced performance and cost
  - `gpt-5.1`: Most capable
  - Cost tracking is automatically logged for all models

### Optimization Tips

1. **Batch requests** to reduce overhead
2. **Use lower temperature** (0.1-0.3) for factual tasks
3. **Set appropriate timeouts** for local/remote
4. **Cache embeddings** for repeated documents
5. **Use shorter prompts** to reduce token usage

## Debugging

### Enable Verbose Logging

```python
import logging
from shared.logging import get_logger

logger = get_logger("shared.haven_llm")
logger.setLevel(logging.DEBUG)
```

### Inspect Raw Responses

```python
response = provider.generate(prompt="test")
print("Raw response:", response.raw_response)
```

### Provider Information

```python
provider = get_llm_provider()
print(provider)  # Detailed provider info
print(provider.health_check())  # Is it available?
```

## Testing

The module includes comprehensive error handling and logging. Enable debug logging to see detailed request/response information:

```python
import logging
from shared.logging import get_logger

logger = get_logger("shared.haven_llm")
logger.setLevel(logging.DEBUG)
```

Cost tracking is automatically logged for OpenAI requests when available.

## Related Modules

- `shared/image_enrichment.py`: Image processing with OCR/vision
- `src/haven/intents/classifier/classifier.py`: Intent classification using LLMs
- `src/haven/intents/slots/extractor.py`: Slot extraction using LLMs
- `services/worker_service/workers/intents.py`: Intent worker using Ollama

## Migration Guide

If you have existing code using direct `httpx` calls to Ollama or OpenAI:

**Before:**
```python
import httpx
response = httpx.post("http://localhost:11434/api/generate", json=payload)
data = response.json()
text = data["response"]
```

**After:**
```python
from shared.haven_llm import get_llm_provider
provider = get_llm_provider()
response = provider.generate(prompt=...)
text = response.text  # Clean interface with automatic error handling
```

**OpenAI Responses API Migration:**

The OpenAI provider uses the Responses API (`/v1/responses`), not Chat Completions. The provider handles the request/response format automatically:

**Before:**
```python
import httpx
response = httpx.post(
    "https://api.openai.com/v1/chat/completions",
    headers={"Authorization": f"Bearer {api_key}"},
    json={"model": "gpt-4", "messages": [...]}
)
```

**After:**
```python
from shared.haven_llm import OpenAIProvider
provider = OpenAIProvider()
response = provider.generate(prompt="...", system_prompt="...")
```

## Future Enhancements

Potential additions to the module:

- [ ] Streaming response support
- [ ] Async/await interface
- [ ] Retry policy customization
- [x] Cost tracking for OpenAI (implemented)
- [ ] Support for Anthropic Claude
- [ ] Support for local LLMs (LLaMA.cpp, vLLM)
- [ ] Request/response caching
- [ ] Rate limiting
- [ ] Multi-provider fallback chains
- [ ] Structured output formats beyond JSON

