#!/usr/bin/env python3
"""Engine inventory script for eGlu.

Measures and reports dependencies on WebKit and Engines in the Mac app,
Shared code, tests, and page scripts.
"""

import argparse
import collections
import datetime
import os
from pathlib import Path
import re
import sys

# Directories to skip when scanning files.
SKIP_DIRS = {
    ".build",
    "build",
    "DerivedData",
    ".git",
    ".claude",
    ".gstack",
    "node_modules",
    "eGlu.xcodeproj",
}

# A single inventory finding.
Finding = collections.namedtuple(
    "Finding", ["path", "line_number", "line_text", "detail"], defaults=[""]
)


def strip_comments_from_line(line: str, in_block: bool) -> tuple[str, bool]:
    """Strip single-line and multi-line comments from a line of code."""
    i = 0
    n = len(line)
    result = []
    while i < n:
        if in_block:
            if i + 1 < n and line[i : i + 2] == "*/":
                in_block = False
                i += 2
            else:
                i += 1
            continue

        # Preserve string literals so comment characters inside quotes are kept.
        if line[i] == '"':
            start = i
            i += 1
            while i < n and line[i] != '"':
                if line[i] == "\\" and i + 1 < n:
                    i += 2
                else:
                    i += 1
            if i < n and line[i] == '"':
                i += 1
            result.append(line[start:i])
            continue

        if i + 1 < n and line[i : i + 2] == "//":
            break
        if i + 1 < n and line[i : i + 2] == "/*":
            in_block = True
            i += 2
            continue

        result.append(line[i])
        i += 1

    return "".join(result), in_block


# Section a: import WebKit and import Engines lines.
IMPORT_RE = re.compile(r"^\s*(?:@\w+\s+)*import\s+(WebKit|Engines)\b")

# The WebKit plugin's own modules. The Mac app reaches them in one file only,
# its composition point, which a build of the app with another engine swaps.
PLUGIN_IMPORT_RE = re.compile(r"^\s*(?:@\w+\s+)*import\s+(WebKitExtensions|WebKitMacPlugin|WebKitSupport)\b")
COMPOSITION_FILES = {"Mac/Sources/EngineComposition.swift"}


def find_imports(text: str, path: str = "") -> list[Finding]:
    """Find import WebKit and import Engines lines."""
    findings = []
    in_block = False
    for idx, raw_line in enumerate(text.splitlines(), start=1):
        clean, in_block = strip_comments_from_line(raw_line, in_block)
        if in_block:
            continue
        m = IMPORT_RE.match(clean)
        if m:
            findings.append(
                Finding(
                    path=path,
                    line_number=idx,
                    line_text=raw_line.strip(),
                    detail=m.group(1),
                )
            )
    return findings


def find_plugin_imports(text: str, path: str = "") -> list[Finding]:
    """Find imports of the WebKit plugin's modules."""
    findings = []
    in_block = False
    for idx, raw_line in enumerate(text.splitlines(), start=1):
        clean, in_block = strip_comments_from_line(raw_line, in_block)
        if in_block:
            continue
        m = PLUGIN_IMPORT_RE.match(clean)
        if m:
            findings.append(Finding(path=path, line_number=idx, line_text=raw_line.strip(), detail=m.group(1)))
    return findings


# Section b: Reach-ins into a page's web view.
# `page.view`, `toolsPage?.view`, `little.page.view`: any page whose name ends in Page or page.
REACH_IN_RE = re.compile(r"\b\w*[Pp]age\??\.view\b")
# Only the view itself makes an alias: `let view = page.view` or
# `let view = little.page.view`, not `let window = page.view.window`,
# whose uses are not the web view's.
ALIAS_DEF_RE = re.compile(
    r"\b(?:let|var)\s+([A-Za-z_]\w*)\s*(?::\s*[^=]+)?=\s*(?:[A-Za-z_]\w*\??\.)*\w*[Pp]age\??\.view\b(?!\s*\??\.)"
)


