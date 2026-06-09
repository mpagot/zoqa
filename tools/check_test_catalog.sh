#!/usr/bin/env bash
#
# check_test_catalog.sh — enforce 3-letter prefix naming standards and catalog parity
#
# Enforces that:
#   1. Every test file `tests/e2e/tests_<suite>.sh` uses a 3-letter prefix derived
#      from its name, in the format `# <PREFIX>-<N>:`.
#   2. Every test execution line is covered by a preceding prefix comment.
#   3. Every declared prefix comment is matched bi-directionally with an entry in
#      `tests/e2e/TEST_CATALOG.md`.
#
# Usage:
#   ./tools/check_test_catalog.sh [file_name.sh]
#
# Exit codes:
#   0  — success (all checks pass)
#   1  — linter errors found
#   2  — usage or file access error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
CATALOG_FILE="$REPO_ROOT/tests/e2e/TEST_CATALOG.md"

# Used later to load catalog mapping into a associative arrays
# catalog_entries["file_name:id"]="line_num"
# files_in_catalog["file_name"]=1
declare -A catalog_entries
declare -A files_in_catalog

# Derive expected prefix from a tests_*.sh filename
# e.g., tests_archive.sh -> ARC
derive_prefix() {
    local filename
    filename=$(basename "$1")
    local rest="${filename#tests_}"
    local first3="${rest:0:3}"
    echo "${first3^^}"
}

