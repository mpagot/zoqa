#!/usr/bin/env python3
"""check_docstrings.py — validate docstring completeness for Zig fn declarations.

Scans all *.zig files under src/ and checks that every fn declaration has a
doc comment (///) with:

  - A summary line (at least one non-empty /// line directly above the fn)
  - An `Arguments:` section when the function has non-self, non-underscore params
  - A `Returns:` section when the return type is not void or noreturn
  - An `Errors:` section when the return type is an error union (starts with `!`)

Doc comments must be a *contiguous* block of `///` lines immediately above the
`fn` declaration — no blank lines or `//` non-doc comments between the comment
block and the `fn` keyword.

Usage:
  ./tools/check_docstrings.py [--with-private] [--with-deinit] [REPO_ROOT]

  --with-private  Also check private (non-pub, non-export) functions.
  --with-deinit   Also check deinit functions (skipped by default).
  REPO_ROOT       Repository root (default: parent of the tools/ directory).

Exit codes:
  0  all checked functions have complete docstrings
  1  one or more violations found
  2  usage error
"""

import argparse
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Regex patterns
# ---------------------------------------------------------------------------

# Matches any fn declaration (pub/export/noinline/inline prefixes optional).
_FN_RE = re.compile(r"^\s*(?:(?:pub|export|noinline|inline)\s+)*fn\s+(\w+)\s*\(")

# Matches only pub fn / export fn declarations.
_PUB_FN_RE = re.compile(
    r"^\s*(?:pub|export)\s+(?:(?:noinline|inline)\s+)*fn\s+(\w+)\s*\("
)

# Matches a test block start at column 0 (test "name" {, test {, test identifier {).
_TEST_START_RE = re.compile(r'^test[\s"({]')

# Matches a closing brace at column 0.
_CLOSE_BRACE_RE = re.compile(r"^\}")

# Strips callconv(...) from a return-type candidate.
# callconv arguments are always simple enum literals (.C, .SysV, …) — no nested parens.
_CALLCONV_RE = re.compile(r"\bcallconv\s*\([^)]*\)\s*")


# ---------------------------------------------------------------------------
# Test-zone tracking
# ---------------------------------------------------------------------------


def find_test_zones(lines: list[str]) -> set[int]:
    """Return the set of 0-indexed line numbers that fall inside test blocks.

    A zone starts at a line matching ``^test[\\s"({]`` at column 0 and ends
    at the first ``}`` that appears at column 0.  This intentionally avoids
    brace counting (which would be confused by ``}`` inside string literals)
    at the cost of being misled by a ``}`` at column 0 that is *not* the
    test close — a pattern that does not occur in this codebase.

    Struct methods or helper functions defined inside test blocks are
    therefore also skipped, which is the desired behaviour.
    """
    in_test = False
    zones: set[int] = set()

    for i, line in enumerate(lines):
        if not in_test:
            if _TEST_START_RE.match(line):
                in_test = True
                zones.add(i)
        else:
            zones.add(i)
            if _CLOSE_BRACE_RE.match(line):
                in_test = False

    return zones


# ---------------------------------------------------------------------------
# Signature collection and parsing
# ---------------------------------------------------------------------------


def collect_signature(lines: list[str], fn_idx: int) -> str:
    """Collect the full fn signature as a single space-joined string.

    Accumulates source lines starting from *fn_idx* until the opening ``{``
    of the function body is found at paren-depth 0 (i.e. after the param
    list has closed).

    Known limitation: anonymous struct return types containing ``{`` (e.g.
    ``fn foo() struct { x: i32 } {``) would cause an early stop — not
    present in this codebase.
    """
    parts: list[str] = []
    paren_depth = 0
    past_params = False  # True once the param-list ``(…)`` has fully closed

    for line in lines[fn_idx:]:
        parts.append(line.rstrip())
        for ch in line:
            if ch == "(":
                paren_depth += 1
            elif ch == ")":
                paren_depth -= 1
                if paren_depth == 0:
                    past_params = True
            elif ch == "{" and past_params and paren_depth == 0:
                return " ".join(parts)

    return " ".join(parts)