def alias_use_re(name: str) -> re.Pattern:
    """An alias used as a value: `view.url`, `view?.reload()`, or passed on
    (`for: view`). Not another type's member (`x.view`) or a label (`view:`)."""
    return re.compile(r"(?<![.\w])" + re.escape(name) + r"\b(?!\s*:(?!:))")


def find_reach_ins(text: str, path: str = "") -> list[Finding]:
    """Find direct reach-ins to page.view and uses of its local aliases."""
    findings = []
    in_block = False
    current_depth = 0
    # Map of alias name to scope depth where it remains valid.
    active_aliases: dict[str, int] = {}

    for idx, raw_line in enumerate(text.splitlines(), start=1):
        clean, in_block = strip_comments_from_line(raw_line, in_block)
        if in_block:
            continue

        matched = False
        # Direct reach-in or alias definition.
        if REACH_IN_RE.search(clean):
            findings.append(
                Finding(
                    path=path,
                    line_number=idx,
                    line_text=raw_line.strip(),
                    detail="page.view reach-in",
                )
            )
            matched = True

            # Register local alias if defined on this line.
            alias_match = ALIAS_DEF_RE.search(clean)
            if alias_match:
                alias_name = alias_match.group(1)
                net = clean.count("{") - clean.count("}")
                # `guard let view = page.view else {`: the else block's brace
                # opens a scope the alias is not in; it lives on after it.
                if re.search(r"\bguard\b", clean):
                    scope_depth = current_depth
                else:
                    scope_depth = current_depth + max(0, net)
                active_aliases[alias_name] = scope_depth

        # If not already matched, check for uses of active aliases.
        if not matched and active_aliases:
            for alias_name, scope_depth in list(active_aliases.items()):
                if current_depth >= scope_depth:
                    if alias_use_re(alias_name).search(clean):
                        findings.append(
                            Finding(
                                path=path,
                                line_number=idx,
                                line_text=raw_line.strip(),
                                detail=f"alias use: {alias_name}",
                            )
                        )
                        break

        # Track brace depth outside string literals.
        code_without_strings = re.sub(r'"([^"\\]|\\.)*"', "", clean)
        opens = code_without_strings.count("{")
        closes = code_without_strings.count("}")
        current_depth += opens - closes
        if current_depth < 0:
            current_depth = 0

        # Discard aliases whose enclosing scope has closed.
        active_aliases = {
            name: depth
            for name, depth in active_aliases.items()
            if current_depth >= depth
        }

    return findings


# Section c: WebKit types in declarations.
DECL_KEYWORD_RE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|open|override|static|final|weak|unowned|lazy|mutating|nonisolated|optional|required|convenience|indirect|class)(?:\([^)]*\))?\s+)*(func|var|let|protocol|init|typealias|case|class|struct|enum|actor|extension|subscript)\b"
)
WK_TYPE_RE = re.compile(r"\bWK[A-Z]\w*")


def find_declarations(text: str, path: str = "") -> list[Finding]:
    """Find declaration lines mentioning WebKit types."""
    findings = []
    in_block = False
    for idx, raw_line in enumerate(text.splitlines(), start=1):
        clean, in_block = strip_comments_from_line(raw_line, in_block)
        if in_block:
            continue
        if DECL_KEYWORD_RE.match(clean) and WK_TYPE_RE.search(clean):
            wk_match = WK_TYPE_RE.search(clean)
            findings.append(
                Finding(
                    path=path,
                    line_number=idx,
                    line_text=raw_line.strip(),
                    detail=wk_match.group(0) if wk_match else "",
                )
            )
    return findings


