#!/bin/bash
# pass the component image ref you want to be nudged as the only argument
# Can be used like so:
# kubectl get components -o json | jq -r '.items[] | select(.spec.application == "cluster-observability-operator-1-3") | select(.status.lastPromotedImage != null).status.lastPromotedImage'  | xargs -L1 hack/nudge_component.sh
set -x
echo $1
image="${1%@sha256:*}"
new_sha="${1#*@sha256:}"
echo "Nudging $image" "to" "$new_sha"
#on MACOS
sed -i '' "s|${image}@sha256:.*|${image}@sha256:${new_sha}\"|" bundle-patches/render_templates
#on linux 
#sed -i "s|${image}@sha256:.*|${image}@sha256:${new_sha}\"|" bundle-patches/render_templates