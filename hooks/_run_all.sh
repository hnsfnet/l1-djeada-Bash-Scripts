#!/usr/bin/env bash

# Script Name: _run_all.sh
# Description: Batch runner for hook check scripts with filtering and summary.
#              Discovers hook scripts in the 'hooks' directory (files not starting
#              with '_') and executes each with '--check' against the given paths.
#              Supports include/exclude filters and produces a human-readable summary.
#
# Usage:
#   ./hooks/_run_all.sh [OPTIONS] [--] [PATH ...]
#
# Options:
#   -h, --help                Show this help message and exit.
#   -p, --paths PATH ...      One or more paths to check (can also be given as
#                             positional arguments after '--' or at the end).
#   -i, --include HOOK ...    Only run these hooks (names or basenames, comma or
#                             space separated). Example: --include last_line_empty,remove_carriage_return
#   -e, --exclude HOOK ...    Skip these hooks (names or basenames, comma or
#                             space separated). Example: --exclude beautify_script
#
# If no paths are given, defaults to 'src'.
#
# Exit codes:
#   0  All checks passed.
#   1  One or more checks failed.
#   2  Usage error (bad arguments).

set -euo pipefail

# Ensure tput has something to work with
export TERM=${TERM:-dumb}

# ---------------------------------------------------------------------------
# Color helpers (safe because TERM is always set above)
# ---------------------------------------------------------------------------
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
BOLD=$(tput bold)
RESET=$(tput sgr0)

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
DEFAULT_PATHS=(src)
HOOKS_DIR="hooks"

declare -a paths=()
declare -a include_list=()
declare -a exclude_list=()

