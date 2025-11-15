# Caption Comparison Tool

This tool compares caption quality between Apple's Foundation Multimodal model and Ollama vision models by processing images in a directory and generating a markdown comparison report.

## Building

From the `hostagent/` directory:

```bash
swift build -c release
```

The executable will be at: `.build/release/CaptionComparison`

## Usage

```bash
swift run CaptionComparison <directory>
# or after building:
.build/release/CaptionComparison <directory>
```

## Configuration

Create an optional `caption-config.yaml` file in the target directory to configure Ollama settings:

```yaml
ollama:
  url: "http://localhost:11434/api/generate"
  model: "llava:7b"
  timeoutMs: 60000
```

If the config file is not present, the tool uses defaults:
- URL: `http://localhost:11434/api/generate` (or `OLLAMA_API_URL` environment variable)
- Model: `llava:7b` (or `OLLAMA_VISION_MODEL` environment variable)
- Timeout: `60000` ms

## Output

The tool generates a `caption-comparison.md` file in the same directory with the following format:

```markdown
# image1.jpg

**Foundation Caption:**
A description of the image from Apple's Foundation Multimodal model

**Ollama Caption:**
A description of the image from the configured Ollama model

---

# image2.png

**Foundation Caption:**
Another description...

**Ollama Caption:**
Another description...

---
```

## Supported Image Formats

- JPEG (.jpg, .jpeg)
- PNG (.png)
- GIF (.gif)
- BMP (.bmp)
- TIFF (.tiff, .tif)
- HEIC/HEIF (.heic, .heif)
- WebP (.webp)

## Requirements

- macOS 14.0 or later
- Ollama server running (if using Ollama method)
- Swift 5.9 or later

