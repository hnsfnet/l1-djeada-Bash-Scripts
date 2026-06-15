#!/usr/bin/env bash

# Script Name: find_script.sh
# Description: Searches the scripts in this repository by name or by keywords in
#              their description, ranks the matches by relevance, and prints a
#              short summary (name, description, usage) for each result.
# Usage: find_script.sh [OPTIONS] KEYWORD [KEYWORD...]
#        KEYWORD            one or more terms to look for in script names/descriptions
#        --dir <dir>        directory of scripts to search (default: this script's folder)
#        --all              show every match, even when a keyword is very broad
#        --help, -h         display this help message
# Example: ./find_script.sh backup
#          ./find_script.sh weather
#          ./find_script.sh --all line

set -euo pipefail
shopt -s nullglob

# Resolve the directory this script lives in so the default search target is
# always the repository's own collection of scripts. New scripts dropped into
# this folder are picked up automatically with no manual list to maintain.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEARCH_DIR="$SCRIPT_DIR"

# How many results to print before suggesting a narrower keyword.
BROAD_THRESHOLD=12

# --- Colors (only when writing to a real terminal) -------------------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    BOLD="$(tput bold)"
    DIM="$(tput dim)"
    CYAN="$(tput setaf 6)"
    YELLOW="$(tput setaf 3)"
    RESET="$(tput sgr0)"
else
    BOLD=""
    DIM=""
    CYAN=""
    YELLOW=""
    RESET=""
fi

usage() {
    cat <<EOF
Usage: find_script.sh [OPTIONS] KEYWORD [KEYWORD...]

Search this repository's scripts by name or by keywords in their description.

Options:
  --dir <dir>   Directory of scripts to search (default: the folder this
                script lives in, i.e. the repository's own scripts).
  --all         Show every match, even when a keyword matches many scripts.
  --help, -h    Show this help message.

Examples:
  ./find_script.sh backup
  ./find_script.sh weather
  ./find_script.sh --all line
EOF
}

# Lowercase helper (portable, no external tools).
to_lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Trim leading and trailing whitespace from a string.
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Truncate a string to a maximum length, appending an ellipsis when cut.
truncate_str() {
    local s="$1" max="$2"
    if [ "${#s}" -gt "$max" ]; then
        printf '%s...' "${s:0:max}"
    else
        printf '%s' "$s"
    fi
}

# Parse the leading comment header of a script. Populates the globals:
#   H_NAME, H_DESC, H_USAGE (newline separated), H_EXAMPLE
# Only the first contiguous block of comment lines after the shebang is read,
# so body comments are never mistaken for metadata. Scripts without a header
# simply leave the fields empty and fall back to their filename later.
parse_header() {
    local file="$1"
    H_NAME=""
    H_DESC=""
    H_USAGE=""
    H_EXAMPLE=""

    local started=0 in_header=0 current=""
    local line content trimmed value field

    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$in_header" -eq 0 ]; then
            if [ "$started" -eq 0 ]; then
                case "$line" in
                    '#!'*) continue ;;                      # skip shebang
                esac
                # skip leading blank lines
                [ -z "$(trim "$line")" ] && continue
            fi
            case "$line" in
                '#'*) in_header=1; started=1 ;;             # header block begins
                *) break ;;                                 # hit code before any comment
            esac
        fi

        # We are inside the header block. A blank line (no leading '#') or any
        # non-comment line ends the contiguous header region. Empty comment
        # lines ("#") are kept as separators: some headers use them between
        # the Description, Usage, and Options sections.
        case "$line" in
            '#'*) : ;;
            *) break ;;
        esac

        content="${line#\#}"
        trimmed="$(trim "$content")"

        # Skip empty comment separator lines without ending the header or
        # appending blank text to the current field.
        [ -z "$trimmed" ] && continue

        if [[ "$trimmed" =~ ^([A-Za-z][A-Za-z\ ]*):(.*)$ ]]; then
            field="$(trim "${BASH_REMATCH[1]}")"
            value="$(trim "${BASH_REMATCH[2]}")"
            case "$field" in
                "Script Name") current="name"; H_NAME="$value" ;;
                "Description") current="desc"; H_DESC="$value" ;;
                "Usage")       current="usage"; H_USAGE="$value" ;;
                "Example")     current="example"; H_EXAMPLE="$value" ;;
                *)             current="ignore" ;;          # known-but-unused field
            esac
        else
            # Continuation line: append to whatever field we are collecting.
            case "$current" in
                desc)
                    [ -n "$H_DESC" ] && H_DESC="$H_DESC $trimmed" || H_DESC="$trimmed"
                    ;;
                usage)
                    if [ -n "$H_USAGE" ]; then
                        H_USAGE="$H_USAGE"$'\n'"$trimmed"
                    else
                        H_USAGE="$trimmed"
                    fi
                    ;;
                example)
                    if [ -n "$H_EXAMPLE" ]; then
                        H_EXAMPLE="$H_EXAMPLE"$'\n'"$trimmed"
                    else
                        H_EXAMPLE="$trimmed"
                    fi
                    ;;
            esac
        fi
    done < "$file"
}

