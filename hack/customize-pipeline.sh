#!/bin/bash
# run like so:
# ./hack/customize-pipeline.sh <pipeline file to customize> [more files]
branch="release-1.3"
for file in "$@"
do
    echo "Processing file $file"
    pipeline=$(basename "$file")
    component="${pipeline%-pu*.yaml}"
    action=$(basename `expr "$file" : '.*\(pu.*\.yaml\)'` .yaml | tr - _)
    dockerfile=$(yq '.spec.params[] | select(.name == "dockerfile").value' "$file")
    src="$(grep COPY "$dockerfile" | head -n1 | awk '{print $2}'| cut -d'/' -f1)"
    if [[ "$component" == *"bundle"* ]]; then
        export trigger="event == \"$action\" && target_branch == \"$branch\" &&
        (\".tekton/$component-pull-request.yaml\".pathChanged() ||
        \".tekton/$component-push.yaml\".pathChanged() ||
        \"$dockerfile\".pathChanged() ||
        \"bundle-patches/***\".pathChanged() ||
        \"observability-operator/bundle/***\".pathChanged())"
        if [[ $action == "push" ]]; then
            yq -i '.metadata.annotations += {"build.appstudio.openshift.io/build-nudge-files": "hack/update-catalog.sh"}' "$file"
            yq -i '.spec.params += [{"name": "build-args", "value": ["REGISTRY=registry.redhat.io"]}]' "$file"
        fi
    else
        export trigger="event == \"$action\" && target_branch == \"$branch\" &&
        (\".tekton/$component-pull-request.yaml\".pathChanged() ||
        \".tekton/$component-push.yaml\".pathChanged() ||
        \"$dockerfile\".pathChanged() ||
        \"$src\".pathChanged())"
        if [[ $action == "push" ]]; then
            yq -i '.metadata.annotations += {"build.appstudio.openshift.io/build-nudge-files": "bundle-patches/render_templates"}' "$file"
        fi
    fi
    yq -i '.metadata.annotations += {"pipelinesascode.tekton.dev/on-cel-expression": strenv(trigger)}' "$file"
    yq -i '(.spec.params[] | select(.name == "build-platforms").value | select(length == 1)) += ["linux/arm64","linux/ppc64le","linux/s390x"]' "$file"
    yq -i 'with(.spec.params; select(all_c(.name != "build-source-image")) | . += [{"name": "build-source-image", "value": "true"}])' "$file"
    yq -i 'with(.spec.params; select(all_c(.name != "enable-cache-proxy")) | . += [{"name": "enable-cache-proxy", "value": "true"}])' "$file"
    yq -i 'with(.spec.pipelineSpec.tasks[] | select(.name == "init").params; select(all_c(.name != "enable-cache-proxy")) | . += [{"name": "enable-cache-proxy", "value": "$(params.enable-cache-proxy)"}])' "$file"
    yq -i 'with(.spec.pipelineSpec.params; select(all_c(.name != "enable-cache-proxy")) | . += [{"name": "enable-cache-proxy", "default": "false", "description": "Enable cache proxy configuration", "type": "string"}])' "$file"
    value="build-pipeline-$component" yq -i '.spec.taskRunTemplate += {"serviceAccountName": strenv(value)}' "$file"
    # yq -i 'with(.spec.params; select(all_c(.name != "hermetic")) | . += [{"name": "hermetic", "value": "true"}])' "$file"
    # export gomod_prefetch="$src"
    # yq -i 'with(.spec.params; select(all_c(.name != "prefetch-input")) | . += [{"name": "prefetch-input", "value": "[{\"type\": \"gomod\", \"path\": \"./\(strenv(gomod_prefetch))\"}]"}])' "$file"
done
