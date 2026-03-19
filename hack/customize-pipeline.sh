#!/bin/bash
# run like so:
# ./hack/customize-pipeline.sh <pipeline file to customize> [more files]
branch="release-1.4"

add_submodule_tasks() {
    local file="$1"

    # Check if get-submodule-commit-labels task already exists
    if ! yq '.spec.pipelineSpec.tasks[] | select(.name == "get-submodule-commit-labels")' "$file" | grep -q "get-submodule-commit-labels"; then
        # Add get-submodule-commit-labels task after clone-repository
        export component
        yq -i '
            .spec.pipelineSpec.tasks += [{
                "name": "get-submodule-commit-labels",
                "params": [
                    {"name": "SOURCE-ARTIFACT", "value": "$(tasks.clone-repository.results.SOURCE_ARTIFACT)"},
                    {"name": "DOCKERFILE", "value": "$(params.dockerfile)"}
                ],
                "runAfter": ["clone-repository"],
                "taskRef": {"name": "get-submodule-commit-labels"}
            }]
        ' "$file"

        # Add LABELS parameter to build-images task
        yq -i '
            (.spec.pipelineSpec.tasks[] | select(.name == "build-images").params) += [{
                "name": "LABELS",
                "value": ["$(tasks.get-submodule-commit-labels.results.labels[*])"]
            }]
        ' "$file"

        # Add get-submodule-commit-labels to runAfter in build-images task
        yq -i '
            (.spec.pipelineSpec.tasks[] | select(.name == "build-images").runAfter) += ["get-submodule-commit-labels"]
        ' "$file"
    fi
}

add_slack_notification() {
    local file="$1"

    # Check if slack-webhook-notification task already exists in finally block
    if ! yq '.spec.pipelineSpec.finally[]? | select(.name == "slack-webhook-notification")' "$file" | grep -q "slack-webhook-notification"; then
        yq -i '
            .spec.pipelineSpec.finally += [{
                "name": "slack-webhook-notification",
                "params": [
                    {"name": "message", "value": "PipelineRun $(context.pipelineRun.name) failed"},
                    {"name": "secret-name", "value": "slack-notifications"},
                    {"name": "key-name", "value": "obo-cicd"}
                ],
                "taskRef": {
                    "params": [
                        {"name": "bundle", "value": "quay.io/konflux-ci/tekton-catalog/task-slack-webhook-notification:0.1"},
                        {"name": "name", "value": "slack-webhook-notification"},
                        {"name": "kind", "value": "Task"}
                    ],
                    "resolver": "bundles"
                },
                "when": [
                    {"input": "$(tasks.status)", "operator": "in", "values": ["Failed"]}
                ]
            }]
        ' "$file"
    fi
}

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

        add_submodule_tasks "$file"
    fi
    if [[ $action == "push" ]]; then
        add_slack_notification "$file"
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
