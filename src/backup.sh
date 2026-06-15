#!/usr/bin/env bash

# Script Name: backup.sh
# Description: Creates reliable filesystem backups with optional compression,
#              symmetric GPG encryption, retention cleanup, and an interactive
#              menu for ad-hoc or cron-friendly usage.
# Usage:
#   ./backup.sh
#   ./backup.sh --auto --source "$HOME/Documents" --dest /mnt/backups --compress
#   ./backup.sh --auto --dest /mnt/backups --exclude '*.cache' --retention-daily 14
#   ./backup.sh --profile documents                       # run a saved profile
#   ./backup.sh --config ~/.config/backup/backup.conf --profile photos
#   ./backup.sh --profile documents --dest /mnt/usb       # profile + CLI override
#   ./backup.sh --profile documents --dry-run             # preview, write nothing

set -euo pipefail
IFS=$'\n\t'

###############################################################################
# Globals
###############################################################################
SCRIPT_NAME="$(basename "$0")"
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
HOST_TAG="$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'host')"
HOST_TAG="${HOST_TAG//[^[:alnum:]._-]/-}"

DEFAULT_SOURCE_DIRS=(
    "$HOME/Documents"
    "$HOME/Downloads"
    "$HOME/Desktop"
)

SOURCE_DIRS=()
EXCLUDE_PATTERNS=()
TARGET_DIR=""

COMPRESS=false
ENCRYPT=false
GPG_PASSPHRASE=""
GPG_PASSPHRASE_FILE=""

RETENTION_DAILY=7
RETENTION_WEEKLY=4
RETENTION_MONTHLY=3

AUTO_MODE=false
BACKUP_REQUESTED=false
QUIET=false
VERBOSE=false
NO_COLOR=false
DRY_RUN=false

# Configuration profile support.
CONFIG_FILE=""
PROFILE_NAME=""
WANT_PROFILE=false

# Default config file search order when --config is omitted but a profile is
# requested. The BACKUP_CONFIG environment variable takes precedence and is
# convenient for cron jobs.
DEFAULT_CONFIG_FILES=(
    "${XDG_CONFIG_HOME:-$HOME/.config}/backup/backup.conf"
    "$HOME/.backup.conf"
)

# Track which settings were given explicitly on the command line so that a
# loaded profile only fills in the values the user did not override.
CLI_SOURCE_SET=false
CLI_EXCLUDE_SET=false
CLI_DEST_SET=false
CLI_COMPRESS_SET=false
CLI_ENCRYPT_SET=false
CLI_GPG_PASSPHRASE_SET=false
CLI_GPG_PASSPHRASE_FILE_SET=false
CLI_RETENTION_DAILY_SET=false
CLI_RETENTION_WEEKLY_SET=false
CLI_RETENTION_MONTHLY_SET=false

CURRENT_ARTIFACT=""
LOCK_DIR=""
BACKUP_SUCCEEDED=false

###############################################################################
# Logging
###############################################################################
supports_color() {
    [[ "$NO_COLOR" != true && -t 2 ]]
}

color_code() {
    case "$1" in
        INFO) printf '34' ;;
        WARN) printf '33' ;;
        ERROR) printf '31' ;;
        DEBUG) printf '36' ;;
        *) printf '0' ;;
    esac
}

log_msg() {
    local level="$1"
    shift
    local message="$*"
    local timestamp plain rendered label

    [[ "$QUIET" == true && "$level" == "INFO" ]] && return 0
    [[ "$VERBOSE" != true && "$level" == "DEBUG" ]] && return 0

    timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    plain="[$timestamp] [$level] $message"

    if supports_color; then
        label="$(printf '\e[%sm%s\e[0m' "$(color_code "$level")" "$level")"
        rendered="[$timestamp] [$label] $message"
    else
        rendered="$plain"
    fi

    printf '%s\n' "$rendered" >&2
}

die() {
    log_msg ERROR "$*"
    exit 1
}

###############################################################################
# Cleanup
###############################################################################
cleanup() {
    local exit_code=$?

    trap - EXIT INT TERM

    if [[ $exit_code -ne 0 && "$BACKUP_SUCCEEDED" != true && -n "$CURRENT_ARTIFACT" && -e "$CURRENT_ARTIFACT" ]]; then
        log_msg WARN "Removing incomplete backup artifact: $CURRENT_ARTIFACT"
        rm -rf -- "$CURRENT_ARTIFACT"
    fi

    if [[ -n "$LOCK_DIR" && -d "$LOCK_DIR" ]]; then
        rmdir -- "$LOCK_DIR" 2>/dev/null || true
    fi

    exit "$exit_code"
}

trap cleanup EXIT INT TERM

###############################################################################
# Usage
###############################################################################
print_usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME
  $SCRIPT_NAME --auto [options]

Profile options:
  --config FILE                 INI-style file holding one or more [profile]
                                sections. When omitted but --profile is given,
                                searches \$BACKUP_CONFIG and then:
                                ${DEFAULT_CONFIG_FILES[*]}
  --profile NAME                Load settings from the [NAME] section. Defaults
                                to "default" when --config is given without it.
  --dry-run                     Show the resolved sources, destination, output
                                artifact, and retention effect without writing.

