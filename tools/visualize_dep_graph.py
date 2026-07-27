#!/usr/bin/env python3
"""visualize_dep_graph.py : Generate Graphviz .dot file of public function usage in Zig files.

Scans all *.zig files in the source directory (default: src/), extracts public
functions, finds their usages in other files, and counts lines (total, comments, code).
Generates a Graphviz dependency graph where:
  - Each file is represented by a rectangle.
  - Node height is proportional to the total number of lines in that file.
  - Arrows are drawn from the implementing file to the calling file for each
    public function invocation.

Usage:
  ./tools/visualize_dep_graph.py [options]

Options:
  --src-dir DIR       Source directory to scan (default: src)
  --output FILE       Path to write the Graphviz .dot file (default: dependency_graph.dot)
  --scale FLOAT       Height scale factor per line of code (default: 0.005)
  --include-common    Include common method names like init/deinit (default: False)
"""

import argparse
import re
import sys
from pathlib import Path

# Regex to match pub fn or export fn declarations
PUB_FN_RE = re.compile(
    r'^\s*(?:pub|export)\s+(?:(?:inline|noinline)\s+)*fn\s+([A-Za-z0-9_]+)\b'
)

# Common/generic function names that can clutter the graph
COMMON_FUNCTIONS = {
    "init",
    "deinit",
    "next",
    "request",
    "reader",
    "format",
    "print",
    "deinit_self",
    "main",
    "iterateHeaders",
    "streamRemaining",
    "sendBodiless",
    "sendBodyComplete",
    "receiveHead"
}


def strip_comment(line: str) -> str:
    """Strips comments from a Zig line, preserving string content safely."""
    if '//' not in line:
        return line
    in_string = False
    in_char = False
    escape = False
    for i, c in enumerate(line):
        if escape:
            escape = False
            continue
        if c == '\\':
            escape = True
            continue
        if c == '"' and not in_char:
            in_string = not in_string
        elif c == "'" and not in_string:
            in_char = not in_char
        elif c == '/' and not in_string and not in_char:
            if i + 1 < len(line) and line[i+1] == '/':
                return line[:i]
    return line


def parse_zig_file(file_path: Path) -> dict:
    """Parses a zig file to count lines, find pub functions, and clean code."""
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except Exception as e:
        print("Error reading file %s: %s" % (file_path, e), file=sys.stderr)
        sys.exit(1)

    total_lines = len(lines)
    comment_lines = 0
    code_lines = 0
    pub_functions = []
    clean_lines = []

    for line in lines:
        stripped = line.strip()
        if not stripped:
            clean_lines.append("")
            continue

        # Strip comment from the line
        code_part = strip_comment(line)
        
        # If any comment was removed, count it as a comment line
        if len(code_part) < len(line):
            comment_lines += 1
            
        # If the line contains non-comment code, count it as a code line
        if code_part.strip():
            code_lines += 1
            clean_lines.append(code_part)
        else:
            clean_lines.append("")

        # Match pub/export function declaration
        match = PUB_FN_RE.match(line)
        if match:
            pub_functions.append(match.group(1))

    return {
        "total_lines": total_lines,
        "comment_lines": comment_lines,
        "code_lines": code_lines,
        "pub_functions": pub_functions,
        "clean_lines": clean_lines
    }


