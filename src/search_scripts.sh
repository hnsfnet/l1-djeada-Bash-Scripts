#!/usr/bin/env bash

# Script Name: search_scripts.sh
# Description: Search and browse scripts in this repository by keyword.
#              Scans all .sh files under src/, extracts their header metadata
#              (name, description, usage), and ranks results by relevance.
# Usage: ./search_scripts.sh <keyword> [keyword2 ...]
#        ./search_scripts.sh --list
#        ./search_scripts.sh --help
# Options:
#   --list, -l     List all available scripts (no search).
#   --help, -h     Show this help message.
# Example: ./search_scripts.sh backup
#          ./search_scripts.sh weather
#          ./search_scripts.sh line counter
#          ./search_scripts.sh --list

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Colors (disable when stdout is not a terminal)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  BOLD='\033[1m'
  DIM='\033[2m'
  GREEN='\033[32m'
  CYAN='\033[36m'
  YELLOW='\033[33m'
  RESET='\033[0m'
else
  BOLD='' DIM='' GREEN='' CYAN='' YELLOW='' RESET=''
fi

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------
show_help() {
  cat <<'EOF'
search_scripts.sh — Find scripts in this repository by keyword.

USAGE
    ./search_scripts.sh <keyword> [keyword2 ...]
    ./search_scripts.sh --list
    ./search_scripts.sh --help

OPTIONS
    --list, -l    Show a compact list of every script in src/.
    --help, -h    Show this help message.

EXAMPLES
    ./search_scripts.sh backup
    ./search_scripts.sh weather
    ./search_scripts.sh line counter
    ./search_scripts.sh git commit
    ./search_scripts.sh --list
EOF
}

