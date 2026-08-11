#!/usr/bin/env bash
# verify-dockerfile-versions.sh — verify (and optionally fix) VERSION labels in
# Dockerfiles against the canonical version found in each git submodule.
#
# Usage:
#   hack/verify-dockerfile-versions.sh          # verify only (exit 1 on mismatch)
#   hack/verify-dockerfile-versions.sh --fix    # fix mismatches in place
#
# Version sources per submodule type:
#   Go projects  → <submodule>/VERSION  (or a known embedded file)
#   UI plugins   → <submodule>/web/package.json  (.version field)
#
# The script expects submodules to be initialised (`git submodule update --init`).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

FIX=false
if [[ "${1:-}" == "--fix" ]]; then
    FIX=true
fi

RC=0
CHECKED=0
MISMATCHES=0
SKIPPED=0

# Colours (disabled when stdout is not a terminal).
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' RESET=''
fi

# ---------------------------------------------------------------------------
# Mapping: Dockerfile suffix → submodule directory.
# Dockerfiles that share a submodule (prom-op, p-o-admission-webhook,
# prometheus-config-reloader) all point to obo-prometheus-operator.
# ---------------------------------------------------------------------------
declare -A DOCKERFILE_TO_SUBMODULE=(
    [alertmanager]=alertmanager
    [prometheus]=prometheus
    [prom-op]=obo-prometheus-operator
    [p-o-admission-webhook]=obo-prometheus-operator
    [prometheus-config-reloader]=obo-prometheus-operator
    [obo]=observability-operator
    [thanos]=thanos
    [korrel8r]=korrel8r
    [perses]=perses
    [perses-operator]=perses-operator
    [cluster-health-analyzer]=cluster-health-analyzer
    [ui-dashboards]=ui-dashboards
    [ui-logging]=ui-logging
    [ui-logging-pf4]=ui-logging-pf4
    [ui-logging-pf5]=ui-logging-pf5
    [ui-monitoring]=ui-monitoring
    [ui-monitoring-pf5]=ui-monitoring-pf5
    [ui-monitoring-pf6]=ui-monitoring-pf6
    [ui-distributed-tracing]=ui-distributed-tracing
    [ui-distributed-tracing-pf4]=ui-distributed-tracing-pf4
    [ui-distributed-tracing-pf5]=ui-distributed-tracing-pf5
    [ui-distributed-tracing-pf6]=ui-distributed-tracing-pf6
    [ui-troubleshooting-panel]=ui-troubleshooting-panel
    [ui-troubleshooting-panel-pf6]=ui-troubleshooting-panel-pf6
)

# ---------------------------------------------------------------------------
# Dockerfiles that get their version injected at build time (via Tekton
# --build-arg or by reading the VERSION file inside the Dockerfile itself).
# These have no static ARG VERSION to verify — skip them.
# ---------------------------------------------------------------------------
declare -A DYNAMIC_VERSION=(
    [alertmanager]=1
    [prometheus]=1
)

# ---------------------------------------------------------------------------
# get_submodule_version DIR
#   Extracts the canonical version string from the submodule checkout.
#   Returns the version on stdout (without a leading "v").
# ---------------------------------------------------------------------------
get_submodule_version() {
    local dir="$1"

    # 1. Special case: korrel8r embeds version in a non-standard path.
    if [[ "$dir" == "korrel8r" ]]; then
        local vfile="${REPO_ROOT}/${dir}/internal/pkg/build/version.txt"
        if [[ -f "$vfile" ]]; then
            tr -d ' \t\n\r' < "$vfile"
            return 0
        fi
    fi

    # 2. web/package.json (UI plugins).  Checked before the generic VERSION
    #    file because some UI submodules ship a VERSION file that is not
    #    reliably updated across all release branches, whereas package.json
    #    is always maintained as part of the npm build workflow.
    local pjson="${REPO_ROOT}/${dir}/web/package.json"
    if [[ -f "$pjson" ]]; then
        jq -re '.version' "$pjson" | tr -d ' \t\n\r'
        return 0
    fi

    # 3. VERSION file at submodule root (Go projects).
    local vfile="${REPO_ROOT}/${dir}/VERSION"
    if [[ -f "$vfile" ]]; then
        tr -d ' \t\n\r' < "$vfile"
        return 0
    fi

    return 1
}