def main():
    parser = argparse.ArgumentParser(
        description="Generate Graphviz .dot file of Zig public function dependency graph."
    )
    parser.add_argument(
        "--src-dir",
        type=str,
        default="src",
        help="Source directory containing zig files (default: src)"
    )
    parser.add_argument(
        "--output",
        type=str,
        default="dependency_graph.dot",
        help="Output Graphviz file path (default: dependency_graph.dot)"
    )
    parser.add_argument(
        "--scale",
        type=float,
        default=0.005,
        help="Height scale factor per total line of the file (default: 0.005)"
    )
    parser.add_argument(
        "--include-common",
        action="store_true",
        help="Include common/generic function names (e.g. init, deinit, next) in dependencies"
    )

    args = parser.parse_args()

    src_path = Path(args.src_dir)
    if not src_path.is_dir():
        print("Error: Source directory '%s' does not exist." % args.src_dir, file=sys.stderr)
        sys.exit(1)

    zig_files = sorted(list(src_path.rglob("*.zig")))
    if not zig_files:
        print("No .zig files found in '%s'." % args.src_dir, file=sys.stderr)
        sys.exit(0)

    # 1. Parse all zig files
    file_data = {}
    for fp in zig_files:
        rel_path = fp.relative_to(src_path.parent)
        file_data[str(rel_path)] = parse_zig_file(fp)

    # 2. Build dependency connections
    edges = []
    
    # Palette of distinct professional colors for edges from the same node
    EDGE_PALETTE = [
        "#1f77b4",  # Blue
        "#ff7f0e",  # Orange
        "#2ca02c",  # Green
        "#d62728",  # Red
        "#9467bd",  # Purple
        "#8c564b",  # Brown
        "#e377c2",  # Pink
        "#7f7f7f",  # Gray
        "#bcbd22",  # Olive
        "#17becf",  # Cyan
        "#34495e",  # Navy
        "#27ae60",  # Emerald
        "#8e44ad",  # Amethyst
        "#f39c12",  # Yellow/Orange
        "#d35400",  # Rust
    ]

    # Map each (defining_file, function_name) to a unique color from the palette
    fn_colors = {}
    for def_file, data in file_data.items():
        color_idx = 0
        for fn_name in data["pub_functions"]:
            if not args.include_common and fn_name in COMMON_FUNCTIONS:
                continue
            # Each function gets its own color in the context of this defining file
            fn_colors[(def_file, fn_name)] = EDGE_PALETTE[color_idx % len(EDGE_PALETTE)]
            color_idx += 1

    for def_file, data in file_data.items():
        for fn_name in data["pub_functions"]:
            # Optionally skip common functions to keep graph high-signal
            if not args.include_common and fn_name in COMMON_FUNCTIONS:
                continue

            color = fn_colors.get((def_file, fn_name), "#7f8c8d")

            # Look for occurrences in other files
            pattern = re.compile(r'\b' + re.escape(fn_name) + r'\b')
            for caller_file, other_data in file_data.items():
                if caller_file == def_file:
                    continue

                # Count matches in other file's clean code lines
                count = 0
                for line in other_data["clean_lines"]:
                    count += len(pattern.findall(line))

                # Add an edge for each call along with its specific color
                for _ in range(count):
                    edges.append((def_file, caller_file, fn_name, color))

    # 3. Write the .dot file
    try:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write("digraph dependency_graph {\n")
            f.write("    // Graph settings\n")
            f.write("    rankdir=LR;\n")
            f.write("    splines=true;\n")
            f.write("    overlap=false;\n")
            f.write("    nodesep=0.4;\n")
            f.write("    ranksep=1.2;\n\n")

            f.write("    // Node style defaults\n")
            f.write('    node [shape=plain, width=0, height=0, margin=0, fontname="Helvetica,Arial,sans-serif", fontsize=10];\n\n')

            f.write("    // Node definitions\n")
            for rel_path, data in file_data.items():
                total = data["total_lines"]
                comments = data["comment_lines"]
                code = data["code_lines"]
                
                # Height calculation proportional to total lines
                height = max(0.8, total * args.scale)
                total_points = int(height * 72)
                
                # Calculate ratio of code vs comment lines (or default if 0)
                if code + comments > 0:
                    code_ratio = code / (code + comments)
                    comment_ratio = comments / (code + comments)
                else:
                    code_ratio = 1.0
                    comment_ratio = 0.0
                    
                code_points = int(code_ratio * total_points)
                comment_points = total_points - code_points
                
                # Safety checks to prevent squishing text in very small/large files
                min_code_height = 55
                min_comment_height = 25
                
                if code_points < min_code_height:
                    code_points = min_code_height
                if comment_points < min_comment_height and comments > 0:
                    comment_points = min_comment_height
                    
                total_points = code_points + comment_points
                
                # Build HTML table label representing split layout with fixedsize forcing
                # BGCOLOR "#d6eaf8" is soft light blue for code, "#e2f0d9" is soft light green for comments
                html_label = (
                    '<<TABLE BORDER="0" CELLBORDER="1" CELLSPACING="0" CELLPADDING="4" fixedsize="true" width="180" height="%d">\n'
                    '      <TR><TD BGCOLOR="#d6eaf8" fixedsize="true" width="180" height="%d" ALIGN="CENTER" VALIGN="MIDDLE">\n'
                    '        <B>%s</B><BR/>\n'
                    '        <FONT POINT-SIZE="9">Lines: %d<BR/>Code: %d</FONT>\n'
                    '      </TD></TR>\n'
                ) % (total_points, code_points, rel_path, total, code)
                
                if comments > 0:
                    html_label += (
                        '      <TR><TD BGCOLOR="#e2f0d9" fixedsize="true" width="180" height="%d" ALIGN="CENTER" VALIGN="MIDDLE">\n'
                        '        <FONT POINT-SIZE="9">Comments: %d</FONT>\n'
                        '      </TD></TR>\n'
                    ) % (comment_points, comments)
                
                html_label += '    </TABLE>>'
                
                f.write(f'    "{rel_path}" [label={html_label}];\n')

            f.write("\n    // Edge definitions\n")
            for src, dest, fn, color in edges:
                f.write(f'    "{src}" -> "{dest}" [label="{fn}", color="{color}", fontname="Courier", fontsize=8];\n')

            f.write("}\n")
        print("Successfully generated dependency graph dot file: %s" % args.output)
    except Exception as e:
        print("Error writing output file: %s" % e, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