# --- Argument parsing ------------------------------------------------------
declare -a TERMS=()
SHOW_ALL=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --all)
            SHOW_ALL=1
            shift
            ;;
        --dir)
            if [ "$#" -lt 2 ]; then
                echo "Error: --dir requires a directory argument." >&2
                exit 1
            fi
            SEARCH_DIR="$2"
            shift 2
            ;;
        --dir=*)
            SEARCH_DIR="${1#--dir=}"
            shift
            ;;
        --)
            shift
            while [ "$#" -gt 0 ]; do TERMS+=("$1"); shift; done
            ;;
        -*)
            echo "Error: unknown option '$1'." >&2
            usage >&2
            exit 1
            ;;
        *)
            TERMS+=("$1")
            shift
            ;;
    esac
done

if [ "${#TERMS[@]}" -eq 0 ]; then
    echo "Error: no keyword provided." >&2
    echo >&2
    usage >&2
    exit 1
fi

if [ ! -d "$SEARCH_DIR" ]; then
    echo "Error: search directory '$SEARCH_DIR' does not exist." >&2
    exit 1
fi

# Warn about overly broad single-character keywords up front.
for t in "${TERMS[@]}"; do
    if [ "${#t}" -lt 2 ]; then
        echo "${YELLOW}Note:${RESET} keyword '$t' is very short and may match many scripts." >&2
    fi
done

QUERY="${TERMS[*]}"

# --- Scan and score scripts ------------------------------------------------
declare -a R_NAME=() R_DESC=() R_USAGE=() R_EXAMPLE=() R_SCORE=() R_REASON=()