def _split_at_depth0_commas(param_str: str) -> list[str]:
    """Split *param_str* by commas that appear at paren/bracket/brace depth 0."""
    params: list[str] = []
    current: list[str] = []
    depth = 0

    for ch in param_str:
        if ch in "([{":
            depth += 1
            current.append(ch)
        elif ch in ")]}":
            depth -= 1
            current.append(ch)
        elif ch == "," and depth == 0:
            params.append("".join(current).strip())
            current = []
        else:
            current.append(ch)

    tail = "".join(current).strip()
    if tail:
        params.append(tail)

    return params


def extract_params(signature: str) -> list[str]:
    """Return the list of parameter *names* found in *signature*.

    Rules:
    - ``self`` and ``_`` are skipped.
    - A leading ``comptime`` keyword is stripped from the parameter token.
    - Parameters without a ``:`` separator (positional type-only params) are
      skipped.
    - ``anytype`` parameters still have a name before the ``:``.
    """
    start = signature.find("(")
    if start == -1:
        return []

    # Find the matching closing paren.
    depth = 0
    end = -1
    for i, ch in enumerate(signature[start:], start):
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                end = i
                break

    if end == -1:
        return []

    raw_params = _split_at_depth0_commas(signature[start + 1 : end])
    names: list[str] = []

    for param in raw_params:
        param = param.strip()
        if not param:
            continue

        # Strip leading ``comptime`` modifier.
        if param.startswith("comptime "):
            param = param[len("comptime "):]

        colon_idx = param.find(":")
        if colon_idx == -1:
            # No colon — positional type-only param; skip.
            continue

        name = param[:colon_idx].strip()
        if not name or name in ("self", "_"):
            continue

        names.append(name)

    return names


def extract_return_type(signature: str) -> str:
    """Return the return-type portion of *signature* as a stripped string.

    Strips ``callconv(…)`` annotations.  Returns an empty string when the
    return type cannot be determined.
    """
    start = signature.find("(")
    if start == -1:
        return ""

    # Locate the matching closing paren.
    depth = 0
    end = -1
    for i, ch in enumerate(signature[start:], start):
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                end = i
                break

    if end == -1:
        return ""

    after_params = signature[end + 1:]

    # Remove callconv(…).
    after_params = _CALLCONV_RE.sub("", after_params)

    # Trim at the first ``{`` at paren-depth 0 (the function-body brace).
    depth = 0
    ret_end = len(after_params)
    for i, ch in enumerate(after_params):
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif ch == "{" and depth == 0:
            ret_end = i
            break

    return after_params[:ret_end].strip()


# ---------------------------------------------------------------------------
# Doc-comment extraction and validation
# ---------------------------------------------------------------------------


def collect_doc_comments(lines: list[str], fn_idx: int) -> list[str]:
    """Return the contiguous ``///`` block immediately above *fn_idx*.

    Walks backward from ``fn_idx - 1``, stopping at the first line that is
    *not* a ``///`` comment (blank lines and ``//`` non-doc comments both
    stop the walk).  Returns the collected lines in top-to-bottom order,
    each with its leading ``///`` prefix removed.
    """
    doc_lines: list[str] = []
    i = fn_idx - 1

    while i >= 0:
        stripped = lines[i].lstrip()
        if stripped.startswith("///"):
            doc_lines.insert(0, stripped[3:])  # strip the `///` prefix
        else:
            break
        i -= 1

    return doc_lines


