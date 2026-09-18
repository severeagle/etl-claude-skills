#!/bin/bash

# Stop on error
set -euo pipefail

FOLDER_PATH=$1
SCHEMA_PATH="$(pwd)/$FOLDER_PATH/schema.py"
LOADER_PATH="$(pwd)/$FOLDER_PATH/loader.py"
MODELS_PATH="$(pwd)/db/src/models"
if [ -z $FOLDER_PATH ]; then
    echo "Provide path to folder where target pipeline exists"
    exit 0
elif [ ! -f $SCHEMA_PATH ]; then
    echo "Schema file not found!"
    exit 0
fi

# Create Model
claude \
  --model sonnet \
  --allowedTools "Edit(/$MODELS_PATH)" \
  -p "/schema-to-model $FOLDER_PATH"

# Create Loader
claude \
  --model sonnet \
  --allowedTools "Edit(/$LOADER_PATH/**)" \
  -p "/schema-to-loader $FOLDER_PATH"