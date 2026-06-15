# Hooks

This directory contains scripts that can be used as pre-commit hooks or CI checks to maintain code quality in the repository.

## Overview

The hooks are designed to automatically check and fix common issues in bash scripts, such as:
- Removing carriage return characters (Windows line endings)
- Ensuring files end with exactly one empty line
- Removing trailing whitespaces
- Formatting and linting bash scripts

## Usage

### Running All Hooks (Batch Runner)

The recommended way to run hooks is through the batch entry point `_run_all.sh`:

```bash
# Default: check all hooks against src/
./hooks/_run_all.sh

# Check specific directories
./hooks/_run_all.sh src hooks

# Check a single file
./hooks/_run_all.sh src/my_script.sh

# Only run specific hooks
./hooks/_run_all.sh --include last_line_empty,remove_carriage_return

# Exclude slow hooks
./hooks/_run_all.sh --exclude beautify_script

# Combine filters and custom paths
./hooks/_run_all.sh --include remove_trailing_whitespaces --exclude beautify_script -- src hooks
```

#### Options

| Flag | Description |
|------|-------------|
| `-h`, `--help` | Show help message and exit |
| `-p`, `--paths PATH ...` | One or more paths to check (can also be positional args) |
| `-i`, `--include HOOK ...` | Only run these hooks (comma or space separated names) |
| `-e`, `--exclude HOOK ...` | Skip these hooks (comma or space separated names) |

Hook names can be given with or without the `.sh` suffix (e.g. `last_line_empty` or `last_line_empty.sh`).

#### Summary Output

At the end of each run, `_run_all.sh` prints a summary table showing:
- How many checks ran in total
- Which hook/path combinations passed
- Which hook/path combinations failed (if any)
- Which hooks were skipped due to filters
- Overall pass/fail status

The script exits with code 0 if all checks passed, 1 if any failed, or 2 on usage errors.

### Running Individual Hooks

Each hook can be run individually with the following syntax:

```bash
./hooks/<hook_name>.sh [--check] <path>
```

- `--check`: Only check if changes are needed, do not modify files
- `<path>`: File or directory to process

**Examples:**

```bash
# Check a single file for carriage returns
./hooks/remove_carriage_return.sh --check src/my_script.sh

# Remove trailing whitespaces from all files in src directory
./hooks/remove_trailing_whitespaces.sh src

# Check if all files end with exactly one empty line
./hooks/last_line_empty.sh --check src
```

## Available Hooks

### beautify_script.sh
Formats shell scripts using Beautysh and analyzes them with ShellCheck.

**Requirements:**
- `beautysh` - Install with `pip3 install beautysh`
- `shellcheck` - Install with `apt-get install shellcheck` (Debian/Ubuntu)

### remove_carriage_return.sh
Removes carriage return characters (`\r`) from files. This is useful for files that may have been edited on Windows systems.

### last_line_empty.sh
Ensures that all files end with exactly one empty line. This is a common convention in many projects.

### remove_trailing_whitespaces.sh
Removes trailing whitespace characters (spaces or tabs) from the end of lines in files.

## Integration

### CI/CD Integration

These hooks are automatically run in the CI pipeline (see `.github/workflows/blank.yml`). The CI uses the same `_run_all.sh` entry point with the same defaults as local development, so CI and local behaviour are consistent. The CI will fail if any checks don't pass.

### Git Pre-commit Hook (Optional)

To run these checks before every commit, you can create a git pre-commit hook:

```bash
cat > .git/hooks/pre-commit << 'EOF'
#!/usr/bin/env bash
./hooks/_run_all.sh
EOF
chmod +x .git/hooks/pre-commit
```

This will automatically run all hooks before each commit. If any checks fail, the commit will be aborted.

## How It Works

The scripts in this directory are thin wrappers that delegate to the corresponding scripts in the `src` directory. This allows the same scripts to be used both as utility scripts and as hooks.

The `_run_all.sh` script:
1. Discovers all executable hook scripts in the `hooks` directory (excluding files starting with `_`)
2. Applies `--include` / `--exclude` filters if given
3. Executes each selected script with the `--check` flag against every specified path
4. Prints a pass/fail summary at the end
5. Exits with status 1 if any check failed, 0 otherwise

## Troubleshooting

If a hook fails in CI or locally:

1. Read the summary output to see which check(s) failed
2. Run the specific hook without `--check` to automatically fix the issue:
   ```bash
   ./hooks/<hook_name>.sh src
   ```
3. Commit the changes and try again

## Note

All hooks respect the `--check` flag. When used with `--check`, they will only report issues without modifying files. Without this flag, they will automatically fix the issues.
