#!/bin/bash
# Download whisper.cpp base model for on-device transcription.
# Run this once before building for Android/Windows/Linux.

set -euo pipefail

MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
MODEL_DIR=""

if [[ "$OSTYPE" == "darwin"* ]]; then
    MODEL_DIR="$HOME/Library/Containers/com.rendergames.rlink/Data/Documents/whisper_models"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    MODEL_DIR="$HOME/.local/share/com.rendergames.rlink/whisper_models"
elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
    MODEL_DIR="$APPDATA/com.rendergames.rlink/whisper_models"
else
    echo "Unknown OS. Set MODEL_DIR manually."
    exit 1
fi

mkdir -p "$MODEL_DIR"
MODEL_PATH="$MODEL_DIR/ggml-base.bin"

if [[ -f "$MODEL_PATH" ]]; then
    echo "Model already exists: $MODEL_PATH"
    ls -lh "$MODEL_PATH"
    exit 0
fi

echo "Downloading whisper base model (~142 MB)..."
curl -L --progress-bar "$MODEL_URL" -o "$MODEL_PATH"

echo "Done: $MODEL_PATH"
ls -lh "$MODEL_PATH"