# ---------------------------------------------------------------------------
# get_dockerfile_version DOCKERFILE
#   Extracts the value of `ARG VERSION=…` from the Dockerfile.
#   Returns the raw value (may include a leading "v").
# ---------------------------------------------------------------------------
get_dockerfile_version() {
    local dockerfile="$1"
    # Match: ARG VERSION=<value> (possibly quoted)
    sed -n 's/^ARG VERSION=["'\'']\?\([^"'\'']*\)["'\'']\?$/\1/p' "$dockerfile" | tail -1
}

# ---------------------------------------------------------------------------
# normalise VERSION
#   Strips a leading "v" so that "v0.41.0" and "0.41.0" compare equal.
# ---------------------------------------------------------------------------
normalise() {
    local v="$1"
    echo "${v#v}"
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
# Dockerfile.bundle has no upstream submodule version — it tracks the product
# release (render_templates PRODUCT_VERSION). Skip it in this check.
echo "Verifying Dockerfile VERSION labels against submodule sources…"
echo ""

for suffix in $(printf '%s\n' "${!DOCKERFILE_TO_SUBMODULE[@]}" | sort); do
    dockerfile="${REPO_ROOT}/Dockerfile.${suffix}"
    submodule="${DOCKERFILE_TO_SUBMODULE[$suffix]}"
    submodule_dir="${REPO_ROOT}/${submodule}"

    if [[ ! -f "$dockerfile" ]]; then
        printf "${YELLOW}SKIP${RESET}  Dockerfile.%-35s (file not found)\n" "$suffix"
        ((SKIPPED++)) || true
        continue
    fi

    # Skip Dockerfiles that inject version dynamically at build time.
    if [[ -n "${DYNAMIC_VERSION[$suffix]:-}" ]]; then
        printf "${GREEN}OK${RESET}    Dockerfile.%-35s (version injected at build time)\n" "$suffix"
        ((CHECKED++)) || true
        continue
    fi

    # Ensure the submodule is checked out.
    if [[ ! -d "$submodule_dir" ]] || [[ -z "$(ls -A "$submodule_dir" 2>/dev/null)" ]]; then
        printf "${YELLOW}SKIP${RESET}  Dockerfile.%-35s (submodule %s not initialised)\n" "$suffix" "$submodule"
        ((SKIPPED++)) || true
        continue
    fi

    # Get the version from the submodule.
    submodule_version="$(get_submodule_version "$submodule" 2>/dev/null)" || true
    if [[ -z "$submodule_version" ]]; then
        printf "${YELLOW}SKIP${RESET}  Dockerfile.%-35s (no version source in %s)\n" "$suffix" "$submodule"
        ((SKIPPED++)) || true
        continue
    fi

    # Get the version from the Dockerfile.
    dockerfile_version="$(get_dockerfile_version "$dockerfile")"
    if [[ -z "$dockerfile_version" ]]; then
        printf "${YELLOW}SKIP${RESET}  Dockerfile.%-35s (no ARG VERSION= found)\n" "$suffix"
        ((SKIPPED++)) || true
        continue
    fi

    ((CHECKED++)) || true

    # Compare (ignoring the "v" prefix).
    norm_submodule="$(normalise "$submodule_version")"
    norm_dockerfile="$(normalise "$dockerfile_version")"

    if [[ "$norm_submodule" == "$norm_dockerfile" ]]; then
        printf "${GREEN}OK${RESET}    Dockerfile.%-35s version=%s\n" "$suffix" "$dockerfile_version"
    else
        ((MISMATCHES++)) || true
        # Preserve the "v" prefix convention from the Dockerfile.
        if [[ "$dockerfile_version" == v* ]]; then
            new_version="v${norm_submodule}"
        else
            new_version="${norm_submodule}"
        fi

        if $FIX; then
            # Use sed to replace the ARG VERSION= line.
            sed -i "s|^ARG VERSION=.*|ARG VERSION=${new_version}|" "$dockerfile"
            printf "${YELLOW}FIX${RESET}   Dockerfile.%-35s %s → %s\n" "$suffix" "$dockerfile_version" "$new_version"
        else
            printf "${RED}FAIL${RESET}  Dockerfile.%-35s Dockerfile=%s  submodule=%s (expected %s)\n" \
                "$suffix" "$dockerfile_version" "$submodule_version" "$new_version"
            RC=1
        fi
    fi
done

echo ""
echo "---"
echo "Checked: ${CHECKED}  Mismatches: ${MISMATCHES}  Skipped: ${SKIPPED}"

if $FIX && (( MISMATCHES > 0 )); then
    echo "Fixed ${MISMATCHES} Dockerfile(s)."
fi

exit $RC
