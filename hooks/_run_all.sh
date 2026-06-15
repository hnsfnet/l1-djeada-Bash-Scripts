#!/usr/bin/env bash

# Script Name: _run_all.sh
# Description: Batch entrypoint for the repository's code-quality hooks.
#              It discovers every hook in this directory (the *.sh entries that
#              do NOT start with '_'), runs each one in --check mode against one
#              or more paths, and prints a clear summary at the end.
#
#              Hooks may be checked out either as symlinks into ../src or as
#              plain files containing the link target; in both cases the real
#              script under ../src is resolved and executed, so the runner works
#              the same locally and in CI.
#
# Usage: ./hooks/_run_all.sh [OPTIONS] [PATH...]
#
# Options:
#   -i, --include LIST   Only run these hooks. Comma-separated and/or repeatable.
#                        Names may be given with or without the .sh suffix.
#   -e, --exclude LIST   Skip these hooks. Comma-separated and/or repeatable.
#   -l, --list           List the available hooks and exit.
#   -h, --help           Show this help text and exit.
#
# Positional arguments:
#   PATH...   One or more files or directories to check. Defaults to the
#             repository's 'src' directory when none are given.
#
# Exit codes:
#   0  All selected checks passed on all paths.
#   1  At least one check failed.
#   2  Usage error (unknown option, no hooks matched the filters, invalid path).

set -uo pipefail

# Ensure tput has something to work with (avoids errors on dumb terminals).
export TERM=${TERM:-dumb}

# --- Locate ourselves so the runner works from any working directory --------
HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HOOKS_DIR}/.." && pwd)"
SRC_DIR="${REPO_ROOT}/src"

# --- Colors: enabled only on a TTY and when NO_COLOR is unset ---------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED="$(tput setaf 1 2>/dev/null || true)"
    GREEN="$(tput setaf 2 2>/dev/null || true)"
    YELLOW="$(tput setaf 3 2>/dev/null || true)"
    CYAN="$(tput setaf 6 2>/dev/null || true)"
    BOLD="$(tput bold 2>/dev/null || true)"
    RESET="$(tput sgr0 2>/dev/null || true)"
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; BOLD=""; RESET=""
fi

err() { echo "${RED}[ERROR]${RESET} $*" >&2; }
warn() { echo "${YELLOW}[WARN]${RESET} $*" >&2; }

print_help() {
    # Strip the leading "# " from the header comment block for a live help text.
    sed -n '3,30p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//'
}

# --- Discover available hooks (names without the .sh suffix) ----------------
# Match both real symlinks and plain files so it works regardless of how the
# repository was checked out.
discover_hooks() {
    find "${HOOKS_DIR}" -maxdepth 1 \( -type f -o -type l \) \
        -name '*.sh' ! -name '_*' -printf '%f\n' 2>/dev/null \
        | sed 's/\.sh$//' | sort
}

# Resolve a hook name to the executable script that should actually run.
#   1. A real symlink -> follow it to its canonical target.
#   2. Otherwise prefer src/<name>.sh (covers link-as-plain-file checkouts).
#   3. Fall back to the hooks/<name>.sh entry itself.
resolve_runnable() {
    local name="$1"
    local entry="${HOOKS_DIR}/${name}.sh"
    if [[ -L "${entry}" ]]; then
        readlink -f "${entry}"
    elif [[ -f "${SRC_DIR}/${name}.sh" ]]; then
        echo "${SRC_DIR}/${name}.sh"
    else
        echo "${entry}"
    fi
}

# Test array membership: contains <needle> <haystack...>
contains() {
    local needle="$1"; shift
    local item
    for item in "$@"; do
        [[ "${item}" == "${needle}" ]] && return 0
    done
    return 1
}

# Normalize a hook name by stripping a trailing .sh, if present.
normalize_name() { echo "${1%.sh}"; }

# Split a comma-separated list and append each non-empty token to a named array.
append_csv() {
    local -n _target="$1"
    local raw="$2" token
    local IFS=','
    for token in ${raw}; do
        token="${token// /}"
        [[ -n "${token}" ]] && _target+=("$(normalize_name "${token}")")
    done
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
declare -a INCLUDE=()
declare -a EXCLUDE=()
declare -a PATHS=()
DO_LIST=0

mapfile -t ALL_HOOKS < <(discover_hooks)

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--include)
            [[ $# -ge 2 ]] || { err "Option '$1' requires an argument."; exit 2; }
            append_csv INCLUDE "$2"; shift 2 ;;
        --include=*)
            append_csv INCLUDE "${1#*=}"; shift ;;
        -e|--exclude)
            [[ $# -ge 2 ]] || { err "Option '$1' requires an argument."; exit 2; }
            append_csv EXCLUDE "$2"; shift 2 ;;
        --exclude=*)
            append_csv EXCLUDE "${1#*=}"; shift ;;
        -l|--list) DO_LIST=1; shift ;;
        -h|--help) print_help; exit 0 ;;
        --) shift; while [[ $# -gt 0 ]]; do PATHS+=("$1"); shift; done ;;
        -*) err "Unknown option: $1"; echo "Try '$(basename "$0") --help'." >&2; exit 2 ;;
        *) PATHS+=("$1"); shift ;;
    esac
