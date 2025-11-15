"""Haven LLM Provider Abstraction.

Provides a unified interface for interacting with multiple LLM backends:
- Ollama (local, self-hosted models)
- OpenAI (API-based, proprietary models)

Usage:
    from shared.haven_llm import get_llm_provider, LLMProvider

    # Automatic provider selection from environment
    provider = get_llm_provider()

    # Or explicit instantiation
    from shared.haven_llm import OllamaProvider, OpenAIProvider
    provider = OllamaProvider(base_url="http://localhost:11434", model="llama3.2")

    # Use the provider
    response = provider.generate(
        prompt="What is the capital of France?",
        format="text"
    )
    print(response.text)
"""

from __future__ import annotations

import abc
import json
import os
from dataclasses import dataclass
from typing import Any, Dict, Optional, Union

import httpx

from shared.logging import get_logger

logger = get_logger(__name__)


# ============================================================================
# Configuration & Settings
# ============================================================================

# Cost per million tokens for OpenAI models
OPENAI_TOKEN_COSTS = {
    'gpt-5-nano': {
        'input': 0.05,
        'output': 0.40,
    },
    'gpt-5-mini': {
        'input': 0.25,
        'output': 2.00,
    },
    'gpt-5.1': {
        'input': 1.25,
        'output': 10.00,
    }
}

@dataclass
class LLMSettings:
    """Base settings for LLM providers."""

    timeout: float = 60.0
    """Request timeout in seconds."""

    max_retries: int = 3
    """Maximum number of retry attempts."""

    retry_delay: float = 1.0
    """Initial retry delay in seconds (exponential backoff)."""


@dataclass
class OllamaSettings(LLMSettings):
    """Settings specific to Ollama provider."""

    base_url: str = "http://localhost:11434"
    """Base URL for Ollama API."""

    model: str = "llama3.2"
    """Default model to use."""

    temperature: float = 0.7
    """Temperature for response generation (0.0-1.0)."""

    top_p: float = 0.95
    """Top-p (nucleus) sampling parameter."""

    top_k: int = 40
    """Top-k sampling parameter."""


@dataclass
class OpenAISettings(LLMSettings):
    """Settings specific to OpenAI provider."""

    api_key: str = ""
    """OpenAI API key."""

    model: str = "gpt-5-nano-2025-08-07"
    """Default model to use."""

    temperature: float = 0.7
    """Temperature for response generation (0.0-1.0)."""

    max_tokens: Optional[int] = None
    """Maximum tokens in response."""


# ============================================================================
# Response Types
# ============================================================================


@dataclass
class LLMResponse:
    """Response from an LLM provider."""

    text: str
    """The generated text response."""

    model: str
    """Model that generated the response."""

    provider: str
    """Name of the LLM provider (e.g., 'ollama', 'openai')."""

    raw_response: Dict[str, Any]
    """Raw response from the provider for debugging/inspection."""

    usage: Optional[Dict[str, int]] = None
    """Token usage information if available (input, output, total)."""

    def __str__(self) -> str:
        """Return the text content."""
        return self.text


# ============================================================================
# Provider Base Class
# ============================================================================


class LLMProvider(abc.ABC):
    """Abstract base class for LLM providers."""

    @abc.abstractmethod
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
        """Generate a response from the LLM.

        Args:
            prompt: The user prompt to send to the model.
            model: Override the default model. If None, uses provider default.
            temperature: Override temperature setting.
            format: Response format ('text', 'json', etc.). Defaults to 'text'.
            system_prompt: Optional system prompt to set context.
            **kwargs: Additional provider-specific parameters.

        Returns:
            LLMResponse with generated text and metadata.

        Raises:
            LLMError: If the request fails.
        """
        ...

    @abc.abstractmethod
    def embed(
        self,
        text: str,
        *,
        model: Optional[str] = None,
        **kwargs: Any,
    ) -> list[float]:
        """Generate embeddings for text.

        Args:
            text: Text to embed.
            model: Override the default model. If None, uses provider default.
            **kwargs: Additional provider-specific parameters.

        Returns:
            List of floats representing the embedding vector.

        Raises:
            LLMError: If the request fails.
        """
        ...

    @abc.abstractmethod
    def health_check(self) -> bool:
        """Check if the provider is accessible and healthy.

        Returns:
            True if provider is accessible, False otherwise.
        """
        ...

    def __str__(self) -> str:
        """Return provider name and configuration."""
        return f"{self.__class__.__name__}()"


