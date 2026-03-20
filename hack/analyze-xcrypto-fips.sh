#!/usr/bin/env bash
# Inventory golang.org/x/crypto reachability from git submodule roots (OCPSTRAT-1882 helper).
# See internal doc: "OpenShift, x/crypto, FIPS 140" (+ check-payload PR216 / callgraph examples).
#
# Scans every path listed in .gitmodules that has a go.mod at the submodule root.
# Main packages: all mains under ./cmd/... (if present) plus the module root if main.go exists.
#
# Optional: ANALYZE_XCRYPTO_INCLUDE_SLOW=1 runs full ./... main discovery when the fast path
# finds no mains (can be very slow for large trees like prometheus).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
unset GOFLAGS

list_submodule_paths() {
  local f="${ROOT}/.gitmodules"
  [[ -f "$f" ]] || {
    echo "warning: no .gitmodules at ${ROOT}" >&2
    return 0
  }
  awk '
    /^[[:space:]]*path[[:space:]]*=[[:space:]]*/ {
      sub(/^[[:space:]]*path[[:space:]]*=[[:space:]]*/, "")
      gsub(/\r$/, "")
      print
    }
  ' "$f"
}

# Print unique main import paths for module at $1 (absolute path to module root).
discover_main_import_paths() {
  local modroot="$1"
  local -a acc=()
  local line

  # Use Name=="main" — modern "go list -f" no longer exposes .Main (see go list template errors).
  local list_fmt='{{if eq .Name "main"}}{{.ImportPath}}{{end}}'

  if [[ -d "${modroot}/cmd" ]]; then
    while IFS= read -r line; do
      [[ -n "${line}" ]] && acc+=("${line}")
    done < <(
      (cd "${modroot}" && go list -e -f "${list_fmt}" ./cmd/... 2>/dev/null) || true
    )
  fi
  if [[ -f "${modroot}/main.go" ]]; then
    line=$(cd "${modroot}" && go list -e -f "${list_fmt}" . 2>/dev/null || true)
    [[ -n "${line}" ]] && acc+=("${line}")
  fi

  if [[ ${#acc[@]} -eq 0 && "${ANALYZE_XCRYPTO_INCLUDE_SLOW:-}" == 1 ]]; then
    while IFS= read -r line; do
      [[ -n "${line}" ]] && acc+=("${line}")
    done < <(
      (cd "${modroot}" && go list -e -f "${list_fmt}" ./... 2>/dev/null) || true
    )
  fi

  printf '%s\n' "${acc[@]}" | grep -v '^$' | sort -u
}

run_why() {
  local modroot="$1"
  local pkg="$2"
  local label="$3"
  echo ""
  echo "======== ${label} ========"
  (cd "${modroot}" && go mod why -m golang.org/x/crypto "${pkg}" 2>/dev/null || true)
}

echo "# Submodule roots from .gitmodules with go.mod (unset GOFLAGS for broken empty-token envs)"
echo "# go mod why -m golang.org/x/crypto  (one chain per main; there may be several importers)"

mapfile -t SUBS < <(list_submodule_paths)
ALL_CRYPTO_LINES=()

for rel in "${SUBS[@]}"; do
  mod="${ROOT}/${rel}"
  if [[ ! -d "${mod}" ]]; then
    echo ""
    echo "======== SKIP ${rel} (path missing — git submodule init/update?) ========"
    continue
  fi
  if [[ ! -f "${mod}/go.mod" ]]; then
    echo ""
    echo "======== SKIP ${rel} (no go.mod at submodule root) ========"
    continue
  fi

  mapfile -t MAINS < <(discover_main_import_paths "${mod}")
  if [[ ${#MAINS[@]} -eq 0 ]]; then
    echo ""
    echo "======== SKIP ${rel} (no main packages via ./cmd/... or root main.go; set ANALYZE_XCRYPTO_INCLUDE_SLOW=1 to try ./...) ========"
    continue
  fi

  echo ""
  echo "######################################################################"
  echo "# MODULE ${rel} (${#MAINS[@]} main(s))"
  echo "######################################################################"

  for main_pkg in "${MAINS[@]}"; do
    run_why "${mod}" "${main_pkg}" "${rel} ${main_pkg}"
  done

  echo ""
  echo "======== golang.org/x/crypto/* in dep closure (${rel}) ========"
  for main_pkg in "${MAINS[@]}"; do
    echo ""
    echo "--- ${main_pkg} ---"
    mapfile -t crypto_pkg < <(
      (cd "${mod}" && go list -deps "${main_pkg}" 2>/dev/null | grep '^golang.org/x/crypto' | sort -u || true)
    )
    if [[ ${#crypto_pkg[@]} -gt 0 ]]; then
      printf '%s\n' "${crypto_pkg[@]}"
      ALL_CRYPTO_LINES+=("${crypto_pkg[@]}")
    fi
  done
done

echo ""
echo "======== Unique golang.org/x/crypto/* across all scanned mains ========"
if [[ ${#ALL_CRYPTO_LINES[@]} -eq 0 ]]; then
  echo "(none found, or no modules scanned)"
else
  printf '%s\n' "${ALL_CRYPTO_LINES[@]}" | sort -u
fi

echo ""
echo "Optional (install tools once):"
echo "  go install golang.org/x/tools/cmd/callgraph@latest"
echo "  go install golang.org/x/tools/cmd/digraph@latest"
echo "Example:"
echo "  (cd prometheus && callgraph -format=digraph ./cmd/prometheus | digraph nodes | grep '^golang.org/x/crypto')"