Options:
  --source PATH                 Add a source file or directory to the backup.
                                Can be used multiple times. Defaults to:
                                ${DEFAULT_SOURCE_DIRS[*]}
  --dest DIR                    Backup destination root directory.
  --exclude PATTERN             rsync exclude pattern. Can be used multiple times.
  --compress                    Package the backup as .tar.gz.
  --encrypt                     Encrypt the final artifact with symmetric GPG.
  --gpg-passphrase VALUE        Passphrase for --encrypt.
  --gpg-passphrase-file FILE    Read GPG passphrase from FILE.
  --retention-daily N           Keep all backups from the last N days. Default: $RETENTION_DAILY
  --retention-weekly N          Then keep one backup per week for N weeks. Default: $RETENTION_WEEKLY
  --retention-monthly N         Then keep one backup per month for N months. Default: $RETENTION_MONTHLY
  --auto                        Run non-interactively.
  -q, --quiet                   Hide informational logs.
  -v, --verbose                 Print debug logs.
      --no-color                Disable colored log labels.
  -h, --help                    Show this help message.

Command-line options override values loaded from a profile, so common setups
can live in the config file while one-off runs tweak them on the fly.

Config file format (one or more named profiles per file):
  [documents]
  source = ~/Documents
  source = ~/Notes
  dest = /mnt/backups/documents
  exclude = *.tmp
  compress = true
  retention_daily = 14

Examples:
  $SCRIPT_NAME --auto --dest /mnt/backups
  $SCRIPT_NAME --auto --source "\$HOME/Documents" --source "\$HOME/Pictures" --dest /mnt/backups --compress
  $SCRIPT_NAME --auto --dest /mnt/backups --compress --encrypt --gpg-passphrase-file ~/.config/backup.pass
  $SCRIPT_NAME --profile documents
  $SCRIPT_NAME --config ~/.config/backup/backup.conf --profile photos --dry-run
  $SCRIPT_NAME --profile documents --dest /mnt/usb   # override the profile's dest
EOF
}

press_enter_to_continue() {
    echo
    read -r -p "Press [Enter] to continue..."
}

prompt_yes_no() {
    local prompt="$1"
    local default_answer="${2:-y}"
    local answer=""

    while true; do
        read -r -p "$prompt" answer
        answer="${answer:-$default_answer}"
        case "$answer" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

###############################################################################
# Validation helpers
###############################################################################
require_command() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
}

canonical_path() {
    local path="$1"

    if [[ -d "$path" ]]; then
        (
            cd "$path" >/dev/null 2>&1 &&
                pwd -P
        )
        return
    fi

    if [[ -e "$path" ]]; then
        (
            cd "$(dirname "$path")" >/dev/null 2>&1 &&
                printf '%s/%s\n' "$(pwd -P)" "$(basename "$path")"
        )
        return
    fi

    if [[ -d "$(dirname "$path")" ]]; then
        (
            cd "$(dirname "$path")" >/dev/null 2>&1 &&
                printf '%s/%s\n' "$(pwd -P)" "$(basename "$path")"
        )
        return
    fi

    printf '%s\n' "$path"
}

is_non_negative_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

validate_retention_value() {
    local label="$1"
    local value="$2"

    is_non_negative_integer "$value" || die "$label must be a non-negative integer."
}

validate_backup_target() {
    local target_canon source source_canon

    target_canon="$(canonical_path "$TARGET_DIR")"
    for source in "${SOURCE_DIRS[@]}"; do
        [[ -d "$source" ]] || continue
        source_canon="$(canonical_path "$source")"
        case "$target_canon/" in
            "$source_canon/"*)
                die "Backup destination must not be inside source directory: $source"
                ;;
        esac
    done
}