# ============================================================================
# Error Classes
# ============================================================================


class LLMError(Exception):
    """Base exception for LLM-related errors."""

    pass


class LLMProviderError(LLMError):
    """Provider-specific error (network, invalid response, etc.)."""

    pass


class LLMConfigError(LLMError):
    """Configuration error (missing API key, invalid settings, etc.)."""

    pass


# ============================================================================
# Ollama Provider
# ============================================================================


class OllamaProvider(LLMProvider):
    """Ollama LLM provider for local/self-hosted models."""

    def __init__(self, settings: Optional[OllamaSettings] = None):
        """Initialize Ollama provider.

        Args:
            settings: OllamaSettings instance. If None, uses defaults and
                     environment variables.

        Raises:
            LLMConfigError: If required configuration is missing.
        """
        self.settings = settings or OllamaSettings()

        # Override with environment variables if present
        self.settings.base_url = os.getenv("OLLAMA_BASE_URL", self.settings.base_url)
        self.settings.model = os.getenv("OLLAMA_MODEL", self.settings.model)

        logger.info(
            "Initialized OllamaProvider",
            base_url=self.settings.base_url,
            model=self.settings.model,
        )

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
        """Generate response using Ollama.

        Supports Ollama API at /api/generate endpoint.
        """
        model = model or self.settings.model
        temperature = temperature if temperature is not None else self.settings.temperature

        # Build the complete prompt with system prompt if provided
        full_prompt = prompt
        if system_prompt:
            full_prompt = f"{system_prompt}\n\n{prompt}"

        payload: Dict[str, Any] = {
            "model": model,
            "prompt": full_prompt,
            "stream": False,
            "temperature": temperature,
            "top_p": self.settings.top_p,
            "top_k": self.settings.top_k,
        }

        # Add format if specified
        if format == "json":
            payload["format"] = "json"

        # Allow kwargs to override
        payload.update(kwargs)

        url = f"{self.settings.base_url}/api/generate"

        try:
            with httpx.Client(timeout=self.settings.timeout) as client:
                logger.debug("Calling Ollama generate", url=url, model=model)
                response = client.post(url, json=payload)
                response.raise_for_status()

            data = response.json()
            text = data.get("response", "").strip()

            # Parse JSON if format was json
            if format == "json":
                try:
                    # Try to extract JSON from the response
                    text = json.loads(text)
                except json.JSONDecodeError:
                    logger.warning("Ollama returned invalid JSON, returning raw text")

            input_tokens = data.get("prompt_eval_count", 0)
            output_tokens = data.get("eval_count", 0)
            
            logger.debug(
                "Ollama generate succeeded",
                model=model,
                response_length=len(str(text)),
                input_tokens=input_tokens,
                output_tokens=output_tokens,
                total_tokens=input_tokens + output_tokens,
            )

            return LLMResponse(
                text=text if isinstance(text, str) else json.dumps(text),
                model=model,
                provider="ollama",
                raw_response=data,
                usage={
                    "input": input_tokens,
                    "output": output_tokens,
                },
            )

        except httpx.HTTPError as e:
            logger.error("Ollama generate failed", url=url, error=str(e))
            raise LLMProviderError(f"Ollama request failed: {e}") from e

    def embed(
        self,
        text: str,
        *,
        model: Optional[str] = None,
        **kwargs: Any,
    ) -> list[float]:
        """Generate embeddings using Ollama.

        Supports Ollama API at /api/embeddings endpoint.
        """
        model = model or self.settings.model
        payload: Dict[str, Any] = {
            "model": model,
            "prompt": text,
        }
        payload.update(kwargs)

        url = f"{self.settings.base_url}/api/embeddings"

        try:
            with httpx.Client(timeout=self.settings.timeout) as client:
                logger.debug("Calling Ollama embeddings", url=url, model=model)
                response = client.post(url, json=payload)
                response.raise_for_status()

            data = response.json()
            embedding = data.get("embedding", [])

            logger.debug("Ollama embeddings succeeded", model=model, vector_dim=len(embedding))
            return embedding

        except httpx.HTTPError as e:
            logger.error("Ollama embeddings failed", url=url, error=str(e))
            raise LLMProviderError(f"Ollama embeddings request failed: {e}") from e

    def health_check(self) -> bool:
        """Check if Ollama is accessible."""
        url = f"{self.settings.base_url}/api/tags"
        try:
            with httpx.Client(timeout=5.0) as client:
                response = client.get(url)
                return response.status_code == 200
        except httpx.RequestError:
            logger.warning("Ollama health check failed", url=url)
            return False

    def __str__(self) -> str:
        """Return provider info."""
        return (
            f"OllamaProvider(base_url={self.settings.base_url}, "
            f"model={self.settings.model})"
        )