# Section d: Private WebKit API.
PRIVATE_API_PATTERNS = [
    # A private selector or key: "_pinnedState", "_webView:didNotHandleWheelEvent:".
    # Not an HTML link target ("_blank", "_self", "_top", "_parent").
    re.compile(r'"_(?!(?:blank|self|top|parent)")[A-Za-z][A-Za-z0-9]*(?::[A-Za-z0-9_]*)*:?"'),
    re.compile(r"@objc\s*\(\s*_"),
    re.compile(r'NSSelectorFromString\s*\(\s*"_'),
    re.compile(r"@objc\b[^;\n]*\bfunc\s+_webView"),
    re.compile(r'value\s*\(\s*forKey(?:Path)?\s*:\s*"_'),
    re.compile(r'setValue\s*\([^)]*forKey(?:Path)?\s*:\s*"_'),
    re.compile(r'"_WK'),
]


def find_private_apis(text: str, path: str = "") -> list[Finding]:
    """Find private WebKit selectors, functions, and key lookups."""
    findings = []
    in_block = False
    for idx, raw_line in enumerate(text.splitlines(), start=1):
        clean, in_block = strip_comments_from_line(raw_line, in_block)
        if in_block:
            continue
        for pat in PRIVATE_API_PATTERNS:
            if pat.search(clean):
                findings.append(
                    Finding(
                        path=path,
                        line_number=idx,
                        line_text=raw_line.strip(),
                        detail=pat.pattern,
                    )
                )
                break
    return findings


# Section e: Hidden web views.
HIDDEN_WEB_VIEW_RE = re.compile(r"\b(?:WKWebView|WKWebViewConfiguration)\s*\(")


def find_hidden_web_views(text: str, path: str = "") -> list[Finding]:
    """Find constructions of WKWebView and WKWebViewConfiguration."""
    findings = []
    in_block = False
    for idx, raw_line in enumerate(text.splitlines(), start=1):
        clean, in_block = strip_comments_from_line(raw_line, in_block)
        if in_block:
            continue
        if HIDDEN_WEB_VIEW_RE.search(clean):
            findings.append(
                Finding(
                    path=path,
                    line_number=idx,
                    line_text=raw_line.strip(),
                    detail="construction",
                )
            )
    return findings


# Section f: Script bridges.
# `root.webkit.messageHandlers` matches too; `root.webkitRequestFileSystem` must not.
SCRIPT_BRIDGE_RE = re.compile(r"\bwebkit\.messageHandlers\b")


def find_script_bridges(text: str, path: str = "") -> list[Finding]:
    """Find webkit.messageHandlers and root.webkit in JS and Swift strings."""
    findings = []
    is_js = path.endswith(".js")
    lines = text.splitlines()

    if is_js:
        in_block = False
        for idx, raw_line in enumerate(lines, start=1):
            clean, in_block = strip_comments_from_line(raw_line, in_block)
            if in_block:
                continue
            if SCRIPT_BRIDGE_RE.search(clean):
                findings.append(
                    Finding(
                        path=path,
                        line_number=idx,
                        line_text=raw_line.strip(),
                        detail="js bridge",
                    )
                )
        return findings

    # In Swift files, scan string literals (single-line and multi-line).
    in_multiline_delim = None
    for idx, raw_line in enumerate(lines, start=1):
        line = raw_line

        # While inside a multi-line string literal.
        if in_multiline_delim is not None:
            if in_multiline_delim in line:
                part_inside, _ = line.split(in_multiline_delim, 1)
                in_multiline_delim = None
                if SCRIPT_BRIDGE_RE.search(part_inside):
                    findings.append(
                        Finding(
                            path=path,
                            line_number=idx,
                            line_text=raw_line.strip(),
                            detail="swift multiline string bridge",
                        )
                    )
            else:
                if SCRIPT_BRIDGE_RE.search(line):
                    findings.append(
                        Finding(
                            path=path,
                            line_number=idx,
                            line_text=raw_line.strip(),
                            detail="swift multiline string bridge",
                        )
                    )
            continue

        # Check for start of multi-line string literal.
        multi_match = re.search(r'(#*""")', line)
        if multi_match:
            delim = multi_match.group(1)
            after_open = line[multi_match.end() :]
            if delim in after_open:
                inside, _ = after_open.split(delim, 1)
                if SCRIPT_BRIDGE_RE.search(inside):
                    findings.append(
                        Finding(
                            path=path,
                            line_number=idx,
                            line_text=raw_line.strip(),
                            detail="swift multiline string bridge",
                        )
                    )
            else:
                in_multiline_delim = delim
                if SCRIPT_BRIDGE_RE.search(after_open):
                    findings.append(
                        Finding(
                            path=path,
                            line_number=idx,
                            line_text=raw_line.strip(),
                            detail="swift multiline string bridge",
                        )
                    )
            continue

        # Check single-line string literals.
        string_literals = re.findall(r'#*"(?:[^"\\]|\\.)*"#*', line)
        for lit in string_literals:
            if SCRIPT_BRIDGE_RE.search(lit):
                findings.append(
                    Finding(
                        path=path,
                        line_number=idx,
                        line_text=raw_line.strip(),
                        detail="swift string literal bridge",
                    )
                )
                break

    return findings


