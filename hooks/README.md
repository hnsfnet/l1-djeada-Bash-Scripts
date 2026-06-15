# Hooks

This directory contains scripts that can be used as pre-commit hooks or CI checks to maintain code quality in the repository.

## Overview

The hooks are designed to automatically check and fix common issues in bash scripts, such as:
- Removing carriage return characters (Windows line endings)
- Ensuring files end with exactly one empty line
- Removing trailing whitespaces
- Formatting and linting bash scripts

## Usage

### Running All Hooks

`_run_all.sh` is the batch entrypoint. In its simplest form it runs every hook
in check mode (without modifying files) against the repository's `src`
directory:

```bash
./hooks/_run_all.sh
```

It prints a per-hook summary at the end and exits non-zero if anything failed.

#### Choosing which paths to check

Any positional arguments are treated as the files or directories to check, so
you are no longer limited to `src`:

```bash
# Check a couple of specific directories
./hooks/_run_all.sh src tests

# Check a single file
./hooks/_run_all.sh src/backup.sh
```

When no path is given it defaults to the repository's `src` directory.

#### Selecting or excluding hooks

Use `--include` to run only certain hooks, or `--exclude` to skip some (for
example, the slower `beautify_script`). Both accept a comma-separated list
and/or can be repeated, and names may be written with or without the `.sh`
suffix:

```bash
# Only run the two fast whitespace checks
./hooks/_run_all.sh --include remove_trailing_whitespaces,remove_carriage_return src

# Run everything except the (slower) beautify hook
./hooks/_run_all.sh --exclude beautify_script src

# List the hooks that are available to include/exclude
./hooks/_run_all.sh --list
```

Run `./hooks/_run_all.sh --help` for the full option list.

#### Exit codes

| Code | Meaning                                                        |
|------|----------------------------------------------------------------|
| `0`  | All selected checks passed on all paths.                       |
| `1`  | At least one check failed.                                     |
| `2`  | Usage error (unknown option, no matching hooks, invalid path). |

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

These hooks are automatically run in the CI pipeline (see `.github/workflows/blank.yml`). The CI will fail if any checks don't pass.

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

The scripts in this directory are symbolic links to the corresponding scripts in the `src` directory. This allows the same scripts to be used both as utility scripts and as hooks.

The `_run_all.sh` script:
1. Discovers every hook in this directory (the `*.sh` entries that do **not** start with `_`)
2. Resolves each one to the real script under `src` (following the symlink, or mapping `hooks/<name>.sh` to `src/<name>.sh` when the repository was checked out without symlink support), so it behaves the same locally and in CI
3. Runs each selected hook with the `--check` flag against each requested path
4. Prints a summary of which hooks ran, which checks failed, and the overall result
5. Exits `0` when everything passed, `1` when a check failed, or `2` on a usage error

## Troubleshooting

If a hook fails in CI or locally:

1. Read the error message to understand which check failed
2. Run the specific hook without `--check` to automatically fix the issue:
   ```bash
   ./hooks/<hook_name>.sh src
   ```
3. Commit the changes and try again

## Note

All hooks respect the `--check` flag. When used with `--check`, they will only report issues without modifying files. Without this flag, they will automatically fix the issues.