# ============================================================================
# OpenAI Provider
# ============================================================================


class OpenAIProvider(LLMProvider):
    """OpenAI LLM provider for GPT models."""

    def __init__(self, settings: Optional[OpenAISettings] = None):
        """Initialize OpenAI provider.

        Args:
            settings: OpenAISettings instance. If None, uses defaults and
                     environment variables.

        Raises:
            LLMConfigError: If required configuration is missing.
        """
        self.settings = settings or OpenAISettings()

        # Override with environment variables if present
        api_key = os.getenv("OPENAI_API_KEY", self.settings.api_key)
        if not api_key:
            raise LLMConfigError(
                "OpenAI API key not provided. Set OPENAI_API_KEY env var or "
                "pass api_key in OpenAISettings."
            )
        self.settings.api_key = api_key
        self.settings.model = os.getenv("OPENAI_MODEL", self.settings.model)

        logger.info(
            "Initialized OpenAIProvider",
            model=self.settings.model,
            api_key_length=len(api_key),
        )

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
        """Generate response using OpenAI API.

        Supports OpenAI Responses API.
        """
        model = model or self.settings.model
        temperature = temperature if temperature is not None else self.settings.temperature

        # Build inputs for Responses API
        # Content type should be "input_text" for input messages, not "output_text"
        inputs: list[Dict[str, Any]] = []
        if system_prompt:
            inputs.append(
                {
                    "role": "system",
                    "content": [{"type": "input_text", "text": system_prompt}],
                }
            )
        inputs.append(
            {
                "role": "user",
                "content": [{"type": "input_text", "text": prompt}],
            }
        )

        payload: Dict[str, Any] = {
            "model": model,
            "input": inputs,
        }

        # Only include temperature if the model supports it
        # Some models like gpt-5-nano don't support temperature
        # Check if model name suggests it doesn't support temperature
        if not model.startswith("gpt-5-nano"):
            payload["temperature"] = temperature

        # Note: Responses API doesn't support max_tokens parameter
        # Response length is controlled by the model's default behavior
        # if self.settings.max_tokens:
        #     payload["max_tokens"] = self.settings.max_tokens

        # Allow kwargs to override
        payload.update(kwargs)

        url = "https://api.openai.com/v1/responses"
        headers = {
            "Authorization": f"Bearer {self.settings.api_key}",
            "Content-Type": "application/json",
        }

        try:
            with httpx.Client(timeout=self.settings.timeout) as client:
                logger.debug("Calling OpenAI API", model=model)
                response = client.post(url, json=payload, headers=headers)
                
                # Log error details for debugging
                if response.status_code >= 400:
                    try:
                        error_data = response.json()
                        logger.error(
                            "OpenAI API error response",
                            status_code=response.status_code,
                            error=error_data,
                            model=model,
                        )
                    except Exception:
                        logger.error(
                            "OpenAI API error response (non-JSON)",
                            status_code=response.status_code,
                            text=response.text[:500],  # First 500 chars
                            model=model,
                        )
                
                response.raise_for_status()

                data = response.json()
                output_blocks = data.get("output", [])
                text_fragments: list[str] = []
                for block in output_blocks:
                    for content in block.get("content", []):
                        if content.get("type") == "output_text":
                            text_fragments.append(content.get("text", ""))

                text = "".join(text_fragments).strip()

                logger.debug(
                    "OpenAI API call succeeded",
                    model=model,
                    response_length=len(text),
                )

                usage = data.get("usage", {})
                input_tokens = usage.get("input_tokens", usage.get("prompt_tokens", 0))
                output_tokens = usage.get("output_tokens", usage.get("completion_tokens", 0))
                total_tokens = usage.get("total_tokens", input_tokens + output_tokens)

                cost = OPENAI_TOKEN_COSTS.get(model, {}).get('input', 0) * input_tokens / 1000000 + OPENAI_TOKEN_COSTS.get(model, {}).get('output', 0) * output_tokens / 1000000
                
                logger.debug(
                    "OpenAI API token usage",
                    model=model,
                    input_tokens=input_tokens,
                    output_tokens=output_tokens,
                    total_tokens=total_tokens,
                    cost=f"${cost:.6f}",
                )
                
                return LLMResponse(
                    text=text,
                    model=model,
                    provider="openai",
                    raw_response=data,
                    usage={
                        "input": input_tokens,
                        "output": output_tokens,
                        "total": total_tokens,
                    },
                )

        except httpx.HTTPError as e:
            logger.error("OpenAI API call failed", error=str(e))
            raise LLMProviderError(f"OpenAI request failed: {e}") from e

    def embed(
        self,
        text: str,
        *,
        model: Optional[str] = None,
        **kwargs: Any,
    ) -> list[float]:
        """Generate embeddings using OpenAI API.

        Uses text-embedding-3-small by default.
        """
        model = model or "text-embedding-3-small"
        payload: Dict[str, Any] = {
            "model": model,
            "input": text,
        }
        payload.update(kwargs)

        url = "https://api.openai.com/v1/embeddings"
        headers = {
            "Authorization": f"Bearer {self.settings.api_key}",
            "Content-Type": "application/json",
        }

        try:
            with httpx.Client(timeout=self.settings.timeout) as client:
                logger.debug("Calling OpenAI embeddings API", model=model)
                response = client.post(url, json=payload, headers=headers)
                response.raise_for_status()

            data = response.json()
            embedding = data["data"][0]["embedding"]

            logger.debug("OpenAI embeddings succeeded", model=model, vector_dim=len(embedding))
            return embedding

        except httpx.HTTPError as e:
            logger.error("OpenAI embeddings API call failed", error=str(e))
            raise LLMProviderError(f"OpenAI embeddings request failed: {e}") from e

    def health_check(self) -> bool:
        """Check if OpenAI API is accessible."""
        headers = {
            "Authorization": f"Bearer {self.settings.api_key}",
            "Content-Type": "application/json",
        }
        try:
            with httpx.Client(timeout=5.0) as client:
                # List models as a simple health check
                response = client.get(
                    "https://api.openai.com/v1/models",
                    headers=headers,
                )
                return response.status_code == 200
        except httpx.RequestError:
            logger.warning("OpenAI health check failed")
            return False

    def __str__(self) -> str:
        """Return provider info."""
        return f"OpenAIProvider(model={self.settings.model})"