def collect_repo_files(root: Path) -> tuple[list[str], list[str]]:
    """Collect Swift and JavaScript files skipping build and metadata directories."""
    swift_files = []
    js_files = []

    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root)
        parts = Path(rel_dir).parts

        # Skip ignored top-level or nested directories.
        if any(part in SKIP_DIRS for part in parts):
            dirnames[:] = []
            continue

        # Skip Engines/target.
        if "Engines" in parts and "target" in dirnames:
            dirnames.remove("target")

        # Filter in-place to avoid descending into skip directories.
        dirnames[:] = [
            d
            for d in dirnames
            if d not in SKIP_DIRS and not (d == "target" and "Engines" in parts)
        ]

        for fname in filenames:
            rel_path = os.path.join(rel_dir, fname) if rel_dir != "." else fname
            if fname.endswith(".swift"):
                swift_files.append(rel_path)
            elif fname.endswith(".js"):
                js_files.append(rel_path)

    swift_files.sort()
    js_files.sort()
    return swift_files, js_files


def run_imports(root: Path):
    """Only the imports, quickly: what --strict checks, as a build phase."""
    data = {"mac_imports": [], "shared_imports": [], "plugin_imports": []}
    for top, key in (("Mac", "mac_imports"), ("Shared", "shared_imports")):
        for path in sorted((root / top).rglob("*.swift")):
            rel_path = path.relative_to(root).as_posix()
            if any(part in SKIP_DIRS for part in Path(rel_path).parts):
                continue
            content = path.read_text(encoding="utf-8", errors="replace")
            data[key].extend(find_imports(content, rel_path))
            if rel_path not in COMPOSITION_FILES:
                data["plugin_imports"].extend(find_plugin_imports(content, rel_path))
    return data


