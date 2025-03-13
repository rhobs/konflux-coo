#!/bin/bash

for f in .tekton/*push*; do
    image=$(yq '.spec.params[] | select(.name =="output-image").value' "$f")
    image="${image:0:(-13)}"
    if ! grep "$image" bundle-patches/render_templates > /dev/null; then
        # the bundle image can be skipped
        if [[ ${image:(-6)} != "bundle" ]]; then
            echo "$image is missing from render_templates"
            exit 1
        fi
    fi
    done
