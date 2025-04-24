branch="release-1.1"
for file in "$@"
do
    echo "Processing file $file"
    component="${file%-pu*.yaml}"
    action=$(basename `expr "$file" : '.*\(pu.*\.yaml\)'` .yaml | tr - _)
    dockerfile=$(yq '.spec.params[] | select(.name == "dockerfile").value' "$file")
    src="$(grep COPY "$dockerfile" | head -n1 | awk '{print $2}'| cut -d'/' -f1)"
    if [[ "$component" == *"bundle"* ]]; then
        export trigger="event == \"$action\" && target_branch == \"$branch\" &&
        (\"$component-pull-request.yaml\".pathChanged() ||
        \"$component-push.yaml\".pathChanged() ||
        \"$dockerfile\".pathChanged() ||
        \"bundle-patches/***\".pathChanged() ||
        \"observability-operator/***\".pathChanged())"
    else
        export trigger="event == \"$action\" && target_branch == \"$branch\" &&
        (\"$component-pull-request.yaml\".pathChanged() ||
        \"$component-push.yaml\".pathChanged() ||
        \"$dockerfile\".pathChanged() ||
        \"$src/***\".pathChanged())"
        yq -i '.metadata.annotations += {"build.appstudio.openshift.io/build-nudge-files": "bundle-patches/render_templates"}' "$file"
    fi
    yq -i '.metadata.annotations += {"pipelinesascode.tekton.dev/on-cel-expression": strenv(trigger)}' "$file"
    yq -i '(.spec.params[] | select(.name == "build-platforms").value | select(length == 1)) += ["linux/arm64","linux/ppc64le","linux/s390x"]' "$file"
    yq -i 'with(.spec.params; select(all_c(.name != "build-source-image")) | . += [{"name": "build-source-image", "value": "true"}])' "$file"
    # yq -i 'with(.spec.params; select(all_c(.name != "hermetic")) | . += [{"name": "hermetic", "value": "true"}])' "$file"
    # export gomod_prefetch="$src"
    # yq -i '.spec.params += [{"name": "hermetic", "value": [{"type": "gomod", "path": strenv(gomod_prefetch)}]' "$file"
done