def run_inventory(root: Path):
    """Run all scans across the repository."""
    swift_files, js_files = collect_repo_files(root)

    # Scanned subsets.
    mac_swift = [
        f for f in swift_files if f.replace("\\", "/").startswith("Mac/")
    ]
    shared_swift = [
        f for f in swift_files if f.replace("\\", "/").startswith("Shared/")
    ]
    all_scan_swift = [
        f
        for f in swift_files
        if any(
            f.replace("\\", "/").startswith(p)
            for p in ("Mac/", "Shared/", "Tests/", "PadCore/")
        )
    ]

    # Section a: Imports.
    mac_imports: list[Finding] = []
    for rel_path in mac_swift:
        content = (root / rel_path).read_text(encoding="utf-8", errors="replace")
        mac_imports.extend(find_imports(content, rel_path))

    shared_imports: list[Finding] = []
    for rel_path in shared_swift:
        content = (root / rel_path).read_text(encoding="utf-8", errors="replace")
        shared_imports.extend(find_imports(content, rel_path))

    # The plugin's modules, outside the composition point.
    plugin_imports: list[Finding] = []
    for rel_path in mac_swift + shared_swift:
        if rel_path.replace("\\", "/") in COMPOSITION_FILES:
            continue
        content = (root / rel_path).read_text(encoding="utf-8", errors="replace")
        plugin_imports.extend(find_plugin_imports(content, rel_path))

    # Section b: Reach-ins.
    # The app's code is what the plan moves; tests that read WebKit's own
    # values on purpose (Tests/MacPage) are counted apart.
    reach_ins: list[Finding] = []
    test_reach_ins: list[Finding] = []
    page_swift_reach_ins: list[Finding] = []
    for rel_path in all_scan_swift:
        content = (root / rel_path).read_text(encoding="utf-8", errors="replace")
        items = find_reach_ins(content, rel_path)
        norm = rel_path.replace("\\", "/")
        if norm.endswith("Mac/Sources/Page.swift") or norm == "Mac/Sources/Page.swift":
            page_swift_reach_ins.extend(items)
        elif norm.startswith("Tests/") or "/Tests/" in norm:
            test_reach_ins.extend(items)
        else:
            reach_ins.extend(items)

    # Section c: WebKit types in declarations.
    declarations: list[Finding] = []
    extension_declarations: list[Finding] = []
    for rel_path in all_scan_swift:
        content = (root / rel_path).read_text(encoding="utf-8", errors="replace")
        items = find_declarations(content, rel_path)
        base = os.path.basename(rel_path)
        if base.startswith("Extension"):
            extension_declarations.extend(items)
        else:
            declarations.extend(items)

    # Section d: Private WebKit API.
    private_apis: list[Finding] = []
    for rel_path in all_scan_swift:
        content = (root / rel_path).read_text(encoding="utf-8", errors="replace")
        private_apis.extend(find_private_apis(content, rel_path))

    # Section e: Hidden web views.
    hidden_web_views: list[Finding] = []
    for rel_path in all_scan_swift:
        content = (root / rel_path).read_text(encoding="utf-8", errors="replace")
        hidden_web_views.extend(find_hidden_web_views(content, rel_path))

    # Section f: App scripts and the WebKit plugin's transport counted apart.
    script_bridges: list[Finding] = []
    plugin_script_bridges: list[Finding] = []
    # Tests that stand in for or read the handlers on purpose are listed apart, as in section b.
    test_script_bridges: list[Finding] = []
    plugin_swift = [f for f in swift_files if f.replace("\\", "/").startswith("WebKitEngine/")]
    app_js = [f for f in js_files if f.replace("\\", "/").startswith(("Mac/", "Shared/", "PadCore/", "Tests/"))]
    plugin_js = [f for f in js_files if f.replace("\\", "/").startswith("WebKitEngine/")]
    for rel_path in app_js + plugin_js + all_scan_swift + plugin_swift:
        content = (root / rel_path).read_text(encoding="utf-8", errors="replace")
        norm = rel_path.replace("\\", "/")
        if norm.startswith("WebKitEngine/"):
            group = plugin_script_bridges
        elif norm.startswith("Tests/"):
            group = test_script_bridges
        else:
            group = script_bridges
        group.extend(find_script_bridges(content, rel_path))

    return {
        "mac_imports": mac_imports,
        "shared_imports": shared_imports,
        "plugin_imports": plugin_imports,
        "reach_ins": reach_ins,
        "test_reach_ins": test_reach_ins,
        "page_swift_reach_ins": page_swift_reach_ins,
        "declarations": declarations,
        "extension_declarations": extension_declarations,
        "private_apis": private_apis,
        "hidden_web_views": hidden_web_views,
        "script_bridges": script_bridges,
        "plugin_script_bridges": plugin_script_bridges,
        "test_script_bridges": test_script_bridges,
    }


def count_files(findings: list[Finding]) -> int:
    """Return count of unique files in findings list."""
    return len({f.path for f in findings})


