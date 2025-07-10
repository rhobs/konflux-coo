#!/bin/bash

# This script gets the images inside a given snapshot and compares them with the images in the repos render_templates file and the bundle CSV.
# It requires to be connected to the Konflux cluster

SNAPSHOT_NAME="${1}"
RENDER_TEMPLATES_FILE="bundle-patches/render_templates"

# Check for help flag
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "check-snapshot-images.sh - Compare Konflux snapshot images with bundle templates and CSV"
    echo ""
    echo "DESCRIPTION:"
    echo "    This script extracts container images from a given Konflux snapshot and compares"
    echo "    them with the images referenced in:"
    echo "    1. The repository's render_templates file (bundle-patches/render_templates)"
    echo "    2. The ClusterServiceVersion (CSV) file within the operator bundle"
    echo ""
    echo "    The script helps verify that snapshot images are properly referenced in the"
    echo "    operator bundle configuration files."
    echo ""
    echo "USAGE:"
    echo "    $0 <snapshot-name>"
    echo "    $0 -h|--help"
    echo ""
    echo "ARGUMENTS:"
    echo "    snapshot-name    Name of the Konflux snapshot to analyze"
    echo ""
    echo "EXAMPLES:"
    echo "    $0 cluster-observability-operator-1-2-9h6j9"
    echo "    $0 --help"
    echo ""
    echo "REQUIREMENTS:"
    echo "    - kubectl CLI tool with access to Konflux cluster"
    echo "    - oc CLI tool for image extraction"
    echo "    - yq CLI tool for YAML parsing"
    echo "    - render_templates file at bundle-patches/render_templates"
    exit 0
fi

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

bundle_image=""

# Iterate over each snapshot image
while IFS=':' read -r component_name image; do
    if [[ -n "$component_name" && -n "$image" ]]; then
        # Skip bundle images
        if [[ "$component_name" == cluster-observability-operator-bundle* ]]; then
            bundle_image="$image"
            continue
        fi
        echo -n "	$component_name ... "
        
        # Use grep to check if image exists in render_templates file
        if grep -q "$image" "$RENDER_TEMPLATES_FILE"; then
            echo -e "\033[32m✓\033[0m"
        else
            echo -e "\033[31m✗ NOT FOUND IN BUNDLE\033[0m"
        fi
    fi
done <<< "$images"

csv_images=""

echo "Comparing snapshot images with bundle CSV..."

if [[ -n "$bundle_image" ]]; then
    echo "Extracting CSV from bundle image..."
    
    # Create temporary directory for bundle extraction
    temp_dir=$(mktemp -d)
    
    # Extract the bundle contents using oc image extract
    if oc image extract "$bundle_image" --path="/:$temp_dir" --confirm; then
        # Look for the CSV file in the extracted manifests
        csv_file=$(find "$temp_dir/manifests" -name "*.clusterserviceversion.yaml" | head -1)
        
        if [[ -n "$csv_file" && -f "$csv_file" ]]; then
            echo "Found CSV file: $(basename "$csv_file")"
            
            # Extract images from the CSV using yq
            echo "Extracting images from CSV..."
            env_images=$(yq '.spec.install.spec.deployments[].spec.template.spec.containers[].env[]? | select(.name | test("RELATED_IMAGE.*")) | .value' "$csv_file" 2>/dev/null)

            related_images=$(yq '.spec.relatedImages[].image' "$csv_file" 2>/dev/null)
            
            csv_images=$(echo -e "$env_images\n$related_images" | grep -v '^$' | sort -u)
            
        else
            echo "No CSV file found in bundle"
        fi
    else
        echo "Failed to extract bundle image contents"
    fi
    
    # Clean up temporary directory
    rm -rf "$temp_dir"
else
    echo "No bundle image found in snapshot."
fi

if [[ -n "$csv_images" ]]; then
    # Compare each snapshot image with CSV images
    while IFS=':' read -r component_name image; do
        snapshot_suffix="${image:58}"
        if [[ -n "$component_name" && -n "$image" && "$component_name" != cluster-observability-operator-bundle* ]]; then
            echo -n "   $component_name ... "
            if echo "$csv_images" | grep -q "$snapshot_suffix"; then
                echo -e "\033[32m✓\033[0m"
            else
                echo -e "\033[31m✗ NOT FOUND IN CSV\033[0m"
            fi
        fi
    done <<< "$images"
else
    echo "No images found in CSV"
fi

