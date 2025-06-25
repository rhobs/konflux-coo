#!/bin/bash
# run like so:
# for f in release-payloads/release-1.2.0/release-stage-fbc-v4-*; do bash hack/update-fbc.sh $f; done

pipeline="$(basename "$1")"
fbc="${pipeline:14}"
fbc="${fbc%.yaml}"
latest_snap=$(kubectl get snapshots -l appstudio.openshift.io/component=coo-"$fbc" --sort-by='.metadata.creationTimestamp' --no-headers -o custom-columns=":metadata.name" | tail -n 3 | tac | xargs kubectl get snapshots -o json | jq -r ".items[] | select(.metadata.labels.\"appstudio.openshift.io/build-pipelinerun\" | startswith(\"coo-$fbc-on-push\")).metadata.name" | head -n1)
echo "latest_snap: $latest_snap"
sed -i "s/\(snapshot: \).*/\1$latest_snap/" "$1"
now=$(date +%Y-%m-%d-%H-%M)
sed -i "s/\(name: \).*/\1$latest_snap-$now/" "$1"
