#!/bin/bash

REPO="rhobs/konflux-coo"

# Default to dry-run mode
DRY_RUN=true

# Default allowed actions (both retest and merge)
ALLOWED_ACTIONS="retest,merge"

# Default filters to empty (consider all PRs)
LABEL=""
TITLE_PREFIX=""

# Default skip patterns
SKIP_PATTERNS_ARG=""

# Default to compact output
VERBOSE=false

# Show help
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Process Konflux PRs by checking CI status and taking actions (retest/merge).

OPTIONS:
  --label LABEL            Filter PRs by label
  --title-prefix PREFIX    Filter PRs by title prefix
  --actions ACTIONS        Comma-separated list of allowed actions: retest,merge
                           (default: retest,merge)
  --skip-patterns PATTERNS Comma-separated list of CI check name patterns to ignore
                           when determining if PR is ready to merge
                           (default: none - all checks can block merge)
  --execute, --apply,      Execute actions (default is dry-run mode)
    --no-dry-run
  --dry-run                Explicitly enable dry-run mode (default)
  -v, --verbose            Show detailed output for each PR
  -h, --help               Show this help message

EXAMPLES:
  # Dry-run with default settings (all checks must pass)
  $0

  # Execute retests and merges for PRs with label "auto-merge"
  $0 --label auto-merge --execute

  # Skip "Run linters" and "Run tests" checks
  $0 --skip-patterns "Run linters,Run tests"

  # Verbose output to see details
  $0 --verbose

  # Filter by title prefix and execute
  $0 --title-prefix "Update" --execute
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        --label)
            LABEL="$2"
            shift 2
            ;;
        --title-prefix)
            TITLE_PREFIX="$2"
            shift 2
            ;;
        --actions)
            ALLOWED_ACTIONS="$2"
            shift 2
            ;;
        --skip-patterns)
            SKIP_PATTERNS_ARG="$2"
            shift 2
            ;;
        --execute|--apply|--no-dry-run)
            DRY_RUN=false
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        *)
            echo "Error: Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Parse skip patterns from comma-separated list
if [[ -n "$SKIP_PATTERNS_ARG" ]]; then
    # Split comma-separated list into array
    IFS=',' read -ra SKIP_PATTERNS <<< "$SKIP_PATTERNS_ARG"
else
    # No skip patterns - all checks can block merge
    SKIP_PATTERNS=()
fi

# Function to check if a check name should be skipped
should_skip_check() {
    local check_name="$1"
    for pattern in "${SKIP_PATTERNS[@]}"; do
        if [[ "$check_name" == *"$pattern"* ]]; then
            return 0  # true - should skip
        fi
    done
    return 1  # false - should not skip
}

# Function to check if an action is allowed
is_action_allowed() {
    local action="$1"
    if [[ ",$ALLOWED_ACTIONS," == *",$action,"* ]]; then
        return 0  # true - action is allowed
    fi
    return 1  # false - action is not allowed
}

# Get current time in seconds since epoch
current_time=$(date +%s)

# 4 hours in seconds
four_hours=14400

# Print mode
if [[ "$DRY_RUN" == true ]]; then
    echo "========================================="
    echo "DRY RUN MODE - No changes will be made"
    echo "Use --execute to actually perform actions"
    echo "========================================="
    echo ""
fi

# Get all PRs (filtered by label if specified)
if [[ -n "$LABEL" ]]; then
    pr_data=$(gh pr list --repo "$REPO" --label "$LABEL" --state open --json number,title,labels)
else
    pr_data=$(gh pr list --repo "$REPO" --state open --json number,title,labels)
fi

# Filter by title prefix if specified
if [[ -n "$TITLE_PREFIX" ]]; then
  filtered_data=$(echo "$pr_data" | jq -c ".[] | select(.title | startswith(\"$TITLE_PREFIX\"))")
else
  filtered_data=$(echo "$pr_data" | jq -c '.[]')
fi

# Arrays to store PR data for table output
declare -a pr_numbers
declare -a pr_titles
declare -a pr_labels
declare -a pr_statuses
declare -a pr_blocking
declare -a pr_actions
declare -a pr_details

