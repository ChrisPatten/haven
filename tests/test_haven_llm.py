"""Tests for the Haven LLM abstraction module."""

import json
import os
import time
from unittest.mock import MagicMock, patch

import httpx
import pytest

from shared.haven_llm import (
    LLMConfigError,
    LLMError,
    LLMProviderError,
    LLMResponse,
    LLMSettings,
    OllamaProvider,
    OllamaSettings,
    OpenAIProvider,
    OpenAISettings,
    get_llm_provider,
)


# ============================================================================
# Test Fixtures
# ============================================================================


@pytest.fixture
def ollama_settings():
    """Create test Ollama settings."""
    return OllamaSettings(
        base_url="http://localhost:11434",
        model="llama3.2",
        temperature=0.7,
    )


@pytest.fixture
def ollama_provider(ollama_settings):
    """Create test Ollama provider."""
    return OllamaProvider(settings=ollama_settings)


@pytest.fixture
def openai_settings():
    """Create test OpenAI settings."""
    return OpenAISettings(
        api_key="test-key",
        model="gpt-4",
        temperature=0.7,
    )


@pytest.fixture
def openai_provider(openai_settings):
    """Create test OpenAI provider."""
    return OpenAIProvider(settings=openai_settings)


# ============================================================================
# Settings Tests
# ============================================================================


def test_ollama_settings_defaults():
    """Test OllamaSettings default values."""
    settings = OllamaSettings()
    assert settings.base_url == "http://localhost:11434"
    assert settings.model == "llama3.2"
    assert settings.temperature == 0.7
    assert settings.top_p == 0.95
    assert settings.top_k == 40


def test_openai_settings_defaults():
    """Test OpenAISettings default values."""
    settings = OpenAISettings(api_key="test-key")
    assert settings.api_key == "test-key"
    assert settings.model == "gpt-4"
    assert settings.temperature == 0.7


# ============================================================================
# OllamaProvider Tests
# ============================================================================


def test_ollama_provider_init(ollama_settings):
    """Test OllamaProvider initialization."""
    provider = OllamaProvider(settings=ollama_settings)
    assert provider.settings == ollama_settings


def test_ollama_provider_init_defaults():
    """Test OllamaProvider with default settings."""
    provider = OllamaProvider()
    assert provider.settings is not None
    assert provider.settings.model == "llama3.2"


@patch.dict(os.environ, {"OLLAMA_BASE_URL": "http://custom:11434", "OLLAMA_MODEL": "custom-model"})
def test_ollama_provider_env_override():
    """Test OllamaProvider respects environment variables."""
    provider = OllamaProvider()
    assert provider.settings.base_url == "http://custom:11434"
    assert provider.settings.model == "custom-model"


@patch("httpx.Client.post")
def test_ollama_generate_success(mock_post, ollama_provider):
    """Test successful Ollama text generation."""
    mock_response = MagicMock()
    mock_response.json.return_value = {
        "model": "llama3.2",
        "response": "The capital of France is Paris.",
        "prompt_eval_count": 10,
        "eval_count": 5,
    }
    mock_post.return_value = mock_response

    response = ollama_provider.generate(prompt="What is the capital of France?")

    assert isinstance(response, LLMResponse)
    assert response.text == "The capital of France is Paris."
    assert response.model == "llama3.2"
    assert response.provider == "ollama"
    assert response.usage["input"] == 10
    assert response.usage["output"] == 5


@patch("httpx.Client.post")
def test_ollama_generate_json_format(mock_post, ollama_provider):
    """Test Ollama generation with JSON format."""
    json_response = {"name": "Alice", "age": 30}
    mock_response = MagicMock()
    mock_response.json.return_value = {
        "model": "llama3.2",
        "response": json.dumps(json_response),
    }
    mock_post.return_value = mock_response

    response = ollama_provider.generate(
        prompt="Extract: Alice is 30 years old",
        format="json",
    )

    # JSON should be parsed into dict or returned as string
    assert isinstance(response.text, str)


@patch("httpx.Client.post")
def test_ollama_embed_success(mock_post, ollama_provider):
    """Test successful Ollama embeddings."""
    embedding = [0.1, 0.2, 0.3, 0.4, 0.5]
    mock_response = MagicMock()
    mock_response.json.return_value = {
        "embedding": embedding,
    }
    mock_post.return_value = mock_response

    result = ollama_provider.embed("Test text")

    assert result == embedding
    assert len(result) == 5


@patch("httpx.Client.post", side_effect=httpx.RequestError("Connection failed"))
def test_ollama_generate_error(mock_post, ollama_provider):
    """Test Ollama generate error handling."""
    with pytest.raises(LLMProviderError):
        ollama_provider.generate(prompt="Test")


