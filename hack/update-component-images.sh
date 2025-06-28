#!/bin/bash

# This script updates the component images in the render_templates file
# it requires to be connected to the Konflux cluster

DEFAULT_APPLICATION_NAME="cluster-observability-operator-1-2"
DEFAULT_TEMPLATE_FILE="bundle-patches/render_templates"

application_name="${1:-$DEFAULT_APPLICATION_NAME}"
template_file="${2:-$DEFAULT_TEMPLATE_FILE}"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Usage: $0 [APPLICATION_NAME] [TEMPLATE_FILE]"
    echo "  APPLICATION_NAME: Konflux application name (default: $DEFAULT_APPLICATION_NAME)"
    echo "  TEMPLATE_FILE: Path to render_templates file (default: $DEFAULT_TEMPLATE_FILE)"
    echo ""
    echo "Examples:"
    echo "  $0"
    echo "  $0 my-app"
    echo "  $0 my-app custom-templates/render_templates"
    exit 0
fi

# Fetch the latest promoted images for the specified application excluding the operator bundle
images=$(kubectl get components -o yaml | yq '.items[] | select(.metadata.ownerReferences[]?.name == "'$application_name'") | select(.metadata.name != "cluster-observability-operator-bundle*") | .metadata.name + ":" + .status.lastPromotedImage')

if [[ ! -f "$template_file" ]]; then
    echo "Error: render_templates file not found at $template_file"
    exit 1
fi

echo "$images" | while IFS=':' read -r component_name image_url; do
    if [[ -n "$component_name" && -n "$image_url" ]]; then
      
      base_url=$(echo "$image_url" | cut -d'@' -f1)
      
      sed -i "s|${base_url}@sha[^\"[:space:]]*|${image_url}|g" "$template_file"
      echo -e "Updated $component_name with latest SHA:\n$image_url"
    fi
done
