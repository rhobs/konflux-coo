#!/bin/bash

# update-release-notes.sh
#
# Populates the releaseNotes section (advisory type, fixed issues and fixed
# vulnerabilities/CVEs) of the Konflux Release payloads under release-payloads/
# for a given Jira fixVersion.
#
# The fixed issues and CVEs are taken from the Jira fixVersion:
#   * "Vulnerability" issues become entries in .spec.data.releaseNotes.cves
#     (key = the CVE-* label, component = the konflux component derived from the
#      pscomponent:* label).
#   * "Bug" and "Epic" issues that have a non-empty "Release Note Type" field
#     become entries in .spec.data.releaseNotes.issues.fixed. All other issue
#     types (and Bugs/Epics without a Release Note Type) are ignored.
#
# The advisory type is DERIVED from the fixed issues:
#   * RHSA  if any Vulnerability is fixed  (security advisory)
#   * RHBA  else if any Bug is fixed       (bug fix advisory)
#   * RHEA  otherwise                      (enhancement advisory)
#
# Snapshots are populated by a separate script (hack/update-fbc.sh).
#
# Authentication to the Jira REST API uses HTTP basic auth via environment
# variables:
#   JIRA_EMAIL      - your atlassian account e-mail
#   JIRA_API_TOKEN  - an API token (https://id.atlassian.com/manage-profile/security/api-tokens)

set -euo pipefail

JIRA_URL="https://redhat.atlassian.net"
VERSION_ID=""
VERSION_NAME=""
FROM_DIR=""
TARGET_DIR=""
STATUS_FILTER='AND statusCategory = Done'
SCAFFOLD=1
SOURCE_HOST=""
ISSUES_FILE=""
# Jira custom field holding the "Release Note Type" (a select list, e.g. "Bug Fix").
RN_TYPE_FIELD="customfield_10785"

usage() {
    cat <<EOF
Usage: $0 --version-id <jira-version-id> [options] [target-directory]

Required:
  --version-id ID     Jira version id (the number in the version URL, e.g.
                      https://redhat.atlassian.net/projects/COO/versions/107848/ -> 107848)

Options:
  --version NAME      Release version, e.g. 1.5.2. Defaults to the Jira version name.
                      Determines the release directory and component stream suffix.
  --from DIR          Existing release directory to scaffold the new one from.
                      Defaults to the highest-versioned release-payloads/release-* dir.
  --jira-url URL      Jira base URL (default: $JIRA_URL)
  --all-statuses      Include every issue in the fixVersion, not only resolved ones.
  --no-scaffold       Do not create the directory; only populate existing payload files.
  --issues-file FILE  Use a pre-fetched newline-delimited JSON file of Jira issues
                      instead of querying the REST API (offline mode). Each line is a
                      Jira issue object with .key and
                      .fields.{issuetype,labels,${RN_TYPE_FIELD}}.
  -h, --help          Show this help.

Environment:
  JIRA_EMAIL, JIRA_API_TOKEN   Credentials for the Jira REST API (basic auth).

Examples:
  JIRA_EMAIL=me\@redhat.com JIRA_API_TOKEN=xxxx \\
    $0 --version-id 107848 --version 1.5.2
EOF
}

die() { echo "Error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version-id) VERSION_ID="$2"; shift 2 ;;
        --version-id=*) VERSION_ID="${1#*=}"; shift ;;
        --version) VERSION_NAME="$2"; shift 2 ;;
        --version=*) VERSION_NAME="${1#*=}"; shift ;;
        --from) FROM_DIR="$2"; shift 2 ;;
        --from=*) FROM_DIR="${1#*=}"; shift ;;
        --jira-url) JIRA_URL="$2"; shift 2 ;;
        --jira-url=*) JIRA_URL="${1#*=}"; shift ;;
        --all-statuses) STATUS_FILTER=""; shift ;;
        --no-scaffold) SCAFFOLD=0; shift ;;
        --issues-file) ISSUES_FILE="$2"; shift 2 ;;
        --issues-file=*) ISSUES_FILE="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) die "Unknown option: $1" ;;
        *) TARGET_DIR="$1"; shift ;;
    esac
done

command -v jq >/dev/null || die "jq is required"
command -v yq >/dev/null || die "yq is required"
command -v curl >/dev/null || die "curl is required"

if [[ -z "$ISSUES_FILE" ]]; then
    [[ -n "$VERSION_ID" ]] || { usage; die "--version-id is required"; }
    [[ -n "${JIRA_EMAIL:-}" && -n "${JIRA_API_TOKEN:-}" ]] || \
        die "JIRA_EMAIL and JIRA_API_TOKEN environment variables must be set"