@patch("httpx.Client.get")
def test_ollama_health_check_success(mock_get):
    """Test successful Ollama health check."""
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_get.return_value = mock_response

    provider = OllamaProvider()
    assert provider.health_check() is True


@patch("httpx.Client.get", side_effect=httpx.RequestError("Failed"))
def test_ollama_health_check_failure(mock_get):
    """Test failed Ollama health check."""
    provider = OllamaProvider()
    assert provider.health_check() is False


def test_ollama_provider_str(ollama_provider):
    """Test OllamaProvider string representation."""
    str_repr = str(ollama_provider)
    assert "OllamaProvider" in str_repr
    assert "localhost" in str_repr


# ============================================================================
# OpenAIProvider Tests
# ============================================================================


def test_openai_provider_init(openai_settings):
    """Test OpenAIProvider initialization."""
    provider = OpenAIProvider(settings=openai_settings)
    assert provider.settings == openai_settings


def test_openai_provider_missing_api_key():
    """Test OpenAIProvider raises error without API key."""
    with pytest.raises(LLMConfigError):
        OpenAIProvider(settings=OpenAISettings(api_key=""))


@patch.dict(os.environ, {"OPENAI_API_KEY": "sk-test123"})
def test_openai_provider_env_override():
    """Test OpenAIProvider respects environment variables."""
    provider = OpenAIProvider(settings=OpenAISettings(api_key=""))
    assert provider.settings.api_key == "sk-test123"


@patch("httpx.Client.post")
def test_openai_generate_success(mock_post, openai_provider):
    """Test successful OpenAI text generation."""
    mock_response = MagicMock()
    mock_response.json.return_value = {
        "output": [
            {
                "content": [
                    {"type": "output_text", "text": "Paris is the capital of France."}
                ]
            }
        ],
        "usage": {
            "input_tokens": 10,
            "output_tokens": 5,
            "total_tokens": 15,
        },
    }
    mock_post.return_value = mock_response

    response = openai_provider.generate(prompt="What is the capital of France?")

    assert isinstance(response, LLMResponse)
    assert response.text == "Paris is the capital of France."
    assert response.model == "gpt-4"
    assert response.provider == "openai"
    assert response.usage["input"] == 10
    assert response.usage["output"] == 5


@patch("httpx.Client.post")
def test_openai_embed_success(mock_post, openai_provider):
    """Test successful OpenAI embeddings."""
    embedding = [0.1] * 1536  # OpenAI embedding dimension
    mock_response = MagicMock()
    mock_response.json.return_value = {
        "data": [
            {
                "embedding": embedding,
            }
        ],
    }
    mock_post.return_value = mock_response

    result = openai_provider.embed("Test text")

    assert result == embedding
    assert len(result) == 1536


@patch("httpx.Client.post", side_effect=httpx.RequestError("Connection failed"))
def test_openai_generate_error(mock_post, openai_provider):
    """Test OpenAI generate error handling."""
    with pytest.raises(LLMProviderError):
        openai_provider.generate(prompt="Test")


@patch("httpx.Client.get")
def test_openai_health_check_success(mock_get):
    """Test successful OpenAI health check."""
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_get.return_value = mock_response

    provider = OpenAIProvider(settings=OpenAISettings(api_key="test"))
    assert provider.health_check() is True


@patch("httpx.Client.get", side_effect=httpx.RequestError("Failed"))
def test_openai_health_check_failure(mock_get):
    """Test failed OpenAI health check."""
    provider = OpenAIProvider(settings=OpenAISettings(api_key="test"))
    assert provider.health_check() is False


def test_openai_provider_str(openai_provider):
    """Test OpenAIProvider string representation."""
    str_repr = str(openai_provider)
    assert "OpenAIProvider" in str_repr
    assert "gpt-4" in str_repr


@patch("httpx.Client.post")
@patch("time.sleep")
def test_openai_retry_on_429_then_success(mock_sleep, mock_post, openai_provider):
    """Test that OpenAI retries on 429 and succeeds on second attempt."""
    # First call returns 429, second call succeeds
    mock_429_response = MagicMock()
    mock_429_response.status_code = 429
    mock_429_response.headers = {}  # No Retry-After header

    mock_success_response = MagicMock()
    mock_success_response.status_code = 200
    mock_success_response.json.return_value = {
        "output": [
            {
                "content": [
                    {"type": "output_text", "text": "Paris is the capital of France."}
                ]
            }
        ],
        "usage": {
            "input_tokens": 10,
            "output_tokens": 5,
            "total_tokens": 15,
        },
    }

    # Mock post to return 429 first, then success
    mock_post.side_effect = [mock_429_response, mock_success_response]

    response = openai_provider.generate(prompt="What is the capital of France?")

    # Should have made 2 calls (first failed, second succeeded)
    assert mock_post.call_count == 2
    # Should have slept once
    assert mock_sleep.call_count == 1
    # Should return the successful response
    assert isinstance(response, LLMResponse)
    assert response.text == "Paris is the capital of France."