def build_summary_table(data: dict) -> str:
    """Format markdown summary table."""
    sections = [
        ("a. Imports (Mac/)", len(data["mac_imports"]), count_files(data["mac_imports"])),
        ("a. Imports (Shared/)", len(data["shared_imports"]), count_files(data["shared_imports"])),
        ("a. Plugin imports outside the composition point", len(data["plugin_imports"]), count_files(data["plugin_imports"])),
        ("b. Reach-ins into page view (app)", len(data["reach_ins"]), count_files(data["reach_ins"])),
        ("b. Reach-ins (tests)", len(data["test_reach_ins"]), count_files(data["test_reach_ins"])),
        ("b. Reach-ins (Page.swift self-references)", len(data["page_swift_reach_ins"]), count_files(data["page_swift_reach_ins"])),
        ("c. WebKit types in declarations", len(data["declarations"]), count_files(data["declarations"])),
        ("c. Declarations (Extension* files)", len(data["extension_declarations"]), count_files(data["extension_declarations"])),
        ("d. Private WebKit API", len(data["private_apis"]), count_files(data["private_apis"])),
        ("e. Hidden web views", len(data["hidden_web_views"]), count_files(data["hidden_web_views"])),
        ("f. Script bridges (app)", len(data["script_bridges"]), count_files(data["script_bridges"])),
        ("f. Script bridges (WebKit plugin)", len(data["plugin_script_bridges"]), count_files(data["plugin_script_bridges"])),
        ("f. Script bridges (tests)", len(data["test_script_bridges"]), count_files(data["test_script_bridges"])),
    ]

    # The total is the app's dependencies: Page.swift's own uses of its view
    # and the tests' deliberate reads are listed, not counted.
    not_counted = {"test_reach_ins", "page_swift_reach_ins", "plugin_script_bridges", "test_script_bridges"}
    total_count = sum(len(findings) for key, findings in data.items() if key not in not_counted)
    all_files = set()
    for key, findings in data.items():
        if key in not_counted:
            continue
        for f in findings:
            all_files.add(f.path)

    lines = [
        "| Section | Count | Files |",
        "|:---|---:|---:|",
    ]
    for name, cnt, fcnt in sections:
        lines.append(f"| {name} | {cnt} | {fcnt} |")
    lines.append(f"| **Total** | **{total_count}** | **{len(all_files)}** |")
    return "\n".join(lines)


def format_findings_group(findings: list[Finding]) -> str:
    """Format list of findings grouped by file with line numbers."""
    if not findings:
        return "_None._\n"

    by_file: dict[str, list[Finding]] = collections.defaultdict(list)
    for f in findings:
        by_file[f.path].append(f)

    lines = []
    for file_path in sorted(by_file.keys()):
        items = by_file[file_path]
        lines.append(f"- `{file_path}` ({len(items)}):")
        for item in items:
            escaped = item.line_text.replace("`", "'")
            lines.append(f"  - L{item.line_number}: `{escaped}`")
    return "\n".join(lines) + "\n"


def build_full_report(data: dict) -> str:
    """Format full markdown report with summary table and section details."""
    summary = build_summary_table(data)
    blocks = [
        "# eGlu Engine Inventory",
        "",
        "## Summary",
        "",
        summary,
        "",
        "## Details",
        "",
        "### a. Imports",
        "",
        f"#### Mac/ ({len(data['mac_imports'])} lines in {count_files(data['mac_imports'])} files)",
        format_findings_group(data["mac_imports"]),
        f"#### Shared/ ({len(data['shared_imports'])} lines in {count_files(data['shared_imports'])} files)",
        format_findings_group(data["shared_imports"]),
        f"### b. Reach-ins into a page's web view ({len(data['reach_ins'])} lines in {count_files(data['reach_ins'])} files)",
        format_findings_group(data["reach_ins"]),
        f"#### Tests ({len(data['test_reach_ins'])} lines in {count_files(data['test_reach_ins'])} files)",
        format_findings_group(data["test_reach_ins"]),
        f"#### Page.swift (self-references, excluded from count: {len(data['page_swift_reach_ins'])} lines)",
        format_findings_group(data["page_swift_reach_ins"]),
        f"### c. WebKit types in declarations ({len(data['declarations'])} lines in {count_files(data['declarations'])} files)",
        format_findings_group(data["declarations"]),
        f"#### Declarations in Extension* files ({len(data['extension_declarations'])} lines in {count_files(data['extension_declarations'])} files)",
        format_findings_group(data["extension_declarations"]),
        f"### d. Private WebKit API ({len(data['private_apis'])} lines in {count_files(data['private_apis'])} files)",
        format_findings_group(data["private_apis"]),
        f"### e. Hidden web views ({len(data['hidden_web_views'])} lines in {count_files(data['hidden_web_views'])} files)",
        format_findings_group(data["hidden_web_views"]),
        f"### f. Script bridges (app: {len(data['script_bridges'])} lines in {count_files(data['script_bridges'])} files)",
        format_findings_group(data["script_bridges"]),
        f"#### WebKit plugin ({len(data['plugin_script_bridges'])} lines in {count_files(data['plugin_script_bridges'])} files)",
        format_findings_group(data["plugin_script_bridges"]),
        f"#### Tests ({len(data['test_script_bridges'])} lines in {count_files(data['test_script_bridges'])} files)",
        format_findings_group(data["test_script_bridges"]),
    ]
    return "\n".join(blocks).strip() + "\n"