def check_docstring(
    doc_lines: list[str],
    param_names: list[str],
    return_type: str,
) -> list[str]:
    """Return a list of missing-section descriptions for the function.

    An empty list means the docstring is complete.
    """
    missing: list[str] = []

    # Summary: at least one non-empty doc line is required.
    has_summary = any(line.strip() for line in doc_lines)
    if not has_summary:
        missing.append("missing summary")
        # No point checking sections when there is no doc comment at all.
        return missing

    doc_text = "\n".join(doc_lines)

    # Arguments: required when there are non-self/non-underscore params.
    if param_names:
        if not re.search(r"^\s*Arguments?:", doc_text, re.MULTILINE):
            missing.append("missing Arguments section")

    # Analyse return type.
    has_error_union = return_type.startswith("!")
    base_type = return_type.lstrip("!").strip()

    # Returns: required unless the base type is void, noreturn, or absent.
    if base_type not in ("void", "noreturn", ""):
        if not re.search(r"^\s*Returns?:", doc_text, re.MULTILINE):
            missing.append("missing Returns section")

    # Errors: required for error-union return types.
    if has_error_union:
        if not re.search(r"^\s*Errors?:", doc_text, re.MULTILINE):
            missing.append("missing Errors section")

    return missing


# ---------------------------------------------------------------------------
# Per-file checker
# ---------------------------------------------------------------------------


def check_file(
    path: Path, with_private: bool = False, with_deinit: bool = False
) -> list[tuple[int, str, list[str]]]:
    """Check one Zig source file.

    Returns a list of ``(line_number, fn_name, [issues])`` tuples, one per
    function that has at least one docstring issue.  *line_number* is
    1-indexed.
    """
    violations: list[tuple[int, str, list[str]]] = []
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)

    test_zones = find_test_zones(lines)
    fn_re = _FN_RE if with_private else _PUB_FN_RE

    for i, line in enumerate(lines):
        if i in test_zones:
            continue

        m = fn_re.match(line)
        if not m:
            continue

        fn_name = m.group(1)
        fn_line_num = i + 1  # convert to 1-indexed

        # Skip deinit functions unless explicitly requested.
        if fn_name == "deinit" and not with_deinit:
            continue

        signature = collect_signature(lines, i)
        param_names = extract_params(signature)
        return_type = extract_return_type(signature)
        doc_lines = collect_doc_comments(lines, i)

        issues = check_docstring(doc_lines, param_names, return_type)
        if issues:
            violations.append((fn_line_num, fn_name, issues))

    return violations


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate docstring completeness for fn declarations in src/*.zig",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
Exit codes:
  0  all checked functions have complete docstrings
  1  one or more violations found
  2  usage error""",
    )
    parser.add_argument(
        "--with-private",
        action="store_true",
        help="Also check private (non-pub, non-export) functions",
    )
    parser.add_argument(
        "--with-deinit",
        action="store_true",
        help="Also check deinit functions (skipped by default)",
    )
    parser.add_argument(
        "repo_root",
        nargs="?",
        default=None,
        help="Repository root (default: parent of the tools/ directory)",
    )
    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent
    repo_root = (
        Path(args.repo_root).resolve() if args.repo_root else script_dir.parent
    )

    src_dir = repo_root / "src"
    if not src_dir.is_dir():
        print(f"error: {src_dir} not found", file=sys.stderr)
        return 2

    zig_files = sorted(src_dir.glob("*.zig"))
    if not zig_files:
        print(f"error: no *.zig files found in {src_dir}", file=sys.stderr)
        return 2

    total_violations = 0

    for zig_file in zig_files:
        rel = zig_file.relative_to(repo_root)
        for line_num, fn_name, issues in check_file(
            zig_file,
            with_private=args.with_private,
            with_deinit=args.with_deinit,
        ):
            for issue in issues:
                print(f"{rel}:{line_num}: {fn_name}: {issue}")
            total_violations += len(issues)

    if total_violations == 0:
        print("OK — all checked functions have complete docstrings.")
        return 0

    print(f"\nFAIL — {total_violations} docstring violation(s) found.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