done

if [[ ${#ALL_HOOKS[@]} -eq 0 ]]; then
    err "No hooks found in ${HOOKS_DIR}."
    exit 2
fi

if [[ ${DO_LIST} -eq 1 ]]; then
    echo "${BOLD}Available hooks:${RESET}"
    for h in "${ALL_HOOKS[@]}"; do
        echo "  ${h}  ->  $(resolve_runnable "${h}")"
    done
    exit 0
fi

# ---------------------------------------------------------------------------
# Resolve the set of hooks to run from include / exclude filters
# ---------------------------------------------------------------------------
# Warn about names that don't correspond to a real hook (likely typos).
for name in "${INCLUDE[@]}" "${EXCLUDE[@]}"; do
    contains "${name}" "${ALL_HOOKS[@]}" || warn "No hook named '${name}'; ignoring."
done

declare -a SELECTED=()
for h in "${ALL_HOOKS[@]}"; do
    # If --include was given, keep only those listed.
    if [[ ${#INCLUDE[@]} -gt 0 ]] && ! contains "${h}" "${INCLUDE[@]}"; then
        continue
    fi
    # Drop anything explicitly excluded.
    if [[ ${#EXCLUDE[@]} -gt 0 ]] && contains "${h}" "${EXCLUDE[@]}"; then
        continue
    fi
    SELECTED+=("${h}")
done

if [[ ${#SELECTED[@]} -eq 0 ]]; then
    err "No hooks left to run after applying include/exclude filters."
    exit 2
fi

# ---------------------------------------------------------------------------
# Resolve paths (default to the repo's src directory) and validate them
# ---------------------------------------------------------------------------
if [[ ${#PATHS[@]} -eq 0 ]]; then
    PATHS=("${SRC_DIR}")
fi

declare -a INVALID=()
for p in "${PATHS[@]}"; do
    [[ -e "${p}" ]] || INVALID+=("${p}")
done
if [[ ${#INVALID[@]} -gt 0 ]]; then
    err "The following path(s) do not exist: ${INVALID[*]}"
    exit 2
fi

# ---------------------------------------------------------------------------
# Run the selected hooks against every path
# ---------------------------------------------------------------------------
echo "${BOLD}Running ${#SELECTED[@]} hook(s) in check mode${RESET}"
echo "  Hooks: ${SELECTED[*]}"
echo "  Paths: ${PATHS[*]}"

declare -A HOOK_STATUS=()   # hook name -> 0 (pass) / 1 (fail)
declare -a FAILURES=()      # "hook<TAB>path" entries that failed

overall=0
for h in "${SELECTED[@]}"; do
    runnable="$(resolve_runnable "${h}")"
    HOOK_STATUS["${h}"]=0
    for p in "${PATHS[@]}"; do
        echo
        echo "${CYAN}==> ${h} --check ${p}${RESET}"
        if bash "${runnable}" --check "${p}"; then
            echo "${GREEN}[PASS]${RESET} ${h} on ${p}"
        else
            echo "${RED}[FAIL]${RESET} ${h} on ${p}"
            HOOK_STATUS["${h}"]=1
            FAILURES+=("${h}"$'\t'"${p}")
            overall=1
        fi
    done
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "${BOLD}==================== SUMMARY ====================${RESET}"
echo "Mode:  check"
echo "Paths: ${PATHS[*]}"
echo
echo "${BOLD}Hook results:${RESET}"
for h in "${SELECTED[@]}"; do
    if [[ "${HOOK_STATUS[${h}]}" -eq 0 ]]; then
        echo "  ${GREEN}PASS${RESET}  ${h}"
    else
        echo "  ${RED}FAIL${RESET}  ${h}"
    fi
done

if [[ ${#FAILURES[@]} -gt 0 ]]; then
    echo
    echo "${BOLD}Failed checks (hook -> path):${RESET}"
    for entry in "${FAILURES[@]}"; do
        hook="${entry%%$'\t'*}"
        path="${entry#*$'\t'}"
        echo "  ${RED}x${RESET} ${hook} -> ${path}"
    done
fi

echo
if [[ ${overall} -eq 0 ]]; then
    echo "Overall: ${GREEN}${BOLD}PASSED${RESET} (${#SELECTED[@]} hook(s), ${#PATHS[@]} path(s))"
else
    echo "Overall: ${RED}${BOLD}FAILED${RESET} (${#FAILURES[@]} failing check(s))"
fi

exit "${overall}"