else
    [[ -f "$ISSUES_FILE" ]] || die "issues file not found: $ISSUES_FILE"
    [[ -n "$VERSION_NAME" ]] || die "--version is required when using --issues-file"
fi

SOURCE_HOST="${JIRA_URL#*://}"
SOURCE_HOST="${SOURCE_HOST%%/*}"

jira_get() {
    # $1 = path (starting with /), performs an authenticated GET
    curl -sSf -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
        -H "Accept: application/json" \
        "${JIRA_URL}${1}"
}

# ---------------------------------------------------------------------------
# Resolve the version name (needed for directory + stream suffix)
# ---------------------------------------------------------------------------
if [[ -z "$VERSION_NAME" ]]; then
    echo "Looking up Jira version $VERSION_ID ..." >&2
    VERSION_NAME=$(jira_get "/rest/api/3/version/${VERSION_ID}" | jq -r '.name')
    [[ -n "$VERSION_NAME" && "$VERSION_NAME" != "null" ]] || \
        die "could not resolve version name for id $VERSION_ID"
fi

echo "Release version: $VERSION_NAME" >&2

# component stream suffix, e.g. 1.5.2 -> 1-5
STREAM=$(echo "$VERSION_NAME" | awk -F. '{print $1"-"$2}')
[[ "$STREAM" =~ ^[0-9]+-[0-9]+$ ]] || die "could not derive component stream from version '$VERSION_NAME'"

if [[ -z "$TARGET_DIR" ]]; then
    TARGET_DIR="release-payloads/release-${VERSION_NAME}"
fi

# ---------------------------------------------------------------------------
# Fetch the fixVersion issues from Jira (paginated)
# ---------------------------------------------------------------------------
issues_json=$(mktemp)
trap 'rm -f "$issues_json"' EXIT

if [[ -n "$ISSUES_FILE" ]]; then
    echo "Using pre-fetched issues from $ISSUES_FILE" >&2
    jq -c '.' "$ISSUES_FILE" > "$issues_json"
else
    JQL="fixVersion = ${VERSION_ID} ${STATUS_FILTER}"
    echo "Querying Jira: ${JQL}" >&2

    start_at=0
    : > "$issues_json"
    while :; do
        body=$(jq -nc \
            --arg jql "$JQL" \
            --argjson startAt "$start_at" \
            --arg rnf "$RN_TYPE_FIELD" \
            '{jql:$jql, startAt:$startAt, maxResults:100,
              fields:["key","issuetype","labels","status",$rnf]}')
        page=$(curl -sSf -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
            -H "Accept: application/json" -H "Content-Type: application/json" \
            -X POST "${JIRA_URL}/rest/api/3/search/jql" -d "$body")
        echo "$page" | jq -c '.issues[]' >> "$issues_json"
        total=$(echo "$page" | jq -r '.total // 0')
        got=$(echo "$page" | jq -r '.issues | length')
        start_at=$((start_at + got))
        [[ "$got" -eq 0 || "$start_at" -ge "$total" ]] && break
    done
fi

issue_count=$(wc -l < "$issues_json")
[[ "$issue_count" -gt 0 ]] || die "no issues found for fixVersion $VERSION_ID"
echo "Fetched $issue_count issue(s)" >&2

# ---------------------------------------------------------------------------
# Map a pscomponent label to a konflux component name
#   pscomponent:cluster-observability-operator/cluster-observability-rhel9-operator
#     -> cluster-observability-operator-<stream>
# ---------------------------------------------------------------------------
map_component() {
    local ps="$1"
    ps="${ps#pscomponent:}"   # drop label prefix
    ps="${ps##*/}"            # drop "namespace/" prefix
    local out=() p
    IFS='-' read -ra _parts <<< "$ps"
    for p in "${_parts[@]}"; do
        [[ "$p" == "rhel9" ]] && continue   # drop the rhel9 segment
        out+=("$p")
    done
    local base; base=$(IFS='-'; echo "${out[*]}")
    echo "${base}-${STREAM}"
}

# ---------------------------------------------------------------------------
# Build the fixed-issues and cves lists, and derive the advisory type
# ---------------------------------------------------------------------------
fixed_json='[]'
cves_json='[]'
has_vuln=0
has_bug=0