validate_configuration() {
    local source valid_sources=0

    require_command rsync
    require_command tar
    require_command date
    require_command find
    require_command hostname
    require_command mktemp

    [[ -n "$TARGET_DIR" ]] || die "Backup destination is required."
    [[ "$DRY_RUN" == true ]] || mkdir -p -- "$TARGET_DIR"

    validate_retention_value "Daily retention" "$RETENTION_DAILY"
    validate_retention_value "Weekly retention" "$RETENTION_WEEKLY"
    validate_retention_value "Monthly retention" "$RETENTION_MONTHLY"

    if [[ ${#SOURCE_DIRS[@]} -eq 0 ]]; then
        die "At least one source file or directory is required."
    fi

    for source in "${SOURCE_DIRS[@]}"; do
        if [[ -e "$source" ]]; then
            valid_sources=$((valid_sources + 1))
        else
            log_msg WARN "Source does not exist and will be skipped: $source"
        fi
    done

    [[ $valid_sources -gt 0 ]] || die "None of the configured sources exist."

    if [[ "$ENCRYPT" == true ]]; then
        require_command gpg

        if [[ -n "$GPG_PASSPHRASE" && -n "$GPG_PASSPHRASE_FILE" ]]; then
            die "Use either --gpg-passphrase or --gpg-passphrase-file, not both."
        fi

        if [[ -n "$GPG_PASSPHRASE_FILE" ]]; then
            [[ -f "$GPG_PASSPHRASE_FILE" ]] || die "GPG passphrase file not found: $GPG_PASSPHRASE_FILE"
        elif [[ -z "$GPG_PASSPHRASE" ]]; then
            die "Encryption requires --gpg-passphrase or --gpg-passphrase-file."
        fi
    fi

    validate_backup_target
}

###############################################################################
# Configuration profiles
###############################################################################
trim() {
    local string="$1"
    string="${string#"${string%%[![:space:]]*}"}"
    string="${string%"${string##*[![:space:]]}"}"
    printf '%s' "$string"
}

parse_bool() {
    local value
    value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$value" in
        true | yes | y | on | 1) printf 'true' ;;
        false | no | n | off | 0) printf 'false' ;;
        *) return 1 ;;
    esac
}

# Expand a leading "~" and "$HOME"/"${HOME}" without evaluating arbitrary shell.
expand_path_value() {
    local value="$1"

    if [[ "$value" == "~" ]]; then
        value="$HOME"
    elif [[ "$value" == "~/"* ]]; then
        value="$HOME/${value#\~/}"
    fi

    value="${value//\$\{HOME\}/$HOME}"
    value="${value//\$HOME/$HOME}"
    printf '%s' "$value"
}

# Decide which configuration file and profile name to use.
resolve_config() {
    local candidate

    [[ -n "$PROFILE_NAME" ]] || PROFILE_NAME="default"

    if [[ -z "$CONFIG_FILE" ]]; then
        if [[ -n "${BACKUP_CONFIG:-}" ]]; then
            CONFIG_FILE="$BACKUP_CONFIG"
        else
            for candidate in "${DEFAULT_CONFIG_FILES[@]}"; do
                if [[ -f "$candidate" ]]; then
                    CONFIG_FILE="$candidate"
                    break
                fi
            done
        fi
    fi

    if [[ -z "$CONFIG_FILE" ]]; then
        die "No configuration file found. Pass --config FILE or create one of: ${DEFAULT_CONFIG_FILES[*]}"
    fi

    [[ -f "$CONFIG_FILE" ]] || die "Configuration file not found: $CONFIG_FILE"
    [[ -r "$CONFIG_FILE" ]] || die "Configuration file is not readable: $CONFIG_FILE"
}

# Parse a single [profile] section from the INI-style configuration file.
# Command-line values always win, so a setting is only applied here when the
# user did not already provide it on the command line.
load_profile() {
    local current_section="" in_target=false found=false line_no=0
    local raw line key value bool
    local -a available_profiles=()

    log_msg DEBUG "Loading profile '$PROFILE_NAME' from $CONFIG_FILE"

    [[ "$CLI_SOURCE_SET" == true ]] || SOURCE_DIRS=()
    [[ "$CLI_EXCLUDE_SET" == true ]] || EXCLUDE_PATTERNS=()

    while IFS= read -r raw || [[ -n "$raw" ]]; do
        line_no=$((line_no + 1))
        line="${raw%$'\r'}"
        line="$(trim "$line")"

        [[ -z "$line" ]] && continue
        [[ "$line" == \#* || "$line" == \;* ]] && continue

        if [[ "$line" =~ ^\[(.*)\]$ ]]; then
            current_section="$(trim "${BASH_REMATCH[1]}")"
            available_profiles+=("$current_section")
            if [[ "$current_section" == "$PROFILE_NAME" ]]; then
                in_target=true
                found=true
            else
                in_target=false
            fi
            continue
        fi

        [[ "$in_target" == true ]] || continue

        if [[ "$line" != *=* ]]; then
            log_msg WARN "Ignoring malformed line $line_no in '$CONFIG_FILE': $line"
            continue
        fi

        key="$(trim "${line%%=*}")"
        value="$(trim "${line#*=}")"
        value="$(expand_path_value "$value")"

        case "$key" in
            source)
                [[ "$CLI_SOURCE_SET" == true ]] || SOURCE_DIRS+=("$value")
                ;;
            exclude)
                [[ "$CLI_EXCLUDE_SET" == true ]] || EXCLUDE_PATTERNS+=("$value")
                ;;
            dest | destination)
                [[ "$CLI_DEST_SET" == true ]] || TARGET_DIR="$value"
                ;;
            compress)
                if [[ "$CLI_COMPRESS_SET" != true ]]; then
                    bool="$(parse_bool "$value")" || die "Invalid boolean for 'compress' in profile '$PROFILE_NAME' (line $line_no): $value"
                    COMPRESS="$bool"
                fi
                ;;
            encrypt)
                if [[ "$CLI_ENCRYPT_SET" != true ]]; then
                    bool="$(parse_bool "$value")" || die "Invalid boolean for 'encrypt' in profile '$PROFILE_NAME' (line $line_no): $value"
                    ENCRYPT="$bool"
                fi
                ;;
            gpg_passphrase)
                [[ "$CLI_GPG_PASSPHRASE_SET" == true ]] || GPG_PASSPHRASE="$value"
                ;;
            gpg_passphrase_file)
                [[ "$CLI_GPG_PASSPHRASE_FILE_SET" == true ]] || GPG_PASSPHRASE_FILE="$value"
                ;;
            retention_daily)
                [[ "$CLI_RETENTION_DAILY_SET" == true ]] || RETENTION_DAILY="$value"
                ;;
            retention_weekly)
                [[ "$CLI_RETENTION_WEEKLY_SET" == true ]] || RETENTION_WEEKLY="$value"
                ;;
            retention_monthly)
                [[ "$CLI_RETENTION_MONTHLY_SET" == true ]] || RETENTION_MONTHLY="$value"
                ;;
            *)
                log_msg WARN "Unknown setting '$key' in profile '$PROFILE_NAME' (line $line_no); ignoring."
                ;;
        esac
    done <"$CONFIG_FILE"

    if [[ "$found" != true ]]; then
        local profile_list="<none>"
        if [[ ${#available_profiles[@]} -gt 0 ]]; then
            printf -v profile_list '%s, ' "${available_profiles[@]}"
            profile_list="${profile_list%, }"
        fi
        die "Profile '$PROFILE_NAME' not found in $CONFIG_FILE. Available profiles: ${profile_list}"
    fi

    log_msg INFO "Loaded profile '$PROFILE_NAME' from $CONFIG_FILE"
}

# Give friendly, specific errors when a profile is missing required fields.
check_profile_completeness() {
    if [[ ${#SOURCE_DIRS[@]} -eq 0 ]]; then
        die "Profile '$PROFILE_NAME' defines no 'source' entries and none were provided via --source."
    fi

    if [[ -z "$TARGET_DIR" ]]; then
        die "Profile '$PROFILE_NAME' defines no 'dest' and --dest was not provided."
    fi
}

###############################################################################
# Interactive selection
###############################################################################
load_default_sources() {
    local dir

    SOURCE_DIRS=()
    for dir in "${DEFAULT_SOURCE_DIRS[@]}"; do
        [[ -e "$dir" ]] || continue
        SOURCE_DIRS+=("$dir")
    done
}

read_paths_into_array() {
    local -n target_ref="$1"
    local prompt="$2"
    local value=""

    while true; do
        read -r -p "$prompt" value
        [[ -z "$value" ]] && break
        target_ref+=("$value")
    done
}

select_source_directories() {
    local choice=""
    local extras=()

    load_default_sources

    echo
    echo "Default backup sources:"
    if [[ ${#SOURCE_DIRS[@]} -eq 0 ]]; then
        echo " - No default directories currently exist on this machine."
    else
        printf ' - %s\n' "${SOURCE_DIRS[@]}"
    fi

    echo
    echo "K) Keep current defaults"
    echo "A) Add more paths"
    echo "C) Choose custom paths only"
    read -r -p "Choose [K/A/C]: " choice

    case "$choice" in
        [Aa]*)
            echo "Enter one path per line. Submit an empty line when done."
            read_paths_into_array extras "Additional source path: "
            SOURCE_DIRS+=("${extras[@]}")
            ;;
        [Cc]*)
            SOURCE_DIRS=()
            echo "Enter one path per line. Submit an empty line when done."
            read_paths_into_array SOURCE_DIRS "Source path: "
            ;;
        *)
            ;;
    esac
}

detect_usb_drives() {
    command -v lsblk >/dev/null 2>&1 || return 0
    lsblk -nr -o RM,MOUNTPOINT | awk '$1=="1" && $2!="" {print $2}'
}

select_target_directory() {
    local choice="" custom_path="" usb_choice=""
    local usb_drives=()

    while true; do
        echo
        echo "Select backup destination:"
        echo "1) Enter a custom path"
        echo "2) Choose from detected USB drives"
        echo "3) Cancel"
        read -r -p "Enter your choice [1-3]: " choice

        case "$choice" in
            1)
                read -r -p "Enter destination directory: " custom_path
                [[ -n "$custom_path" ]] || {
                    echo "Destination cannot be empty."
                    continue
                }
                TARGET_DIR="$custom_path"
                return 0
                ;;
            2)
                mapfile -t usb_drives < <(detect_usb_drives)
                if [[ ${#usb_drives[@]} -eq 0 ]]; then
                    echo "No mounted removable drives detected."
                    continue
                fi

                printf '%s\n' "${usb_drives[@]}" | nl -w1 -s') '
                read -r -p "Select a drive by number: " usb_choice
                if [[ "$usb_choice" =~ ^[0-9]+$ ]] && (( usb_choice >= 1 && usb_choice <= ${#usb_drives[@]} )); then
                    TARGET_DIR="${usb_drives[$((usb_choice - 1))]}"
                    return 0
                fi
                echo "Invalid drive selection."
                ;;
            3)
                return 1
                ;;
            *)
                echo "Invalid choice."
                ;;
        esac
    done
}

prompt_backup_settings() {
    local retention_value=""

    COMPRESS=false
    ENCRYPT=false
    GPG_PASSPHRASE=""
    GPG_PASSPHRASE_FILE=""
    EXCLUDE_PATTERNS=()
    RETENTION_DAILY=7
    RETENTION_WEEKLY=4
    RETENTION_MONTHLY=3

    echo
    if prompt_yes_no "Enable compression? [Y/n]: " "y"; then
        COMPRESS=true
    fi

    if prompt_yes_no "Enable encryption? [y/N]: " "n"; then
        ENCRYPT=true
        read -r -p "Use a passphrase file instead of typing the passphrase? [y/N]: " retention_value
        if [[ "$retention_value" =~ ^[Yy]$ ]]; then
            read -r -p "Path to passphrase file: " GPG_PASSPHRASE_FILE
        else
            read -r -s -p "Enter GPG passphrase: " GPG_PASSPHRASE
            echo
            [[ -n "$GPG_PASSPHRASE" ]] || die "Encryption passphrase cannot be empty."
        fi
    fi

    if prompt_yes_no "Add rsync exclude patterns? [y/N]: " "n"; then
        echo "Enter one exclude pattern per line. Submit an empty line when done."
        read_paths_into_array EXCLUDE_PATTERNS "Exclude pattern: "
    fi

    read -r -p "Daily retention in days [7]: " retention_value
    RETENTION_DAILY="${retention_value:-7}"
    read -r -p "Weekly retention in weeks [4]: " retention_value
    RETENTION_WEEKLY="${retention_value:-4}"
    read -r -p "Monthly retention in months [3]: " retention_value
    RETENTION_MONTHLY="${retention_value:-3}"
}

###############################################################################
# Backup implementation
###############################################################################
backup_base_name() {
    local name="$1"

    name="${name%.tar.gz.gpg}"
    name="${name%.tar.gpg}"
    name="${name%.tar.gz}"
    name="${name%.tar}"
    name="${name%.gpg}"
    printf '%s\n' "$name"
}

timestamp_to_epoch() {
    local stamp="$1"
    date -u -d "${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2} UTC" +%s
}

create_lock() {
    LOCK_DIR="${TARGET_DIR%/}/.backup.lock"
    if mkdir -- "$LOCK_DIR" 2>/dev/null; then
        return 0
    fi
    die "Another backup appears to be running for $TARGET_DIR"
}

build_shell_command() {
    local IFS=' '
    local rendered=()
    local arg="" quoted=""

    for arg in "$@"; do
        printf -v quoted '%q' "$arg"
        rendered+=("$quoted")
    done

    printf '%s' "${rendered[*]}"
}

write_metadata() {
    local snapshot_dir="$1"
    local manifest_path="$snapshot_dir/backup_manifest.txt"
    local source=""
    local pattern=""

    {
        printf 'backup_name=%s\n' "$(basename "$snapshot_dir")"
        printf 'created_at_utc=%s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        printf 'host=%s\n' "$HOST_TAG"
        if [[ "$WANT_PROFILE" == true ]]; then
            printf 'profile=%s\n' "$PROFILE_NAME"
        fi
        printf 'compress=%s\n' "$COMPRESS"
        printf 'encrypt=%s\n' "$ENCRYPT"
        printf 'retention_daily=%s\n' "$RETENTION_DAILY"
        printf 'retention_weekly=%s\n' "$RETENTION_WEEKLY"
        printf 'retention_monthly=%s\n' "$RETENTION_MONTHLY"
        printf 'sources:\n'
        for source in "${SOURCE_DIRS[@]}"; do
            printf '  - %s\n' "$source"
        done
        if [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]]; then
            printf 'excludes:\n'
            for pattern in "${EXCLUDE_PATTERNS[@]}"; do
                printf '  - %s\n' "$pattern"
            done
        fi
    } >"$manifest_path"
}

sync_source() {
    local source="$1"
    local snapshot_dir="$2"
    local relative_path destination_dir parent_dir
    local rsync_args=(--archive --human-readable)
    local pattern=""

    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        rsync_args+=("--exclude=$pattern")
    done

    if [[ -d "$source" ]]; then
        relative_path="${source#/}"
        destination_dir="$snapshot_dir/files/$relative_path"
        mkdir -p -- "$destination_dir"
        log_msg INFO "Backing up directory: $source"
        rsync "${rsync_args[@]}" -- "$source/" "$destination_dir/"
        return 0
    fi

    if [[ -f "$source" ]]; then
        relative_path="${source#/}"
        parent_dir="$snapshot_dir/files/$(dirname "$relative_path")"
        mkdir -p -- "$parent_dir"
        log_msg INFO "Backing up file: $source"
        rsync "${rsync_args[@]}" -- "$source" "$parent_dir/"
        return 0
    fi

    log_msg WARN "Skipping unsupported or missing source: $source"
    return 1
}

package_backup() {
    local snapshot_dir="$1"
    local backup_name="$2"
    local artifact="$snapshot_dir"
    local archive_path="" encrypted_path=""

    if [[ "$COMPRESS" == true || "$ENCRYPT" == true ]]; then
        if [[ "$COMPRESS" == true ]]; then
            archive_path="${TARGET_DIR%/}/${backup_name}.tar.gz"
            CURRENT_ARTIFACT="$archive_path"
            log_msg INFO "Compressing backup to: $archive_path"
            tar -czf "$archive_path" -C "$(dirname "$snapshot_dir")" "$(basename "$snapshot_dir")"
        else
            archive_path="${TARGET_DIR%/}/${backup_name}.tar"
            CURRENT_ARTIFACT="$archive_path"
            log_msg INFO "Packing backup to: $archive_path"
            tar -cf "$archive_path" -C "$(dirname "$snapshot_dir")" "$(basename "$snapshot_dir")"
        fi

        rm -rf -- "$snapshot_dir"
        artifact="$archive_path"
    fi

    if [[ "$ENCRYPT" == true ]]; then
        encrypted_path="${artifact}.gpg"
        CURRENT_ARTIFACT="$encrypted_path"
        log_msg INFO "Encrypting backup to: $encrypted_path"

        if [[ -n "$GPG_PASSPHRASE_FILE" ]]; then
            gpg --batch --yes --pinentry-mode loopback \
                --passphrase-file "$GPG_PASSPHRASE_FILE" \
                --symmetric \
                --output "$encrypted_path" \
                "$artifact"
        else
            gpg --batch --yes --pinentry-mode loopback \
                --passphrase "$GPG_PASSPHRASE" \
                --symmetric \
                --output "$encrypted_path" \
                "$artifact"
        fi

        rm -f -- "$artifact"
        artifact="$encrypted_path"
    fi

    CURRENT_ARTIFACT="$artifact"
}

apply_retention_policy() {
    local target_dir="$1"
    local now_epoch daily_cutoff weekly_cutoff monthly_cutoff
    local item name base_name stamp epoch week_key month_key
    local removed=0
    local -a candidates=() entries=()
    declare -A kept_weeks=()
    declare -A kept_months=()

    if (( RETENTION_DAILY == 0 && RETENTION_WEEKLY == 0 && RETENTION_MONTHLY == 0 )); then
        log_msg INFO "Retention disabled; keeping all existing backups."
        return 0
    fi

    now_epoch="$(date -u +%s)"
    daily_cutoff=$(( now_epoch - (RETENTION_DAILY * 86400) ))
    weekly_cutoff=$(( now_epoch - (RETENTION_WEEKLY * 7 * 86400) ))
    monthly_cutoff=$(( now_epoch - (RETENTION_MONTHLY * 31 * 86400) ))

    while IFS= read -r item; do
        [[ -n "$item" ]] && candidates+=("$item")
    done < <(find "$target_dir" -mindepth 1 -maxdepth 1 \( -type f -o -type d \) -name 'backup_*' -printf '%f\n')

    if [[ ${#candidates[@]} -eq 0 ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            log_msg INFO "Dry run: no existing backups present to evaluate for retention."
        fi
        return 0
    fi

    for name in "${candidates[@]}"; do
        base_name="$(backup_base_name "$name")"
        stamp="${base_name#backup_}"
        stamp="${stamp%%_*}"
        [[ "$stamp" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || continue
        epoch="$(timestamp_to_epoch "$stamp")"
        entries+=("${epoch}"$'\t'"${name}")
    done

    [[ ${#entries[@]} -gt 0 ]] || return 0

    mapfile -t entries < <(printf '%s\n' "${entries[@]}" | sort -r)

    for item in "${entries[@]}"; do
        epoch="${item%%$'\t'*}"
        name="${item#*$'\t'}"

        if (( RETENTION_DAILY > 0 )) && (( epoch >= daily_cutoff )); then
            continue
        fi

        if (( RETENTION_WEEKLY > 0 )) && (( epoch >= weekly_cutoff )); then
            week_key="$(date -u -d "@$epoch" +%G-%V)"
            if [[ -z "${kept_weeks[$week_key]+x}" ]]; then
                kept_weeks[$week_key]=1
                continue
            fi
        fi

        if (( RETENTION_MONTHLY > 0 )) && (( epoch >= monthly_cutoff )); then
            month_key="$(date -u -d "@$epoch" +%Y-%m)"
            if [[ -z "${kept_months[$month_key]+x}" ]]; then
                kept_months[$month_key]=1
                continue
            fi
        fi

        removed=$((removed + 1))
        if [[ "$DRY_RUN" == true ]]; then
            log_msg INFO "Would remove expired backup: ${target_dir%/}/$name"
            continue
        fi

        log_msg INFO "Removing expired backup: ${target_dir%/}/$name"
        target_dir=${target_dir%/}
        rm -rf -- "${target_dir:?}/$name"
    done

    if [[ "$DRY_RUN" == true ]]; then
        if ((removed > 0)); then
            log_msg INFO "Dry run: $removed expired backup(s) would be removed by the retention policy."
        else
            log_msg INFO "Dry run: no expired backups would be removed by the retention policy."
        fi
    fi
}

render_dry_run_plan() {
    local timestamp backup_name artifact source existing=0

    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    backup_name="backup_${timestamp}_${HOST_TAG}"

    log_msg INFO "Dry run enabled: no files will be written."
    if [[ "$WANT_PROFILE" == true ]]; then
        log_msg INFO "Profile: $PROFILE_NAME (from $CONFIG_FILE)"
    fi

    log_msg INFO "Source paths that would be processed:"
    for source in "${SOURCE_DIRS[@]}"; do
        if [[ -e "$source" ]]; then
            log_msg INFO "  include : $source"
            existing=$((existing + 1))
        else
            log_msg WARN "  skip    : $source (does not exist)"
        fi
    done
    log_msg INFO "$existing of ${#SOURCE_DIRS[@]} configured source path(s) currently exist."

    log_msg INFO "Destination directory: ${TARGET_DIR%/}"

    if [[ "$COMPRESS" == true && "$ENCRYPT" == true ]]; then
        artifact="${backup_name}.tar.gz.gpg"
    elif [[ "$COMPRESS" == true ]]; then
        artifact="${backup_name}.tar.gz"
    elif [[ "$ENCRYPT" == true ]]; then
        artifact="${backup_name}.tar.gpg"
    else
        artifact="${backup_name}/ (uncompressed snapshot directory)"
    fi
    log_msg INFO "Output artifact: ${TARGET_DIR%/}/$artifact"
    log_msg INFO "Compression: $COMPRESS | Encryption: $ENCRYPT"
    log_msg INFO "Retention policy: daily=$RETENTION_DAILY weekly=$RETENTION_WEEKLY monthly=$RETENTION_MONTHLY"

    if [[ -d "$TARGET_DIR" ]]; then
        apply_retention_policy "$TARGET_DIR"
    else
        log_msg INFO "Destination does not exist yet; no existing backups to clean."
    fi
}

create_backup() {
    local timestamp backup_name snapshot_dir source copied_count=0

    validate_configuration

    if [[ "$DRY_RUN" == true ]]; then
        render_dry_run_plan
        return 0
    fi

    create_lock

    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    backup_name="backup_${timestamp}_${HOST_TAG}"
    snapshot_dir="${TARGET_DIR%/}/${backup_name}"
    CURRENT_ARTIFACT="$snapshot_dir"

    mkdir -p -- "$snapshot_dir/files"
    write_metadata "$snapshot_dir"

    for source in "${SOURCE_DIRS[@]}"; do
        if sync_source "$source" "$snapshot_dir"; then
            copied_count=$((copied_count + 1))
        fi
    done

    [[ $copied_count -gt 0 ]] || die "No sources were successfully backed up."

    package_backup "$snapshot_dir" "$backup_name"
    BACKUP_SUCCEEDED=true

    log_msg INFO "Backup created successfully: $CURRENT_ARTIFACT"
    apply_retention_policy "$TARGET_DIR"
}

###############################################################################
# Cron helper
###############################################################################
configure_cron_job() {
    local cron_sources=()
    local cron_excludes=()
    local cron_dest=""
    local cron_compress=false
    local cron_encrypt=false
    local cron_passphrase_file=""
    local cron_daily=7
    local cron_weekly=4
    local cron_monthly=3
    local hour="" minute="" value=""
    local command=("$SCRIPT_PATH" "--auto" "--no-color")
    local cron_line=""

    echo
    echo "Configure cron backup job"
    echo "Enter one source path per line. Submit an empty line when done."
    read_paths_into_array cron_sources "Source path: "
    if [[ ${#cron_sources[@]} -eq 0 ]]; then
        load_default_sources
        cron_sources=("${SOURCE_DIRS[@]}")
    fi

    while [[ -z "$cron_dest" ]]; do
        read -r -p "Destination directory: " cron_dest
    done

    if prompt_yes_no "Enable compression for cron runs? [Y/n]: " "y"; then
        cron_compress=true
    fi

    if prompt_yes_no "Add exclude patterns? [y/N]: " "n"; then
        echo "Enter one exclude pattern per line. Submit an empty line when done."
        read_paths_into_array cron_excludes "Exclude pattern: "
    fi

    if prompt_yes_no "Enable encryption for cron runs? [y/N]: " "n"; then
        cron_encrypt=true
        while [[ -z "$cron_passphrase_file" ]]; do
            read -r -p "Path to passphrase file: " cron_passphrase_file
        done
    fi

    read -r -p "Daily retention in days [7]: " value
    cron_daily="${value:-7}"
    read -r -p "Weekly retention in weeks [4]: " value
    cron_weekly="${value:-4}"
    read -r -p "Monthly retention in months [3]: " value
    cron_monthly="${value:-3}"

    while true; do
        read -r -p "Hour for daily backup [0-23]: " hour
        [[ "$hour" =~ ^([01]?[0-9]|2[0-3])$ ]] && break
        echo "Invalid hour."
    done

    while true; do
        read -r -p "Minute for daily backup [0-59]: " minute
        [[ "$minute" =~ ^([0-5]?[0-9])$ ]] && break
        echo "Invalid minute."
    done

    command+=("--dest" "$cron_dest" "--retention-daily" "$cron_daily" "--retention-weekly" "$cron_weekly" "--retention-monthly" "$cron_monthly")

    if [[ "$cron_compress" == true ]]; then
        command+=("--compress")
    fi

    if [[ "$cron_encrypt" == true ]]; then
        command+=("--encrypt" "--gpg-passphrase-file" "$cron_passphrase_file")
    fi

    for value in "${cron_sources[@]}"; do
        command+=("--source" "$value")
    done

    for value in "${cron_excludes[@]}"; do
        command+=("--exclude" "$value")
    done

    cron_line="${minute} ${hour} * * * $(build_shell_command "${command[@]}")"
    (crontab -l 2>/dev/null || true; printf '%s\n' "$cron_line") | crontab -
    log_msg INFO "Cron job added: $cron_line"
}

###############################################################################
# CLI parsing
###############################################################################
load_defaults_if_needed() {
    [[ ${#SOURCE_DIRS[@]} -gt 0 ]] && return 0
    load_default_sources
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                [[ -n "${2-}" ]] || die "--config requires a path."
                CONFIG_FILE="$2"
                WANT_PROFILE=true
                BACKUP_REQUESTED=true
                shift 2
                ;;
            --profile)
                [[ -n "${2-}" ]] || die "--profile requires a name."
                PROFILE_NAME="$2"
                WANT_PROFILE=true
                BACKUP_REQUESTED=true
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                BACKUP_REQUESTED=true
                shift
                ;;
            --source)
                [[ -n "${2-}" ]] || die "--source requires a path."
                SOURCE_DIRS+=("$2")
                CLI_SOURCE_SET=true
                BACKUP_REQUESTED=true
                shift 2
                ;;
            --dest)
                [[ -n "${2-}" ]] || die "--dest requires a directory."
                TARGET_DIR="$2"
                CLI_DEST_SET=true
                BACKUP_REQUESTED=true
                shift 2
                ;;
            --exclude)
                [[ -n "${2-}" ]] || die "--exclude requires a pattern."
                EXCLUDE_PATTERNS+=("$2")
                CLI_EXCLUDE_SET=true
                BACKUP_REQUESTED=true
                shift 2
                ;;
            --compress)
                COMPRESS=true
                CLI_COMPRESS_SET=true
                BACKUP_REQUESTED=true
                shift
                ;;
            --encrypt)
                ENCRYPT=true
                CLI_ENCRYPT_SET=true
                BACKUP_REQUESTED=true
                shift
                ;;
            --gpg-passphrase)
                [[ -n "${2-}" ]] || die "--gpg-passphrase requires a value."
                GPG_PASSPHRASE="$2"
                CLI_GPG_PASSPHRASE_SET=true
                BACKUP_REQUESTED=true
                shift 2
                ;;
            --gpg-passphrase-file)
                [[ -n "${2-}" ]] || die "--gpg-passphrase-file requires a path."
                GPG_PASSPHRASE_FILE="$2"
                CLI_GPG_PASSPHRASE_FILE_SET=true
                BACKUP_REQUESTED=true
                shift 2
                ;;
            --retention-daily)
                [[ -n "${2-}" ]] || die "--retention-daily requires a value."
                RETENTION_DAILY="$2"
                CLI_RETENTION_DAILY_SET=true
                BACKUP_REQUESTED=true
                shift 2
                ;;
            --retention-weekly)
                [[ -n "${2-}" ]] || die "--retention-weekly requires a value."
                RETENTION_WEEKLY="$2"
                CLI_RETENTION_WEEKLY_SET=true
                BACKUP_REQUESTED=true
                shift 2
                ;;
            --retention-monthly)
                [[ -n "${2-}" ]] || die "--retention-monthly requires a value."
                RETENTION_MONTHLY="$2"
                CLI_RETENTION_MONTHLY_SET=true
                BACKUP_REQUESTED=true
                shift 2
                ;;
            --auto)
                AUTO_MODE=true
                shift
                ;;
            -q|--quiet)
                QUIET=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            --no-color)
                NO_COLOR=true
                shift
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done
}

###############################################################################
# Interactive menu
###############################################################################
run_interactive_backup() {
    select_source_directories
    if [[ ${#SOURCE_DIRS[@]} -eq 0 ]]; then
        log_msg WARN "No sources selected. Backup canceled."
        return 0
    fi

    if ! select_target_directory; then
        log_msg WARN "No destination selected. Backup canceled."
        return 0
    fi

    prompt_backup_settings
    create_backup
}

main_menu() {
    local choice=""

    while true; do
        clear
        echo "========================================="
        echo "              Backup Script"
        echo "========================================="
        echo "1) Perform Backup"
        echo "2) Configure Automated Cron Job"
        echo "3) Quit"
        echo
        read -r -p "Enter your choice [1-3]: " choice

        case "$choice" in
            1)
                run_interactive_backup
                press_enter_to_continue
                ;;
            2)
                require_command crontab
                configure_cron_job
                press_enter_to_continue
                ;;
            3)
                echo "Goodbye."
                break
                ;;
            *)
                log_msg WARN "Invalid choice."
                press_enter_to_continue
                ;;
        esac
    done
}

###############################################################################
# Entry point
###############################################################################
parse_args "$@"

if [[ "$WANT_PROFILE" == true ]]; then
    resolve_config
    load_profile
fi

if [[ "$AUTO_MODE" == true || "$BACKUP_REQUESTED" == true ]]; then
    if [[ "$WANT_PROFILE" == true ]]; then
        check_profile_completeness
    else
        load_defaults_if_needed
    fi
    create_backup
    exit 0
fi

main_menu
