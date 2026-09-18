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
claude \
  --model haiku \
  --allowedTools "Edit(/$SCHEMA_PATH)" \
  -p "/schema-column-translations $FOLDER_PATH"