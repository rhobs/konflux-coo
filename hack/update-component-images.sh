#!/bin/bash

# This script updates the component images in the render_templates file
# it requires to be connected to the Konflux cluster

DEFAULT_APPLICATION_NAME="cluster-observability-operator-1-5"
DEFAULT_TEMPLATE_FILE="bundle-patches/render_templates"

application_name="${1:-$DEFAULT_APPLICATION_NAME}"
template_file="${2:-$DEFAULT_TEMPLATE_FILE}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

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

log "Starting component image update"
log "Application: $application_name"
log "Template file: $template_file"

if [[ ! -f "$template_file" ]]; then
    log "ERROR: render_templates file not found at $template_file"
    exit 1
fi

log "Fetching promoted images from Konflux cluster..."
images=$(kubectl get components -o yaml | yq '.items[] | select(.spec.application == "'$application_name'") | select(.metadata.name != "cluster-observability-operator-bundle*") | .metadata.name + ":" + .status.lastPromotedImage')

if [[ -z "$images" ]]; then
    log "WARNING: No component images found for application '$application_name'"
    exit 0
fi

component_count=$(echo "$images" | wc -l | tr -d ' ')
log "Found $component_count component(s) to process"

updated=0
skipped=0

while IFS=':' read -r component_name image_url; do
    if [[ -n "$component_name" && -n "$image_url" ]]; then
        base_url=$(echo "$image_url" | cut -d'@' -f1)
        new_sha=$(echo "$image_url" | grep -o 'sha256:[a-f0-9]*')

        old_image=$(grep -o "${base_url}@sha[^\"[:space:]]*" "$template_file" | head -1)
        old_sha=$(echo "$old_image" | grep -o 'sha256:[a-f0-9]*')

        if [[ "$old_sha" == "$new_sha" ]]; then
            log "SKIP $component_name (already up to date)"
            skipped=$((skipped + 1))
        else
            sed -i "s|${base_url}@sha[^\"[:space:]]*|${image_url}|g" "$template_file"
            log "UPDATED $component_name"
            if [[ -n "$old_sha" ]]; then
                log "  old: $old_sha"
            else
                log "  old: (not found in template)"
            fi
            log "  new: $new_sha"
            updated=$((updated + 1))
        fi
    fi
done <<< "$images"

log "Done — $updated updated, $skipped unchanged"