@patch("httpx.Client.post")
@patch("time.sleep")
def test_openai_retry_with_retry_after_header(mock_sleep, mock_post, openai_provider):
    """Test that OpenAI respects Retry-After header."""
    mock_429_response = MagicMock()
    mock_429_response.status_code = 429
    mock_429_response.headers = {"retry-after": "2"}  # 2 second delay

    mock_success_response = MagicMock()
    mock_success_response.status_code = 200
    mock_success_response.json.return_value = {
        "output": [
            {
                "content": [
                    {"type": "output_text", "text": "Paris is the capital of France."}
                ]
            }
        ],
        "usage": {
            "input_tokens": 10,
            "output_tokens": 5,
            "total_tokens": 15,
        },
    }

    mock_post.side_effect = [mock_429_response, mock_success_response]

    response = openai_provider.generate(prompt="What is the capital of France?")

    # Should have slept with the Retry-After delay (2 seconds)
    mock_sleep.assert_called_once_with(2.0)
    assert isinstance(response, LLMResponse)


@patch("httpx.Client.post")
def test_openai_no_retry_on_400_error(mock_post, openai_provider):
    """Test that OpenAI does not retry on 400 Bad Request."""
    mock_400_response = MagicMock()
    mock_400_response.status_code = 400
    mock_400_response.raise_for_status.side_effect = httpx.HTTPError("400 Bad Request")
    mock_400_response.headers = {}

    mock_post.return_value = mock_400_response

    with pytest.raises(LLMProviderError):
        openai_provider.generate(prompt="Test")

    # Should have made only 1 call (no retries for 4xx errors)
    assert mock_post.call_count == 1


@patch("httpx.Client.post")
@patch("time.sleep")
def test_openai_retry_exhaustion(mock_sleep, mock_post, openai_provider):
    """Test that OpenAI fails after exhausting all retries."""
    # Always return 429
    mock_response = MagicMock()
    mock_response.status_code = 429
    mock_response.headers = {}

    mock_post.return_value = mock_response

    with pytest.raises(LLMProviderError, match="failed after 6 attempts"):
        openai_provider.generate(prompt="Test")

    # Should have made max_retries + 1 calls (default max_retries=3, so 4 total)
    assert mock_post.call_count == 4  # 3 retries + 1 initial = 4
    # Should have slept 3 times
    assert mock_sleep.call_count == 3


# ============================================================================
# Factory Function Tests
# ============================================================================


def test_get_llm_provider_default():
    """Test get_llm_provider defaults to Ollama."""
    provider = get_llm_provider()
    assert isinstance(provider, OllamaProvider)


def test_get_llm_provider_ollama():
    """Test get_llm_provider with explicit Ollama."""
    provider = get_llm_provider(provider_type="ollama")
    assert isinstance(provider, OllamaProvider)


def test_get_llm_provider_openai():
    """Test get_llm_provider with explicit OpenAI."""
    with patch.dict(os.environ, {"OPENAI_API_KEY": "sk-test"}):
        provider = get_llm_provider(provider_type="openai")
        assert isinstance(provider, OpenAIProvider)


def test_get_llm_provider_invalid():
    """Test get_llm_provider with invalid provider type."""
    with pytest.raises(LLMConfigError):
        get_llm_provider(provider_type="invalid")


@patch.dict(os.environ, {"LLM_PROVIDER": "ollama"})
def test_get_llm_provider_env():
    """Test get_llm_provider respects LLM_PROVIDER env var."""
    provider = get_llm_provider()
    assert isinstance(provider, OllamaProvider)


# ============================================================================
# LLMResponse Tests
# ============================================================================


def test_llm_response_creation():
    """Test LLMResponse creation."""
    response = LLMResponse(
        text="Hello world",
        model="test-model",
        provider="test",
        raw_response={"key": "value"},
        usage={"input": 10, "output": 5},
    )

    assert response.text == "Hello world"
    assert response.model == "test-model"
    assert response.provider == "test"
    assert str(response) == "Hello world"


def test_llm_response_str():
    """Test LLMResponse string representation."""
    response = LLMResponse(
        text="Test response",
        model="test",
        provider="test",
        raw_response={},
    )
    assert str(response) == "Test response"


# ============================================================================
# Error Classes Tests
# ============================================================================


def test_llm_error_inheritance():
    """Test error class hierarchy."""
    assert issubclass(LLMProviderError, LLMError)
    assert issubclass(LLMConfigError, LLMError)


def test_llm_provider_error():
    """Test LLMProviderError."""
    error = LLMProviderError("Test error")
    assert str(error) == "Test error"


def test_llm_config_error():
    """Test LLMConfigError."""
    error = LLMConfigError("Missing config")
    assert str(error) == "Missing config"

