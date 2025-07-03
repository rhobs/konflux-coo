#!/bin/bash

# This script gets the images inside a given snapshot and compares them with the images in the render_templates file.
# it requires to be connected to the Konflux cluster

SNAPSHOT_NAME="${1}"
RENDER_TEMPLATES_FILE="bundle-patches/render_templates"

if [[ -z "$SNAPSHOT_NAME" ]]; then
    echo "Usage: $0 <snapshot-name>"
    echo "Example: $0 cluster-observability-operator-1-2-9h6j9"
    exit 1
fi

# Get the snapshot YAML and extract container images
echo "Extracting container images from snapshot: $SNAPSHOT_NAME"
images=$(kubectl get snapshot $SNAPSHOT_NAME -o yaml | yq '.spec.components[] | .name + ":" + .containerImage')

if [[ -z "$images" ]]; then
    echo "No container images found in snapshot $SNAPSHOT_NAME"
    exit 1
fi

if [[ ! -f "$RENDER_TEMPLATES_FILE" ]]; then
    echo "Error: render_templates file not found at $RENDER_TEMPLATES_FILE"
    exit 1
fi

echo "Comparing snapshot images with render_templates..."

# Iterate over each snapshot image
echo "$images" | while IFS=':' read -r component_name image; do
    if [[ -n "$component_name" && -n "$image" ]]; then
        # Skip bundle images
        if [[ "$component_name" == cluster-observability-operator-bundle* ]]; then
            continue
        fi
        echo -n "$component_name ... "
        
        # Use grep to check if image exists in render_templates file
        if grep -q "$image" "$RENDER_TEMPLATES_FILE"; then
            echo -e "\033[32m✓\033[0m"
        else
            echo -e "\033[31m✗ NOT FOUND\033[0m"
        fi
    fi
done