# ---------------------------------------------------------------------------
# usage
# ---------------------------------------------------------------------------
usage() {
    sed -n '3,/^$/{ s/^# \{0,1\}//; p }' "$0"
    exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# parse_args: Populate paths, include_list, exclude_list from CLI arguments.
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage 0
                ;;
            -p|--paths)
                shift
                while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
                    paths+=("$1")
                    shift
                done
                ;;
            -i|--include)
                shift
                if [[ $# -eq 0 ]]; then
                    echo "Error: --include requires at least one argument" >&2
                    usage 2
                fi
                # Accept comma-separated or space-separated values
                IFS=', ' read -ra tokens <<< "$1"
                for t in "${tokens[@]}"; do
                    [[ -n "$t" ]] && include_list+=("$t")
                done
                shift
                ;;
            -e|--exclude)
                shift
                if [[ $# -eq 0 ]]; then
                    echo "Error: --exclude requires at least one argument" >&2
                    usage 2
                fi
                IFS=', ' read -ra tokens <<< "$1"
                for t in "${tokens[@]}"; do
                    [[ -n "$t" ]] && exclude_list+=("$t")
                done
                shift
                ;;
            --)
                shift
                # Everything after -- is a path
                while [[ $# -gt 0 ]]; do
                    paths+=("$1")
                    shift
                done
                ;;
            -*)
                echo "Error: unknown option '$1'" >&2
                usage 2
                ;;
            *)
                # Positional argument treated as a path
                paths+=("$1")
                shift
                ;;
        esac
    done

    # Fall back to default paths when none specified
    if [[ ${#paths[@]} -eq 0 ]]; then
        paths=("${DEFAULT_PATHS[@]}")
    fi
}

# ---------------------------------------------------------------------------
# hook_name: Extract a canonical hook name from a file path.
#   hooks/remove_carriage_return.sh -> remove_carriage_return
# ---------------------------------------------------------------------------
hook_name() {
    local base
    base="$(basename "$1")"
    echo "${base%.sh}"
}

# ---------------------------------------------------------------------------
# is_included: Return 0 if a hook should be run given include/exclude lists.
# ---------------------------------------------------------------------------
is_included() {
    local name="$1"

    # If include list is non-empty, hook must appear in it
    if [[ ${#include_list[@]} -gt 0 ]]; then
        local found=0
        for inc in "${include_list[@]}"; do
            if [[ "$name" == "$inc" || "$name" == "${inc%.sh}" ]]; then
                found=1
                break
            fi
        done
        [[ $found -eq 1 ]] || return 1
    fi

    # If exclude list is non-empty, hook must NOT appear in it
    if [[ ${#exclude_list[@]} -gt 0 ]]; then
        for exc in "${exclude_list[@]}"; do
            if [[ "$name" == "$exc" || "$name" == "${exc%.sh}" ]]; then
                return 1
            fi
        done
    fi

    return 0
}

# ---------------------------------------------------------------------------
# discover_hooks: Print the list of hook script paths to run, one per line.
# ---------------------------------------------------------------------------
discover_hooks() {
    # Find all executable .sh files (and symlinks) in HOOKS_DIR whose basename
    # does not start with '_'.  Sort for deterministic order.
    find "$HOOKS_DIR" -maxdepth 1 \( -type f -o -type l \) -name "[^_]*.sh" -executable 2>/dev/null | sort
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    # Discover available hooks
    local -a all_hooks=()
    while IFS= read -r hook; do
        [[ -n "$hook" ]] && all_hooks+=("$hook")
    done < <(discover_hooks)

    if [[ ${#all_hooks[@]} -eq 0 ]]; then
        echo "No hook scripts found in '${HOOKS_DIR}/'." >&2
        exit 2
    fi

    # Filter hooks
    local -a hooks_to_run=()
    local -a skipped_hooks=()
    for hook in "${all_hooks[@]}"; do
        local name
        name="$(hook_name "$hook")"
        if is_included "$name"; then
            hooks_to_run+=("$hook")
        else
            skipped_hooks+=("$name")
        fi
    done

    if [[ ${#hooks_to_run[@]} -eq 0 ]]; then
        echo "No hooks to run after applying include/exclude filters." >&2
        exit 0
    fi

    # Print run configuration
    echo "${BOLD}=== Batch Hook Runner ===${RESET}"
    echo "Paths:    ${paths[*]}"
    echo "Hooks:    ${#hooks_to_run[@]} selected (${#skipped_hooks[@]} skipped)"
    if [[ ${#skipped_hooks[@]} -gt 0 ]]; then
        echo "Skipped:  ${skipped_hooks[*]}"
    fi
    echo ""

    # Tracking arrays for the summary
    local -a passed_entries=()
    local -a failed_entries=()
    local overall_status=0
    local total_checks=0

    # Run each hook against each path
    for hook in "${hooks_to_run[@]}"; do
        local name
        name="$(hook_name "$hook")"

        for path in "${paths[@]}"; do
            total_checks=$((total_checks + 1))
            local label="${name} @ ${path}"

            echo "${BOLD}▶ Running ${label}${RESET}"

            if "$hook" --check "$path" 2>&1; then
                echo "${GREEN}  ✓ ${label} passed${RESET}"
                passed_entries+=("$label")
            else
                echo "${RED}  ✗ ${label} FAILED${RESET}"
                failed_entries+=("$label")
                overall_status=1
            fi
            echo ""
        done
    done

    # -----------------------------------------------------------------------
    # Summary
    # -----------------------------------------------------------------------
    echo "${BOLD}=== Summary ===${RESET}"
    echo "Total checks: ${total_checks}"
    echo "${GREEN}Passed:       ${#passed_entries[@]}${RESET}"

    if [[ ${#failed_entries[@]} -gt 0 ]]; then
        echo "${RED}Failed:       ${#failed_entries[@]}${RESET}"
        echo ""
        echo "${RED}Failed checks:${RESET}"
        for entry in "${failed_entries[@]}"; do
            echo "  ${RED}✗${RESET} ${entry}"
        done
    else
        echo "Failed:       0"
    fi

    if [[ ${#skipped_hooks[@]} -gt 0 ]]; then
        echo "${YELLOW}Skipped hooks: ${skipped_hooks[*]}${RESET}"
    fi

    echo ""
    if [[ $overall_status -eq 0 ]]; then
        echo "${GREEN}${BOLD}All checks passed.${RESET}"
    else
        echo "${RED}${BOLD}Some checks failed.${RESET}"
    fi

    exit $overall_status
}

main "$@"
