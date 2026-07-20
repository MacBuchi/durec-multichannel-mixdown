#!/usr/bin/env python3
"""Regenerate assets/licenses/rust-third-party.txt.

Flutter's LicenseRegistry collects the Dart/Flutter side by itself; the Rust
crates linked into the engine are invisible to it. This walks the actual
link-time dependency graph and copies each crate's own licence text into one
bundled asset.

    tool/gen_rust_licenses.py            # rewrite the asset
    tool/gen_rust_licenses.py --check    # fail if it would change (CI use)

Scope decisions worth knowing:

* `-e normal` only — build-dependencies and dev-dependencies are not linked
  into the shipped binary, so their notices do not have to travel with it.
* `--target all` — one asset serves every platform we ship, and cpal alone
  pulls a different subtree per OS.
* Workspace members (our own crates) are skipped; DurecMix's own licence is
  the MIT LICENSE at the repo root.
* Identical licence texts are emitted once, with every crate that uses them
  listed above — 100+ crates share a handful of MIT/Apache texts verbatim.
"""

import argparse
import hashlib
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "licenses" / "rust-third-party.txt"
CANONICAL = pathlib.Path(__file__).resolve().parent / "licenses"

LICENSE_FILE_HINTS = ("license", "licence", "copying", "notice", "unlicense")

# Not every crate ships its licence text — 31 of ours do not, including the
# whole MPL-2.0 Symphonia family, and MPL-2.0 §3.1 wants the text to travel
# with the distribution. For those we fall back to the canonical text of one
# licence from their SPDX expression.
#
# Order matters: Apache-2.0 and MPL-2.0 are boilerplate that says nothing
# about who holds the copyright, so quoting them for a crate we did not
# write is accurate. A verbatim MIT text carries a "Copyright (c) <holder>"
# line, so it comes last and its holder line is generalised — the crate
# authors are printed above each block.
FALLBACK_ORDER = ("Apache-2.0", "MPL-2.0", "MIT")


def run(*args: str) -> str:
    return subprocess.run(
        args, cwd=ROOT, capture_output=True, text=True, check=True
    ).stdout


def linked_crates() -> list[tuple[str, str, str]]:
    """(name, version, spdx) for every crate linked into the binary."""
    out = run(
        "cargo", "tree", "-e", "normal", "--target", "all",
        "--prefix", "none", "--format", "{p}|{l}",
    )
    seen: dict[tuple[str, str], str] = {}
    for line in out.splitlines():
        line = line.strip()
        if not line or line.endswith("(*)"):
            continue
        pkg, _, spdx = line.partition("|")
        parts = pkg.split()
        if len(parts) < 2 or not parts[1].startswith("v"):
            continue
        name, version = parts[0], parts[1][1:]
        # Path-qualified entries are our own workspace crates.
        if "(/" in pkg:
            continue
        seen[(name, version)] = spdx.strip() or "(not declared)"
    return sorted((n, v, s) for (n, v), s in seen.items())


def package_info() -> dict[tuple[str, str], tuple[pathlib.Path, str]]:
    """(source dir, authors) per crate."""
    meta = json.loads(run("cargo", "metadata", "--format-version", "1"))
    return {
        (p["name"], p["version"]): (
            pathlib.Path(p["manifest_path"]).parent,
            ", ".join(p.get("authors") or []) or "authors not declared",
        )
        for p in meta["packages"]
    }


def fallback_license(spdx: str) -> str | None:
    """Pick one licence from an SPDX expression we have canonical text for."""
    for candidate in FALLBACK_ORDER:
        if candidate in spdx and (CANONICAL / f"{candidate}.txt").exists():
            return candidate
    return None


def license_texts(directory: pathlib.Path) -> list[str]:
    texts = []
    for path in sorted(directory.iterdir()):
        if not path.is_file():
            continue
        stem = path.name.lower()
        if any(stem.startswith(h) for h in LICENSE_FILE_HINTS):
            try:
                body = path.read_text(encoding="utf-8", errors="replace").strip()
            except OSError:
                continue
            if body:
                texts.append(body)
    return texts


def build() -> str:
    info = package_info()
    crates = linked_crates()

    # text hash -> (text, [crate labels])
    grouped: dict[str, tuple[str, list[str]]] = {}
    # canonical licence id -> [crate labels]
    fallbacks: dict[str, list[str]] = {}
    unresolved: list[str] = []

    for name, version, spdx in crates:
        label = f"{name} {version} — {spdx}"
        directory, authors = info.get((name, version), (None, ""))
        texts = license_texts(directory) if directory else []
        if not texts:
            chosen = fallback_license(spdx)
            if chosen:
                fallbacks.setdefault(chosen, []).append(f"{label}  [{authors}]")
            else:
                unresolved.append(label)
            continue
        for text in texts:
            key = hashlib.sha256(text.encode()).hexdigest()
            grouped.setdefault(key, (text, []))[1].append(label)

    lines = [
        "Third-party licences of the Rust engine bundled with DurecMix",
        "",
        "Generated by tool/gen_rust_licenses.py from the link-time dependency",
        "graph (cargo tree -e normal --target all). DurecMix's own licence is",
        "the MIT LICENSE in the repository root.",
        "",
        f"{len(crates)} crates, {len(grouped) + len(fallbacks)} licence texts.",
        "",
    ]

    if unresolved:
        lines += [
            "Crates shipping no licence file, and whose SPDX expression names no",
            "licence we hold canonical text for — the expression itself applies:",
            "",
        ]
        lines += [f"  {label}" for label in unresolved]
        lines += [""]

    for _, (text, labels) in sorted(
        grouped.items(), key=lambda kv: (-len(kv[1][1]), kv[1][1][0])
    ):
        lines.append("=" * 72)
        lines += [f"  {label}" for label in sorted(set(labels))]
        lines.append("=" * 72)
        lines += ["", text, ""]

    for licence, labels in sorted(fallbacks.items()):
        lines.append("=" * 72)
        lines += [f"  {label}" for label in sorted(set(labels))]
        lines.append("-" * 72)
        lines.append(
            f"  These crates ship no licence file. Canonical text of "
            f"{licence}, one of the licences their manifest offers:"
        )
        lines.append("=" * 72)
        lines += ["", (CANONICAL / f"{licence}.txt").read_text().strip(), ""]

    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    content = build()
    if args.check:
        current = OUT.read_text() if OUT.exists() else ""
        if current != content:
            print(f"{OUT.relative_to(ROOT)} is stale — run tool/gen_rust_licenses.py")
            return 1
        print(f"{OUT.relative_to(ROOT)} is up to date")
        return 0

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(content)
    print(f"wrote {OUT.relative_to(ROOT)} ({len(content) // 1024} KiB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