# Parse catalog using standard POSIX awk to extract section tables and their IDs.
# Outputs lines format: <filename>:<line_number>:<ID>
parse_catalog() {
    local catalog="$1"
    awk '
    BEGIN {
        FS = "|"
        current_file = ""
        in_table = 0
    }
    /^### / {
        current_file = ""
        in_table = 0
        start_paren = index($0, "(")
        if (start_paren > 0) {
            sub_str = substr($0, start_paren + 1)
            end_paren = index(sub_str, ")")
            if (end_paren > 0) {
                file_part = substr(sub_str, 1, end_paren - 1)
                gsub(/`/, "", file_part)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", file_part)
                if (file_part ~ /\.sh$/) {
                    current_file = file_part
                }
            }
        }
        next
    }
    current_file != "" {
        if ($0 ~ /^[[:space:]]*\|/) {
            if ($0 ~ /^[[:space:]]*\|[[:space:]]*:?-+/) {
                in_table = 1
                next
            }
            if (in_table) {
                id = $2
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", id)
                if (id != "" && id != "#" && id != "ID" && id != "Test" && id !~ /^[[:space:]]*-+[[:space:]]*$/) {
                    print current_file ":" NR ":" id
                }
            }
        } else {
            in_table = 0
        }
    }
    ' "$catalog"
}

# Helper function to lint a single test file
check_test_file() {
    local file="$1"
    local filename
    filename=$(basename "$file")
    local expected_prefix
    expected_prefix=$(derive_prefix "$filename")

    # Verify file is registered in the catalog
    if [[ -z "${files_in_catalog["$filename"]:-}" ]]; then
        echo "$CATALOG_FILE:1: error: No section header found for '$filename' (expected '### ... ($filename)')."
        return 1
    fi

    # Read file lines
    local -a lines
    if ! mapfile -t lines < "$file"; then
        echo "error: Failed to read file $file" >&2
        return 2
    fi

    # Track declared prefixes in this file
    local -A declared_prefixes
    local file_errors=0
    local i
    for i in "${!lines[@]}"; do
        local line="${lines[$i]}"
        local line_num=$((i + 1))

        #if [[ "$line" =~ ^[[:space:]]*#[[:space:]]*Test[[:space:]]([A-Z]{3}-[0-9]+[a-z]?): ]]; then
        #    echo "[DEBUG] File $file line:$line_num '$line' MATCH1"
        #else
        #    echo "[DEBUG] File $file line:$line_num '$line' NO MATCH1"
        #fi

        # Check if this line is a prefix comment
        if [[ "$line" =~ ^[[:space:]]*#[[:space:]]*Test[[:space:]]([A-Z]{3}-[0-9]+[a-z]?): ]]; then
            local prefix_id="${BASH_REMATCH[1]}"
            local prefix_part="${prefix_id%%-*}"
            
            if [[ "$prefix_part" != "$expected_prefix" ]]; then
                echo "$file:$line_num: error: Incorrect prefix '$prefix_part' (expected '$expected_prefix' for '$filename')."
                file_errors=1
            fi
            #echo "[DEBUG] File $file line:$line_num '$line' has prefix '$prefix_id'"
            declared_prefixes["$prefix_id"]="$line_num"
        #else
            #echo "[DEBUG] File $file line:$line_num '$line' has NO prefix"
        fi

        # Check if this line is a test execution
        if [[ "$line" =~ ^[[:space:]]*(run_test|run_comparison|run_diff_test|run_capture|run_capture_both)\b ]]; then
            local found_prefix=""
            local j
            # Scan backward up to 40 lines
            for ((j=i-1; j>=0 && j>=i-40; j--)); do
                local prev_line="${lines[$j]}"
                if [[ "$prev_line" =~ ^[[:space:]]*#[[:space:]]*([A-Z]{3}-[0-9]+): ]]; then
                    found_prefix="${BASH_REMATCH[1]}"
                    break
                fi
            done
            
            if [[ -n "$found_prefix" ]]; then
                local found_prefix_part="${found_prefix%%-*}"
                if [[ "$found_prefix_part" != "$expected_prefix" ]]; then
                    echo "$file:$line_num: error: Test execution covered by prefix '$found_prefix_part' instead of expected '$expected_prefix'."
                    file_errors=1
                fi
            else
                echo "$file:$line_num: error: Test execution has no preceding prefix comment (expected '$expected_prefix-N:')."
                file_errors=1
            fi
        fi
    done
    
    # Rule 1 Parity Check
    
    # Check for Orphan Catalog Entries (present in catalog, missing in code)
    local key
    for key in "${!catalog_entries[@]}"; do
        local file_part="${key%%:*}"
        local id_part="${key#*:}"
        
        if [[ "$file_part" == "$filename" ]]; then
            if [[ -z "${declared_prefixes["$id_part"]:-}" ]]; then
                local catalog_line="${catalog_entries["$key"]}"
                echo "$CATALOG_FILE:$catalog_line: error: Catalog entry '$id_part' has no matching test case in '$filename'."
                file_errors=1
            fi
        fi
    done
    
    # Check for Orphan Test Cases (present in code, missing in catalog)
    local dec_id
    for dec_id in "${!declared_prefixes[@]}"; do
        if [[ -z "${catalog_entries["$filename:$dec_id"]:-}" ]]; then
            local dec_line="${declared_prefixes["$dec_id"]}"
            echo "$file:$dec_line: error: Test case '$dec_id' has no corresponding entry in '$CATALOG_FILE'."
            file_errors=1
        fi
    done
    
    return "$file_errors"
}

###########################################################################

if [[ ! -f "$CATALOG_FILE" ]]; then
    echo "error: Catalog file not found at $CATALOG_FILE" >&2
    exit 2
fi

# Collect target files
FILES_TO_CHECK=()
SPECIFIC_FILE=""

# TODO -gt 0 is maybe fragile if script is extended
if [[ $# -gt 0 ]]; then
    SPECIFIC_FILE="$(basename "$1")"
    if [[ ! "$SPECIFIC_FILE" =~ ^tests_.*\.sh$ ]]; then
        echo "error: Target file must match tests_*.sh pattern (got '$SPECIFIC_FILE')" >&2
        exit 2
    fi
    target_path="$REPO_ROOT/tests/e2e/$SPECIFIC_FILE"
    if [[ ! -f "$target_path" ]]; then
        echo "error: File not found at $target_path" >&2
        exit 2
    fi
    FILES_TO_CHECK+=("$target_path")
else
    # Scan all test files in e2e
    for f in "$REPO_ROOT"/tests/e2e/tests_*.sh; do
        if [[ -f "$f" ]]; then
            FILES_TO_CHECK+=("$f")
        fi
    done
fi

while IFS= read -r line; do
    if [[ -n "$line" ]]; then
        file_name="${line%%:*}"
        rest="${line#*:}"
        line_num="${rest%%:*}"
        id="${rest#*:}"
        catalog_entries["$file_name:$id"]="$line_num"
        files_in_catalog["$file_name"]=1
    fi
done < <(parse_catalog "$CATALOG_FILE")

overall_errors=0

for file in "${FILES_TO_CHECK[@]}"; do
    if ! check_test_file "$file"; then
        overall_errors=1
    fi
done

if [[ $overall_errors -ne 0 ]]; then
    exit 1
fi

echo "OK — all checks passed."
exit 0
