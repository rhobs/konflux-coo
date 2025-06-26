#!/bin/bash

# Function to update a single FBC file
update_single_fbc() {
    local file="$1"
    local env="$2"
    pipeline="$(basename "$file")"
    fbc="${pipeline:14}"
    fbc="${fbc%.yaml}"
    
    latest_snap=$(kubectl get snapshots -l appstudio.openshift.io/component=coo-"$fbc" --sort-by='.metadata.creationTimestamp' --no-headers -o custom-columns=":metadata.name" | tail -n 3 | tac | xargs kubectl get snapshots -o json | jq -r ".items[] | select(.metadata.labels.\"appstudio.openshift.io/build-pipelinerun\" | startswith(\"coo-$fbc-on-push\")).metadata.name" | head -n1)
    
    if [[ -z "$latest_snap" ]]; then
        echo "Error: No latest snapshot found for component coo-$fbc to update file $file"
        return 1
    fi

    echo "Updating $file with latest snapshot: $latest_snap"
    
    sed -i "s/\(snapshot:\).*/\1 $latest_snap/" "$file"
    now=$(date +%Y-%m-%d-%H-%M)
    sed -i "s/\(name:\).*/\1 $latest_snap-$now/" "$file"
}

# Function to update all FBC files given a directory and environment
update_all_fbc() {
    local release_dir="$1"
    local env="$2"
    
    local file_pattern="release-stage-fbc-v4-*"
    if [[ "$env" == "prod" ]]; then
        file_pattern="release-prod-fbc-v4-*"
    fi
    
    for f in "$release_dir"/$file_pattern; do
        if [[ -f "$f" ]]; then
            echo "Processing $f..."
            update_single_fbc "$f" "$env"
        fi
    done
}

env="stage"
target=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --env)
            env="$2"
            if [[ "$env" != "stage" && "$env" != "prod" ]]; then
                echo "Error: Environment must be 'stage' or 'prod'"
                exit 1
            fi
            shift 2
            ;;
        *)
            target="$1"
            shift
            ;;
    esac
done

if [[ -n "$target" ]]; then
    if [[ -f "$target" ]]; then
        update_single_fbc "$target"
    elif [[ -d "$target" ]]; then
        echo "Processing directory $target for $env environment"
        update_all_fbc "$target" "$env"
    else
        echo "Error: $target is not a valid file or directory"
        exit 1
    fi
else
    echo "Usage: $0 [--env stage|prod] <file_or_directory>"
    echo "  Single file: $0 release-payloads/release-1.2.0/release-stage-fbc-v4-example.yaml"
    echo "  Directory:   $0 --env prod release-payloads/release-1.2.0/"
    echo "  Default env for directory: stage"
    exit 1
fi
