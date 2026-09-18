#!/bin/bash

FOLDER_PATH=$1
SCHEMA_PATH="$(pwd)/$FOLDER_PATH/schema.py"
if [ -z $FOLDER_PATH ]; then
    echo "Provide path to folder where target pipeline exists"
    exit 0
elif [ ! -f $SCHEMA_PATH ]; then
    echo "Schema file not found!"
    exit 0
fi

# Run Claude script
out=$(claude \
  --model sonnet \
  --allowedTools "Edit(/$(pwd)/db/src/models)" \
  -p "/schema-to-model $FOLDER_PATH"
)
echo $out