files=("$SEARCH_DIR"/*.sh)
if [ "${#files[@]}" -eq 0 ]; then
    echo "No scripts (*.sh) found in '$SEARCH_DIR'." >&2
    exit 1
fi

self_base="$(basename "${BASH_SOURCE[0]}")"

for file in "${files[@]}"; do
    base="$(basename "$file")"

    # Skip the finder itself: its help/examples mention many keywords, so it
    # would otherwise surface in almost every search and add noise.
    [ "$base" = "$self_base" ] && continue

    parse_header "$file"

    name_display="${H_NAME:-$base}"
    name_noext="${base%.sh}"

    lc_name="$(to_lower "$name_noext")"
    lc_desc="$(to_lower "$H_DESC")"
    lc_usage="$(to_lower "$H_USAGE")"
    lc_example="$(to_lower "$H_EXAMPLE")"

    score=0
    hit_name=0
    hit_desc=0
    hit_usage=0

    for term in "${TERMS[@]}"; do
        lc_term="$(to_lower "$term")"

        if [ "$lc_name" = "$lc_term" ]; then
            score=$((score + 100))
            hit_name=1
        elif [[ "$lc_name" == *"$lc_term"* ]]; then
            score=$((score + 40))
            hit_name=1
        fi

        if [[ "$lc_desc" == *"$lc_term"* ]]; then
            score=$((score + 15))
            hit_desc=1
        fi
        if [[ "$lc_usage" == *"$lc_term"* ]]; then
            score=$((score + 8))
            hit_usage=1
        fi
        if [[ "$lc_example" == *"$lc_term"* ]]; then
            score=$((score + 5))
            hit_usage=1
        fi
    done

    [ "$score" -eq 0 ] && continue

    reason=""
    [ "$hit_name" -eq 1 ] && reason="name"
    if [ "$hit_desc" -eq 1 ]; then
        reason="${reason:+$reason, }description"
    fi
    if [ "$hit_usage" -eq 1 ]; then
        reason="${reason:+$reason, }usage"
    fi

    R_NAME+=("$name_display")
    R_DESC+=("$H_DESC")
    R_USAGE+=("$H_USAGE")
    R_EXAMPLE+=("$H_EXAMPLE")
    R_SCORE+=("$score")
    R_REASON+=("$reason")
done

count="${#R_NAME[@]}"

# --- No matches: never exit silently --------------------------------------
if [ "$count" -eq 0 ]; then
    echo "No scripts found matching \"${QUERY}\"."
    echo "Try a broader or different keyword, e.g.: backup, weather, video, git, file."
    echo "Run './${self_base} --help' for usage."
    exit 1
fi

# --- Sort matches by score (desc), then by name (asc) ----------------------
declare -a ORDER=()
while IFS=$'\t' read -r _ _ idx; do
    ORDER+=("$idx")
done < <(
    for i in "${!R_NAME[@]}"; do
        printf '%s\t%s\t%s\n' "${R_SCORE[$i]}" "${R_NAME[$i]}" "$i"
    done | sort -t$'\t' -k1,1nr -k2,2
)

# --- Render a single, unambiguous match in full detail ---------------------
if [ "$count" -eq 1 ]; then
    i="${ORDER[0]}"
    echo "Found 1 script matching \"${QUERY}\":"
    echo
    echo "${BOLD}${CYAN}${R_NAME[$i]}${RESET}"
    if [ -n "${R_DESC[$i]}" ]; then
        echo "  ${R_DESC[$i]}"
    else
        echo "  ${DIM}(no description available)${RESET}"
    fi
    echo
    if [ -n "${R_USAGE[$i]}" ]; then
        echo "  ${BOLD}Usage:${RESET}"
        while IFS= read -r uline; do
            [ -n "$uline" ] && echo "    $uline"
        done <<< "${R_USAGE[$i]}"
    fi
    if [ -n "${R_EXAMPLE[$i]}" ]; then
        echo "  ${BOLD}Example:${RESET}"
        while IFS= read -r eline; do
            [ -n "$eline" ] && echo "    $eline"
        done <<< "${R_EXAMPLE[$i]}"
    fi
    exit 0
fi

# --- Render multiple matches as a ranked list ------------------------------
echo "Found ${count} scripts matching \"${QUERY}\" (most relevant first):"

display_limit="$count"
if [ "$SHOW_ALL" -eq 0 ] && [ "$count" -gt "$BROAD_THRESHOLD" ]; then
    echo "${YELLOW}Note:${RESET} your keyword matched many scripts. Showing the top" \
         "${BROAD_THRESHOLD}; use a more specific keyword or pass --all to see all."
    display_limit="$BROAD_THRESHOLD"
fi
echo

shown=0
for idx in "${ORDER[@]}"; do
    if [ "$shown" -ge "$display_limit" ]; then
        break
    fi
    shown=$((shown + 1))

    name="${R_NAME[$idx]}"
    desc="${R_DESC[$idx]}"
    reason="${R_REASON[$idx]}"

    # First usage line gives a compact "how to run it" hint.
    first_usage=""
    if [ -n "${R_USAGE[$idx]}" ]; then
        first_usage="$(head -n 1 <<< "${R_USAGE[$idx]}")"
    fi

    echo "${BOLD}${CYAN}${name}${RESET}  ${DIM}(matched in: ${reason})${RESET}"
    if [ -n "$desc" ]; then
        echo "    $(truncate_str "$desc" 100)"
    else
        echo "    ${DIM}(no description available)${RESET}"
    fi
    if [ -n "$first_usage" ]; then
        echo "    ${DIM}Usage:${RESET} ${first_usage}"
    fi
    echo
done

echo "${DIM}Tip: run './${self_base} <keyword>' with a single, specific result to see full usage and an example.${RESET}"