# ---------------------------------------------------------------------------
# Parse one script file and emit a structured record
#   Outputs: name|description|usage|options|example|filepath
# ---------------------------------------------------------------------------
parse_script() {
  local file="$1"
  local name="" desc="" usage="" options="" example=""
  local in_desc=0 in_usage=0 in_options=0 in_example=0

  while IFS= read -r line; do
    # Strip leading '# ' or '#'
    local content
    content="${line#\# }"
    content="${content#\#}"

    # Detect field headers — handle both "Field: value" and "Field:" (value on next line)
    if [[ "$content" == Script\ Name:* ]]; then
      name="${content#Script Name:}"
      name="${name# }"
      in_desc=0; in_usage=0; in_options=0; in_example=0
    elif [[ "$content" == Description:* ]]; then
      desc="${content#Description:}"
      desc="${desc# }"
      in_desc=1; in_usage=0; in_options=0; in_example=0
    elif [[ "$content" == Usage:* ]]; then
      usage="${content#Usage:}"
      usage="${usage# }"
      in_desc=0; in_usage=1; in_options=0; in_example=0
    elif [[ "$content" == Options:* ]]; then
      options="${content#Options:}"
      options="${options# }"
      in_desc=0; in_usage=0; in_options=1; in_example=0
    elif [[ "$content" == Example:* ]]; then
      example="${content#Example:}"
      example="${example# }"
      in_desc=0; in_usage=0; in_options=0; in_example=1
    elif [[ "$line" =~ ^[^#] ]]; then
      # First non-comment line — stop parsing header
      break
    else
      # Continuation line (indented under a field)
      local trimmed
      trimmed="$(echo "$content" | sed 's/^[[:space:]]*//')"
      if [ -z "$trimmed" ]; then
        continue
      fi
      if (( in_desc )); then
        desc="$desc $trimmed"
      elif (( in_usage )); then
        [ -n "$usage" ] && usage="$usage | $trimmed" || usage="$trimmed"
      elif (( in_options )); then
        [ -n "$options" ] && options="$options | $trimmed" || options="$trimmed"
      elif (( in_example )); then
        [ -n "$example" ] && example="$example | $trimmed" || example="$trimmed"
      fi
    fi
  done < "$file"

  # Fallback: if no Script Name header, derive from filename
  if [ -z "$name" ]; then
    name="$(basename "$file")"
  fi

  printf '%s\n' "${name}|${desc}|${usage}|${options}|${example}|${file}"
}

# ---------------------------------------------------------------------------
# Collect all script records
# ---------------------------------------------------------------------------
collect_records() {
  local records=()
  for f in "$SCRIPT_DIR"/*.sh; do
    [ -f "$f" ] || continue
    # Skip self
    if [ "$(basename "$f")" = "search_scripts.sh" ]; then
      continue
    fi
    records+=("$(parse_script "$f")")
  done
  printf '%s\n' "${records[@]}"
}

# ---------------------------------------------------------------------------
# List mode
# ---------------------------------------------------------------------------
list_all() {
  local count=0
  printf "${BOLD}%-35s %s${RESET}\n" "SCRIPT" "DESCRIPTION"
  printf '%s\n' "$(printf '%.0s-' {1..80})"
  while IFS='|' read -r name desc _usage _opts _ex _path; do
    # Truncate description for list view
    local short_desc
    if [ ${#desc} -gt 50 ]; then
      short_desc="${desc:0:47}..."
    else
      short_desc="$desc"
    fi
    printf "${GREEN}%-35s${RESET} %s\n" "$name" "$short_desc"
    (( count++ )) || true
  done < <(collect_records | sort)
  printf '\n%s%d scripts found.%s\n' "$DIM" "$count" "$RESET"
}

# ---------------------------------------------------------------------------
# Score a record against keywords
#   Returns a numeric score (higher = better match)
# ---------------------------------------------------------------------------
score_record() {
  local name="$1" desc="$2" usage="$3"
  shift 3
  local keywords=("$@")
  local score=0
  local name_lower desc_lower usage_lower
  name_lower="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
  desc_lower="$(echo "$desc" | tr '[:upper:]' '[:lower:]')"
  usage_lower="$(echo "$usage" | tr '[:upper:]' '[:lower:]')"

  for kw in "${keywords[@]}"; do
    local kw_lower
    kw_lower="$(echo "$kw" | tr '[:upper:]' '[:lower:]')"
    # Exact name match (highest)
    if [[ "$name_lower" == "$kw_lower" || "$name_lower" == *"$kw_lower"* ]]; then
      (( score += 10 )) || true
    fi
    # Description contains keyword
    if [[ "$desc_lower" == *"$kw_lower"* ]]; then
      (( score += 5 )) || true
    fi
    # Usage contains keyword
    if [[ "$usage_lower" == *"$kw_lower"* ]]; then
      (( score += 2 )) || true
    fi
  done
  echo "$score"
}

# ---------------------------------------------------------------------------
# Print a single result card
# ---------------------------------------------------------------------------
print_card() {
  local name="$1" desc="$2" usage="$3" opts="$4" example="$5" filepath="$6"
  local detail="$7"  # 1 = full detail, 0 = compact

  printf "${BOLD}${GREEN}%s${RESET}\n" "$name"
  printf "  ${CYAN}Description:${RESET} %s\n" "$desc"

  if [ "$detail" = "1" ]; then
    # Full usage (split on | separator)
    if [ -n "$usage" ]; then
      printf "  ${CYAN}Usage:${RESET}\n"
      IFS='|' read -ra usage_parts <<< "$usage"
      for part in "${usage_parts[@]}"; do
        local trimmed
        trimmed="$(echo "$part" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -n "$trimmed" ] && printf "    %s\n" "$trimmed"
      done
    fi
    # Options
    if [ -n "$opts" ]; then
      printf "  ${CYAN}Options:${RESET}\n"
      IFS='|' read -ra opts_parts <<< "$opts"
      for part in "${opts_parts[@]}"; do
        local trimmed
        trimmed="$(echo "$part" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -n "$trimmed" ] && printf "    %s\n" "$trimmed"
      done
    fi
    # Example
    if [ -n "$example" ]; then
      printf "  ${CYAN}Example:${RESET} %s\n" "$example"
    fi
  else
    # Compact: just first usage line
    local first_usage
    first_usage="$(echo "$usage" | cut -d'|' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$first_usage" ] && printf "  ${CYAN}Usage:${RESET} %s\n" "$first_usage"
  fi

  local relpath
  relpath="${filepath#"$SCRIPT_DIR"/../}"
  printf "  ${DIM}Path: %s${RESET}\n" "src/$name"
  printf '\n'
}

# ---------------------------------------------------------------------------
# Search
# ---------------------------------------------------------------------------
search() {
  local keywords=("$@")
  local scored=()

  while IFS='|' read -r name desc usage opts example filepath; do
    local s
    s="$(score_record "$name" "$desc" "$usage" "${keywords[@]}")"
    if (( s > 0 )); then
      scored+=("${s}|${name}|${desc}|${usage}|${opts}|${example}|${filepath}")
    fi
  done < <(collect_records)

  if [ ${#scored[@]} -eq 0 ]; then
    printf "${YELLOW}No scripts matched the keyword(s): %s${RESET}\n" "${keywords[*]}"
    printf 'Try a different term, or run %s--list%s to see all available scripts.\n' "$BOLD" "$RESET"
    return 1
  fi

  # Sort by score descending
  IFS=$'\n' sorted=($(printf '%s\n' "${scored[@]}" | sort -t'|' -k1 -rn))
  unset IFS

  local total=${#sorted[@]}

  if (( total == 1 )); then
    # Single exact result — show full detail
    IFS='|' read -r _score name desc usage opts example filepath <<< "${sorted[0]}"
    printf 'Found 1 matching script:\n\n'
    print_card "$name" "$desc" "$usage" "$opts" "$example" "$filepath" 1
  else
    # Multiple results — compact cards, best match first
    printf 'Found %d matching scripts (best match first):\n\n' "$total"
    local rank=0
    for entry in "${sorted[@]}"; do
      IFS='|' read -r score name desc usage opts example filepath <<< "$entry"
      (( rank++ )) || true
      printf "${BOLD}#%d${RESET} (score: %d)\n" "$rank" "$score"
      print_card "$name" "$desc" "$usage" "$opts" "$example" "$filepath" 0
    done
    printf '%sTip: search with a more specific keyword to narrow results.%s\n' "$DIM" "$RESET"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  if [ $# -eq 0 ]; then
    show_help
    exit 0
  fi

  case "${1:-}" in
    --help|-h)
      show_help
      exit 0
      ;;
    --list|-l)
      list_all
      exit 0
      ;;
  esac

  search "$@"
}

main "$@"