# Process each PR
while IFS= read -r pr_json; do
    pr=$(echo "$pr_json" | jq -r '.number')
    title=$(echo "$pr_json" | jq -r '.title')
    labels=$(echo "$pr_json" | jq -r '.labels[].name' | tr '\n' ',' | sed 's/,$//')

    if [[ "$VERBOSE" == true ]]; then
        echo "========================================="
        echo "Processing PR #$pr: $title"
        echo "========================================="
    fi

    # Get checks for this PR
    checks=$(gh pr checks "$pr" --repo "$REPO" --json name,state,startedAt,completedAt)

    # Check if any jobs have been running for over 4 hours
    over_time=false
    overtime_checks=()
    while IFS= read -r check; do
        name=$(echo "$check" | jq -r '.name')
        state=$(echo "$check" | jq -r '.state')
        started=$(echo "$check" | jq -r '.startedAt')

        if [[ "$state" == "IN_PROGRESS" || "$state" == "QUEUED" || "$state" == "PENDING" ]]; then
            if [[ "$started" != "null" && "$started" != "0001-01-01T00:00:00Z" ]]; then
                start_time=$(date -d "$started" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started" +%s 2>/dev/null)
                if [[ -n "$start_time" ]]; then
                    elapsed=$((current_time - start_time))
                    if [[ $elapsed -gt $four_hours ]]; then
                        hours=$(($elapsed / 3600))
                        if [[ "$VERBOSE" == true ]]; then
                            echo "  Job '$name' has been running for $hours hours"
                        fi
                        over_time=true
                        overtime_checks+=("$name")
                    fi
                fi
            fi
        fi
    done < <(echo "$checks" | jq -c '.[]')

    # Check if any jobs failed (excluding skipped checks)
    # Only consider Red Hat Konflux checks ending with -on-pull-request
    failed=false
    failed_checks=()
    failed_pipelines=()
    while IFS= read -r check; do
        name=$(echo "$check" | jq -r '.name')
        state=$(echo "$check" | jq -r '.state')

        # Only process Red Hat Konflux checks ending with -on-pull-request
        if [[ "$name" == "Red Hat Konflux /"* && "$name" == *"-on-pull-request" ]]; then
            if [[ "$state" == "FAILURE" ]] && ! should_skip_check "$name"; then
                # Extract pipeline name (everything after "Red Hat Konflux / ")
                pipeline_name="${name#Red Hat Konflux / }"

                if [[ "$VERBOSE" == true ]]; then
                    echo "  Job '$name' has FAILED (pipeline: $pipeline_name)"
                fi
                failed=true
                failed_checks+=("$name")
                failed_pipelines+=("$pipeline_name")
            fi
        fi
    done < <(echo "$checks" | jq -c '.[]')

    # Check if all jobs are complete (except skipped checks) and count running
    all_complete=true
    running_checks=()
    while IFS= read -r check; do
        name=$(echo "$check" | jq -r '.name')
        state=$(echo "$check" | jq -r '.state')

        if ! should_skip_check "$name"; then
            if [[ "$state" != "SUCCESS" ]]; then
                all_complete=false
                if [[ "$state" == "IN_PROGRESS" || "$state" == "QUEUED" || "$state" == "PENDING" ]]; then
                    running_checks+=("$name")
                fi
            fi
        fi
    done < <(echo "$checks" | jq -c '.[]')

    # Determine status and blocking info
    status=""
    blocking=""
    failed_count=${#failed_checks[@]}
    overtime_count=${#overtime_checks[@]}
    running_count=${#running_checks[@]}

    if [[ "$over_time" == true || "$failed" == true ]]; then
        if [[ "$failed" == true ]]; then
            status="Failed"
            if [[ "$VERBOSE" == true ]]; then
                blocking="${failed_checks[*]}"
            else
                blocking="${failed_count} failed"
                [[ $overtime_count -gt 0 ]] && blocking="$blocking, ${overtime_count} overtime"
            fi
        else
            status="Overtime"
            if [[ "$VERBOSE" == true ]]; then
                blocking="${overtime_checks[*]}"
            else
                blocking="${overtime_count} overtime"
            fi
        fi
    elif [[ "$all_complete" == true ]]; then
        status="Ready"
        blocking="-"
    else
        status="Waiting"
        if [[ "$VERBOSE" == true ]]; then
            blocking="${running_checks[*]}"
        else
            blocking="${running_count} running"
        fi
    fi

    # Decide action
    action=""
    if [[ "$over_time" == true || "$failed" == true ]]; then
        if ! is_action_allowed "retest"; then
            action="Blocked"
            if [[ "$VERBOSE" == true ]]; then
                echo "  Action: Would retest, but blocked by --actions (allowed: $ALLOWED_ACTIONS)"
            fi
        elif [[ "$DRY_RUN" == true ]]; then
            action="Retest"
            if [[ "$VERBOSE" == true ]]; then
                if [[ ${#failed_pipelines[@]} -gt 0 ]]; then
                    echo "  Action: [DRY RUN] Would comment /retest for ${#failed_pipelines[@]} pipeline(s):"
                    for pipeline in "${failed_pipelines[@]}"; do
                        echo "    /retest $pipeline"
                    done
                else
                    echo "  Action: [DRY RUN] Would comment /retest"
                fi
            fi
        else
            action="Retest"
            if [[ ${#failed_pipelines[@]} -gt 0 ]]; then
                # Retest each failed pipeline individually
                for pipeline in "${failed_pipelines[@]}"; do
                    if [[ "$VERBOSE" == true ]]; then
                        echo "  Action: Commenting /retest $pipeline"
                    fi
                    gh pr comment "$pr" --repo "$REPO" --body "/retest $pipeline"
                done
            else
                # Fallback to general retest for overtime cases
                if [[ "$VERBOSE" == true ]]; then
                    echo "  Action: Commenting /retest"
                fi
                gh pr comment "$pr" --repo "$REPO" --body "/retest"
            fi
        fi
    elif [[ "$all_complete" == true ]]; then
        if ! is_action_allowed "merge"; then
            action="Blocked"
            if [[ "$VERBOSE" == true ]]; then
                echo "  Action: Would merge, but blocked by --actions (allowed: $ALLOWED_ACTIONS)"
            fi
        elif [[ "$DRY_RUN" == true ]]; then
            action="Merge"
            if [[ "$VERBOSE" == true ]]; then
                echo "  Action: [DRY RUN] Would merge PR"
            fi
        else
            action="Merge"
            if [[ "$VERBOSE" == true ]]; then
                echo "  Action: Merging PR"
            fi
            gh pr merge "$pr" --repo "$REPO" --squash --delete-branch
        fi
    else
        action="Wait"
        if [[ "$VERBOSE" == true ]]; then
            echo "  Action: Waiting (jobs still running)"
        fi
    fi

    # Store data for table
    pr_numbers+=("$pr")
    pr_titles+=("$title")
    pr_labels+=("$labels")
    pr_statuses+=("$status")
    pr_blocking+=("$blocking")
    pr_actions+=("$action")

    if [[ "$VERBOSE" == true ]]; then
        echo ""
    fi
done < <(echo "$filtered_data")

# Print table output (non-verbose mode)
if [[ "$VERBOSE" == false ]]; then
    # Print header
    printf "%-6s %-40s %-20s %-10s %-25s %-10s\n" "PR#" "TITLE" "LABELS" "STATUS" "BLOCKING CHECKS" "ACTION"
    printf "%-6s %-40s %-20s %-10s %-25s %-10s\n" "---" "-----" "------" "------" "---------------" "------"

    # Print rows
    for i in "${!pr_numbers[@]}"; do
        # Truncate title to 40 chars
        title_short="${pr_titles[$i]}"
        if [[ ${#title_short} -gt 40 ]]; then
            title_short="${title_short:0:37}..."
        fi

        # Truncate labels to 20 chars
        labels_short="${pr_labels[$i]}"
        if [[ ${#labels_short} -gt 20 ]]; then
            labels_short="${labels_short:0:17}..."
        fi
        [[ -z "$labels_short" ]] && labels_short="-"

        # Truncate blocking to 25 chars
        blocking_short="${pr_blocking[$i]}"
        if [[ ${#blocking_short} -gt 25 ]]; then
            blocking_short="${blocking_short:0:22}..."
        fi

        printf "%-6s %-40s %-20s %-10s %-25s %-10s\n" \
            "${pr_numbers[$i]}" \
            "$title_short" \
            "$labels_short" \
            "${pr_statuses[$i]}" \
            "$blocking_short" \
            "${pr_actions[$i]}"
    done
fi

echo ""
echo "Processed ${#pr_numbers[@]} PRs"