def main():
    parser = argparse.ArgumentParser(description="eGlu WebKit & Engines inventory")
    parser.add_argument(
        "--check", action="store_true", help="Print summary table only and exit 0"
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit 1 if Mac/ or Shared/ imports WebKit or Engines, or a WebKit plugin module outside the composition point",
    )
    parser.add_argument(
        "--write", type=Path, help="Write markdown report to specified path"
    )
    args = parser.parse_args()

    # Find repository root.
    cwd = Path.cwd()
    if (cwd / "Mac").is_dir() and (cwd / "Shared").is_dir():
        repo_root = cwd
    else:
        repo_root = Path(__file__).resolve().parent.parent

    if args.strict and not (args.write or args.check):
        data = run_imports(repo_root)
        offending = data["mac_imports"] + data["shared_imports"] + data["plugin_imports"]
        if offending:
            print(
                "Offending files importing WebKit or Engines in Mac/ or Shared/,"
                " or a WebKit plugin module outside the composition point:"
            )
            # As Xcode reads errors, so a build phase shows them at the line.
            for item in offending:
                print(f"{repo_root / item.path}:{item.line_number}: error: {item.line_text}"
                      " (the interface talks to engines only through contracts; Docs/WebEngine.md)")
            sys.exit(1)
        print("No file in Mac/ or Shared/ imports WebKit or Engines, or a WebKit plugin module outside the composition point.")
        sys.exit(0)

    data = run_inventory(repo_root)

    if args.write:
        today = datetime.date.today().isoformat()
        first_line = (
            f"<!-- Generated by Tests/engine-inventory.py on {today}. Do not edit by hand. -->\n"
        )
        report_content = first_line + build_full_report(data)
        args.write.parent.mkdir(parents=True, exist_ok=True)
        args.write.write_text(report_content, encoding="utf-8")
        # Written: say where, not the whole report again.
        print(f"Wrote {args.write}")
        if not (args.check or args.strict):
            return

    if args.check:
        print(build_summary_table(data))
        sys.exit(0)

    if args.strict:
        print(build_summary_table(data))
        offending = data["mac_imports"] + data["shared_imports"] + data["plugin_imports"]
        if offending:
            print(
                "\nOffending files importing WebKit or Engines in Mac/ or Shared/,"
                " or a WebKit plugin module outside the composition point:"
            )
            # As Xcode reads errors, so a build phase shows them at the line.
            for item in offending:
                print(f"{repo_root / item.path}:{item.line_number}: error: {item.line_text}"
                      " (the interface talks to engines only through contracts; Docs/WebEngine.md)")
            sys.exit(1)
        sys.exit(0)

    # Default output: markdown to stdout.
    print(build_full_report(data))


if __name__ == "__main__":
    main()
