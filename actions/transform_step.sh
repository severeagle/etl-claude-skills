#!/bin/bash

# Stop on error
set -euo pipefail

FOLDER_PATH=$1
SCHEMA_PATH="$(pwd)/$FOLDER_PATH/schema.py"
TRANSFORMER_PATH="$(pwd)/$FOLDER_PATH/transformer.py"
if [ -z $FOLDER_PATH ]; then
    echo "Provide path to folder where target pipeline exists"
    exit 0
elif [ ! -f $SCHEMA_PATH ]; then
    echo "Schema file not found!"
    exit 0
fi

# Run Claude script
bash .claude/actions/create_schema.sh $FOLDER_PATH
claude \
  --model sonnet \
  --allowedTools "Edit(/$SCHEMA_PATH),Edit(/$TRANSFORMER_PATH),Bash(docker exec:*),Bash(grep:*)" \
  -p "/schema-to-transformer $FOLDER_PATH"