# ============================================================================
# Factory Function
# ============================================================================


def get_llm_provider(
    provider_type: Optional[str] = None,
    settings: Optional[Union[OllamaSettings, OpenAISettings]] = None,
) -> LLMProvider:
    """Get an LLM provider instance.

    Automatically selects provider based on environment or explicit parameter.

    Environment Variables:
        LLM_PROVIDER: 'ollama' or 'openai' (defaults to 'ollama')
        OLLAMA_BASE_URL: Base URL for Ollama (default: http://localhost:11434)
        OLLAMA_MODEL: Model to use with Ollama (default: llama3.2)
        OPENAI_API_KEY: API key for OpenAI
        OPENAI_MODEL: Model to use with OpenAI (default: gpt-4)

    Args:
        provider_type: Override provider type ('ollama' or 'openai').
                      If None, uses LLM_PROVIDER env var or defaults to 'ollama'.
        settings: Provider-specific settings. If None, uses environment vars.

    Returns:
        LLMProvider instance.

    Raises:
        LLMConfigError: If provider type is invalid or required config is missing.
    """
    provider_type = provider_type or os.getenv("LLM_PROVIDER", "ollama").lower()

    if provider_type == "ollama":
        provider_settings = (
            settings if isinstance(settings, OllamaSettings) else OllamaSettings()
        )
        return OllamaProvider(settings=provider_settings)
    elif provider_type == "openai":
        provider_settings = (
            settings if isinstance(settings, OpenAISettings) else OpenAISettings()
        )
        return OpenAIProvider(settings=provider_settings)
    else:
        raise LLMConfigError(
            f"Unknown LLM provider: {provider_type}. "
            f"Supported: 'ollama', 'openai'"
        )


__all__ = [
    # Providers
    "LLMProvider",
    "OllamaProvider",
    "OpenAIProvider",
    # Settings
    "LLMSettings",
    "OllamaSettings",
    "OpenAISettings",
    # Response types
    "LLMResponse",
    # Errors
    "LLMError",
    "LLMProviderError",
    "LLMConfigError",
    # Factory
    "get_llm_provider",
]