while IFS=$'\x1f' read -r key itype rntype labels; do
    case "$itype" in
        Vulnerability)
            has_vuln=1
            cve=$(echo "$labels" | tr ' ' '\n' | grep -m1 '^CVE-' || true)
            ps=$(echo "$labels" | tr ' ' '\n' | grep -m1 '^pscomponent:' || true)
            if [[ -z "$cve" || -z "$ps" ]]; then
                echo "  ! skipping $key (Vulnerability without CVE/pscomponent label)" >&2
                continue
            fi
            comp=$(map_component "$ps")
            cves_json=$(jq -c --arg k "$cve" --arg c "$comp" \
                '. + [{key:$k, component:$c}]' <<< "$cves_json")
            ;;
        Bug|Epic)
            if [[ -z "$rntype" ]]; then
                echo "  - skipping $key ($itype without a Release Note Type)" >&2
                continue
            fi
            [[ "$itype" == "Bug" ]] && has_bug=1
            fixed_json=$(jq -c --arg id "$key" --arg src "$SOURCE_HOST" \
                '. + [{id:$id, source:$src}]' <<< "$fixed_json")
            ;;
        *)
            echo "  - skipping $key ($itype: not a Bug/Epic or Vulnerability)" >&2
            ;;
    esac
done < <(jq -r --arg rnf "$RN_TYPE_FIELD" \
    '[.key, .fields.issuetype.name, (.fields[$rnf].value // ""), (.fields.labels // [] | join(" "))] | join("\u001f")' \
    "$issues_json")

# de-duplicate and sort for stable output
fixed_json=$(jq -c 'unique_by(.id) | sort_by(.id)' <<< "$fixed_json")
cves_json=$(jq -c 'unique_by(.key + "|" + .component) | sort_by(.component, .key)' <<< "$cves_json")

if [[ "$has_vuln" -eq 1 ]]; then
    ADV_TYPE="RHSA"
elif [[ "$has_bug" -eq 1 ]]; then
    ADV_TYPE="RHBA"
else
    ADV_TYPE="RHEA"
fi

n_fixed=$(jq 'length' <<< "$fixed_json")
n_cves=$(jq 'length' <<< "$cves_json")
echo "Advisory type: $ADV_TYPE (fixed issues: $n_fixed, CVEs: $n_cves)" >&2

# ---------------------------------------------------------------------------
# Scaffold the release directory from a previous release if needed
# ---------------------------------------------------------------------------
if [[ ! -d "$TARGET_DIR" ]]; then
    [[ "$SCAFFOLD" -eq 1 ]] || die "target directory $TARGET_DIR does not exist (use scaffold, or create it first)"

    if [[ -z "$FROM_DIR" ]]; then
        FROM_DIR=$(find release-payloads -maxdepth 1 -type d -name 'release-*' \
            | grep -vFx "$TARGET_DIR" \
            | sort -t- -k2 -V | tail -n1)
    fi
    [[ -n "$FROM_DIR" && -d "$FROM_DIR" ]] || die "could not find a source directory to scaffold from (use --from)"

    from_version=$(basename "$FROM_DIR" | sed 's/^release-//')
    echo "Scaffolding $TARGET_DIR from $FROM_DIR (v${from_version} -> v${VERSION_NAME})" >&2
    cp -r "$FROM_DIR" "$TARGET_DIR"

    # bump version strings: dotted (1.5.1 -> 1.5.2) and dashed patch (1-5-1- -> 1-5-2-)
    from_dashed=$(echo "$from_version" | tr . -)
    to_dashed=$(echo "$VERSION_NAME" | tr . -)
    find "$TARGET_DIR" -type f -name '*.yaml' -print0 | while IFS= read -r -d '' f; do
        sed -i "s/${from_version//./\\.}/${VERSION_NAME}/g; s/${from_dashed}-/${to_dashed}-/g" "$f"
    done
fi

# ---------------------------------------------------------------------------
# Populate the releaseNotes of every payload file in the target directory
# ---------------------------------------------------------------------------
shopt -s nullglob
files=("$TARGET_DIR"/release-*.yaml)
[[ ${#files[@]} -gt 0 ]] || die "no release-*.yaml payload files found in $TARGET_DIR"

# Render the arrays as clean block-style YAML (unquoted keys) for loading.
fixed_yaml=$(mktemp); cves_yaml=$(mktemp)
trap 'rm -f "$issues_json" "$fixed_yaml" "$cves_yaml"' EXIT
echo "$fixed_json" | yq -P '.' > "$fixed_yaml"
echo "$cves_json" | yq -P '.' > "$cves_yaml"

for f in "${files[@]}"; do
    echo "Populating $f" >&2
    ADV_TYPE="$ADV_TYPE" FIXED_YAML="$fixed_yaml" CVES_YAML="$cves_yaml" \
    yq -i '
        .spec.data.releaseNotes.type = strenv(ADV_TYPE) |
        .spec.data.releaseNotes.issues.fixed = load(strenv(FIXED_YAML)) |
        .spec.data.releaseNotes.cves = load(strenv(CVES_YAML))
    ' "$f"
done

echo "Done. Populated ${#files[@]} payload file(s) in $TARGET_DIR" >&2
echo "Next: run hack/update-fbc.sh to set snapshots for the FBC payloads." >&2
