#!/bin/bash
# pass the component image ref you want to be nudged as the only argument
# Can be used like so:
# kubectl get components -o json | jq -r '.items[] | select(.spec.application == "cluster-observability-operator-1-1") | select(.status.lastPromotedImage != null).status.lastPromotedImage'  | xargs -L1 hack/nudge_component.sh

image="${1:0:(-64)}"
new_sha="${1:(-64)}"
echo "Nudging $image" "to" "$new_sha"
sed -i "s|${image}.*|${image}${new_sha}\"|" bundle-patches/render_templates
