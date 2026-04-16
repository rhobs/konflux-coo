#!/bin/bash
# run like so:
# ./hack/customize-pipeline.sh <pipeline file to customize> [more files]
branch="release-1.5"

add_submodule_tasks() {
    local file="$1"

    if [ -z "$(yq '.spec.pipelineSpec.tasks[] | select(.name == "get-submodule-commit-labels") | .name' "$file")" ]; then
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

        yq -i '
            (.spec.pipelineSpec.tasks[] | select(.name == "build-images").params) += [{
                "name": "LABELS",
                "value": ["$(tasks.get-submodule-commit-labels.results.labels[*])"]
            }]
        ' "$file"

        yq -i '
            (.spec.pipelineSpec.tasks[] | select(.name == "build-images").runAfter) += ["get-submodule-commit-labels"]
        ' "$file"
    fi
}

add_slack_notification() {
    local file="$1"

    if [ -z "$(yq '.spec.pipelineSpec.finally[]? | select(.name == "slack-webhook-notification") | .name' "$file")" ]; then
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

add_coverity_tasks() {
    local file="$1"
    local component="$2"

    if [ -z "$(yq '.spec.pipelineSpec.tasks[] | select(.name == "coverity-availability-check") | .name' "$file")" ]; then
        yq -i '
            .spec.pipelineSpec.tasks += [{
                "name": "coverity-availability-check",
                "runAfter": ["build-image-index"],
                "taskRef": {
                    "params": [
                        {"name": "name", "value": "coverity-availability-check"},
                        {"name": "bundle", "value": "quay.io/konflux-ci/tekton-catalog/task-coverity-availability-check:0.2@sha256:de35caf2f090e3275cfd1019ea50d9662422e904fb4aebd6ea29fb53a1ad57f5"},
                        {"name": "kind", "value": "task"}
                    ],
                    "resolver": "bundles"
                },
                "when": [
                    {"input": "$(params.skip-checks)", "operator": "in", "values": ["false"]}
                ]
            }]
        ' "$file"
    fi

    if [ -z "$(yq '.spec.pipelineSpec.tasks[] | select(.name == "sast-coverity-check") | .name' "$file")" ]; then
        if [[ "$component" == *"bundle"* ]]; then
            yq -i '
                .spec.pipelineSpec.tasks += [{
                    "name": "sast-coverity-check",
                    "params": [
                        {"name": "image-digest", "value": "$(tasks.build-image-index.results.IMAGE_DIGEST)"},
                        {"name": "image-url", "value": "$(tasks.build-image-index.results.IMAGE_URL)"},
                        {"name": "IMAGE", "value": "$(params.output-image)"},
                        {"name": "DOCKERFILE", "value": "$(params.dockerfile)"},
                        {"name": "CONTEXT", "value": "$(params.path-context)"},
                        {"name": "HERMETIC", "value": "$(params.hermetic)"},
                        {"name": "PREFETCH_INPUT", "value": "$(params.prefetch-input)"},
                        {"name": "IMAGE_EXPIRES_AFTER", "value": "$(params.image-expires-after)"},
                        {"name": "COMMIT_SHA", "value": "$(tasks.clone-repository.results.commit)"},
                        {"name": "BUILD_ARGS", "value": ["$(params.build-args[*])"]},
                        {"name": "BUILD_ARGS_FILE", "value": "$(params.build-args-file)"}
                    ],
                    "runAfter": ["coverity-availability-check"],
                    "taskRef": {
                        "params": [
                            {"name": "name", "value": "sast-coverity-check"},
                            {"name": "bundle", "value": "quay.io/konflux-ci/tekton-catalog/task-sast-coverity-check:0.3@sha256:368e1d92d1d6a44a6479ac4c15b274cb12c19d2207159a870e9e96b9b0f0afcc"},
                            {"name": "kind", "value": "task"}
                        ],
                        "resolver": "bundles"
                    },
                    "when": [
                        {"input": "$(params.skip-checks)", "operator": "in", "values": ["false"]},
                        {"input": "$(tasks.coverity-availability-check.results.STATUS)", "operator": "in", "values": ["success"]}
                    ],
                    "workspaces": [
                        {"name": "source", "workspace": "workspace"}
                    ]
                }]
            ' "$file"
        else
            yq -i '
                .spec.pipelineSpec.tasks += [{
                    "name": "sast-coverity-check",
                    "params": [
                        {"name": "image-digest", "value": "$(tasks.build-image-index.results.IMAGE_DIGEST)"},
                        {"name": "image-url", "value": "$(tasks.build-image-index.results.IMAGE_URL)"},
                        {"name": "IMAGE", "value": "$(params.output-image)"},
                        {"name": "DOCKERFILE", "value": "$(params.dockerfile)"},
                        {"name": "CONTEXT", "value": "$(params.path-context)"},
                        {"name": "HERMETIC", "value": "$(params.hermetic)"},
                        {"name": "PREFETCH_INPUT", "value": "$(params.prefetch-input)"},
                        {"name": "IMAGE_EXPIRES_AFTER", "value": "$(params.image-expires-after)"},
                        {"name": "COMMIT_SHA", "value": "$(tasks.clone-repository.results.commit)"},
                        {"name": "BUILD_ARGS", "value": ["$(params.build-args[*])"]},
                        {"name": "BUILD_ARGS_FILE", "value": "$(params.build-args-file)"},
                        {"name": "SOURCE_ARTIFACT", "value": "$(tasks.prefetch-dependencies.results.SOURCE_ARTIFACT)"},
                        {"name": "CACHI2_ARTIFACT", "value": "$(tasks.prefetch-dependencies.results.CACHI2_ARTIFACT)"}
                    ],
                    "runAfter": ["coverity-availability-check"],
                    "taskRef": {
                        "params": [
                            {"name": "name", "value": "sast-coverity-check-oci-ta"},
                            {"name": "bundle", "value": "quay.io/konflux-ci/tekton-catalog/task-sast-coverity-check-oci-ta:0.3@sha256:ab60e90de028036be823e75343fdc205418edcfa7c4de569bb5f8ab833bc2037"},
                            {"name": "kind", "value": "task"}
                        ],
                        "resolver": "bundles"
                    },
                    "when": [
                        {"input": "$(params.skip-checks)", "operator": "in", "values": ["false"]},
                        {"input": "$(tasks.coverity-availability-check.results.STATUS)", "operator": "in", "values": ["success"]}
                    ]
                }]
            ' "$file"
        fi
    fi
}

add_build_image_index_params() {
    local file="$1"

    yq -i '
        with(.spec.pipelineSpec.tasks[] | select(.name == "build-image-index").params;
            select(all_c(.name != "COMMIT_SHA")) |
            . += [{"name": "COMMIT_SHA", "value": "$(tasks.clone-repository.results.commit)"}]
        )
    ' "$file"
    yq -i '
        with(.spec.pipelineSpec.tasks[] | select(.name == "build-image-index").params;
            select(all_c(.name != "IMAGE_EXPIRES_AFTER")) |
            . += [{"name": "IMAGE_EXPIRES_AFTER", "value": "$(params.image-expires-after)"}]
        )
    ' "$file"
}

add_hermetic_params() {
    local file="$1"
    local component="$2"
    local src="$3"

    yq -i 'with(.spec.params; select(all_c(.name != "hermetic")) | . += [{"name": "hermetic", "value": "true"}])' "$file"
    yq -i 'del(.spec.params[] | select(.name == "prefetch-input"))' "$file"
    if [[ "$component" == *"bundle"* ]]; then
        yq -i '.spec.params += [{"name": "prefetch-input", "value": [{"type": "rpm", "path": "./bundle-patches"}]}]' "$file"
    else
        export gomod_prefetch="$src"
        if [[ -f "$src/web/package-lock.json" ]]; then
            export npm_prefetch="$src/web"
            yq -i '.spec.params += [{"name": "prefetch-input", "value": [{"type": "gomod", "path": ("./"+strenv(gomod_prefetch))}, {"type": "npm", "path": ("./"+strenv(npm_prefetch))}]}]' "$file"
        else
            yq -i '.spec.params += [{"name": "prefetch-input", "value": [{"type": "gomod", "path": ("./"+strenv(gomod_prefetch))}]}]' "$file"
        fi
    fi
}

add_cache_proxy() {
    local file="$1"

    yq -i 'with(.spec.params; select(all_c(.name != "enable-cache-proxy")) | . += [{"name": "enable-cache-proxy", "value": "true"}])' "$file"
    yq -i 'with(.spec.pipelineSpec.tasks[] | select(.name == "init").params; select(all_c(.name != "enable-cache-proxy")) | . += [{"name": "enable-cache-proxy", "value": "$(params.enable-cache-proxy)"}])' "$file"
    yq -i 'with(.spec.pipelineSpec.params; select(all_c(.name != "enable-cache-proxy")) | . += [{"name": "enable-cache-proxy", "default": "false", "description": "Enable cache proxy configuration", "type": "string"}])' "$file"
}

configure_trigger() {
    local file="$1"
    local component="$2"
    local action="$3"
    local dockerfile="$4"
    local src="$5"

    if [[ "$component" == *"bundle"* ]]; then
        export trigger="event == \"$action\" && target_branch == \"$branch\" &&
        (\".tekton/$component-pull-request.yaml\".pathChanged() ||
        \".tekton/$component-push.yaml\".pathChanged() ||
        \"$dockerfile\".pathChanged() ||
        \"bundle-patches/***\".pathChanged() ||
        \"observability-operator/bundle/***\".pathChanged())"
        if [[ $action == "push" ]]; then
            yq -i '.metadata.annotations += {"build.appstudio.openshift.io/build-nudge-files": "hack/update-catalog.sh"}' "$file"
            yq -i 'with(.spec.params; select(all_c(.name != "build-args")) | . += [{"name": "build-args", "value": ["REGISTRY=registry.redhat.io"]}])' "$file"
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

    yq -i '.metadata.annotations += {"pipelinesascode.tekton.dev/on-cel-expression": strenv(trigger)}' "$file"
}

configure_build() {
    local file="$1"
    local component="$2"

    yq -i '(.spec.params[] | select(.name == "build-platforms").value | select(length == 1)) += ["linux/arm64","linux/ppc64le","linux/s390x"]' "$file"
    yq -i 'with(.spec.params; select(all_c(.name != "build-source-image")) | . += [{"name": "build-source-image", "value": "true"}])' "$file"
    value="build-pipeline-$component" yq -i '.spec.taskRunTemplate += {"serviceAccountName": strenv(value)}' "$file"
}

for file in "$@"
do
    if [[ -d "$file" || "$(basename "$file")" == *"mirror-set"* ]]; then
        echo "Skipping $file"
        continue
    fi
    echo "Processing file $file"
    pipeline=$(basename "$file")
    component="${pipeline%-pu*.yaml}"
    action=$(basename `expr "$file" : '.*\(pu.*\.yaml\)'` .yaml | tr - _)
    dockerfile=$(yq '.spec.params[] | select(.name == "dockerfile").value' "$file")
    src="$(grep COPY "$dockerfile" | head -n1 | awk '{print $2}'| cut -d'/' -f1)"

    configure_trigger "$file" "$component" "$action" "$dockerfile" "$src"
    if [[ $action == "push" ]]; then
        add_slack_notification "$file"
    fi
    configure_build "$file" "$component"
    add_cache_proxy "$file"
    add_hermetic_params "$file" "$component" "$src"
    add_build_image_index_params "$file"
    add_coverity_tasks "$file" "$component"

    # Component-specific overrides
    case "$component" in
        alertmanager-*)
            # Alertmanager push builds need larger arm64 instances
            if [[ $action == "push" ]]; then
                yq -i '(.spec.params[] | select(.name == "build-platforms").value) |= map(select(. == "linux/arm64") = "linux-mxlarge/arm64")' "$file"
            fi
            ;;
        prometheus-*)
            # Prometheus builds need larger arm64 instances and extra memory
            yq -i '(.spec.params[] | select(.name == "build-platforms").value) |= map(select(. == "linux/arm64") = "linux-m4xlarge/arm64")' "$file"
            yq -i 'del(.spec.params[] | select(.name == "prefetch-input"))' "$file"
            yq -i '.spec.params += [{"name": "prefetch-input", "value": [{"type": "gomod", "path": "./prometheus"}, {"type": "npm", "path": "./prometheus/web/ui"}, {"type": "npm", "path": "./prometheus/web/ui/react-app"}]}]' "$file"
            if [ -z "$(yq '.spec.taskRunSpecs[]? | select(.pipelineTaskName == "build-images") | .pipelineTaskName' "$file")" ]; then
                yq -i '.spec.taskRunSpecs += [{
                    "pipelineTaskName": "build-images",
                    "stepSpecs": [{
                        "name": "build",
                        "computeResources": {
                            "requests": {"memory": "32Gi"},
                            "limits": {"memory": "64Gi"}
                        }
                    }]
                }]' "$file"
            fi
            ;;
    esac
done
