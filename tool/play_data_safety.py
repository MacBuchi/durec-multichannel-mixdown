#!/usr/bin/env python3
"""Fill Google's Data Safety form from docs/PLAN-PLAYSTORE.md.

Play Console can import the form's answers as a CSV (App content → Data
safety → "Import from CSV"). This takes a blank export of that form
(`docs/store/data_safety_template.csv`) and fills in our answers — the
result is `docs/store/data_safety.csv`, ready to import.

Pattern from PilzBuddy/Fahrgemeinschaft (tool/play_data_safety.py in both):
hand-editing the CSV is how it drifts from what's actually true and stops
matching what Play will accept — `--check` catches that in CI. The content
truth stays docs/PLAN-PLAYSTORE.md §3; the answer below is copied from
there.

Mixstack's answer set is almost entirely empty, and that's the point, not
an oversight: the app is fully offline, and the Play build specifically
disables both network paths the direct build has (self-update check,
token-based feedback posting — see docs/PLAN-PLAYSTORE.md §2/§3). With
`PSL_DATA_COLLECTION_COLLECTS_PERSONAL_DATA = false`, almost every other
question in the form becomes unanswerable — not optional-to-skip, but
actively rejected by Play if answered at all. That's exactly the mistake a
prior hand-edited version of this CSV made
(`PSL_SUPPORTED_ACCOUNT_CREATION_METHODS` answered "none" instead of left
blank; Play's import error: "Du kannst
PSL_SUPPORTED_ACCOUNT_CREATION_METHODS nicht beantworten").

Two guards against the two ways this has actually broken before:

* Every key in the answer table MUST exist in the template — a made-up or
  mistyped id fails the run instead of silently writing nothing.
* Every key MUST NOT point at a template row marked `OPTIONAL` in the
  "Answer requirement" column. Rows tagged `OPTIONAL` are conditionally
  gated on other answers Google doesn't expose in the template — answering
  one that isn't currently active is exactly the rejection above. When
  `COLLECTS_PERSONAL_DATA` is false, that's every other question in this
  form.

Usage:
  python3 tool/play_data_safety.py            # writes docs/store/data_safety.csv
  python3 tool/play_data_safety.py --check    # CI guard
"""
from __future__ import annotations

import csv
import io
import sys

TEMPLATE = "docs/store/data_safety_template.csv"
OUTPUT = "docs/store/data_safety.csv"

# Lowercase because the Console export writes it that way.
TRUE, FALSE = "true", "false"

# (question id, response id) -> value, exactly as the template spells them.
# Response id is "" for single-value questions. Anything not listed here
# stays blank — the template has no "No" checkbox, blank IS the answer.
ANSWERS: dict[tuple[str, str], str] = {
    # The one REQUIRED question. Everything downstream of "no" is either
    # blank because it doesn't apply, or blocked by the OPTIONAL guard
    # below because Play won't accept an answer to it while this is false.
    ("PSL_DATA_COLLECTION_COLLECTS_PERSONAL_DATA", ""): FALSE,
}


def render() -> str:
    with open(TEMPLATE, newline="", encoding="utf-8-sig") as f:
        rows = list(csv.reader(f))

    known = {(r[0], r[1]) for r in rows[1:] if r}
    unknown = [k for k in ANSWERS if k not in known]
    if unknown:
        raise SystemExit(
            "Answer ids missing from the template (typo, or Google changed "
            f"the form): {unknown}"
        )

    requirement = {(r[0], r[1]): r[3] for r in rows[1:] if r}
    gated = sorted(k for k in ANSWERS if requirement[k] == "OPTIONAL")
    if gated:
        raise SystemExit(
            "These questions are marked OPTIONAL in the template, meaning "
            "they're only asked conditionally — Play rejects an answer to "
            f"them on import: {gated}"
        )

    used = set()
    for row in rows[1:]:
        if not row:
            continue
        key = (row[0], row[1])
        if key in ANSWERS:
            row[2] = ANSWERS[key]
            used.add(key)
        else:
            row[2] = ""
    assert used == set(ANSWERS)

    out = io.StringIO()
    # CRLF, no trailing blank line — matches the Console's own export.
    csv.writer(out, lineterminator="\r\n").writerows(rows)
    return out.getvalue()[:-2]


def main() -> int:
    content = render()
    answered = sum(1 for line in content.splitlines() if ",true," in line or ",false," in line)

    if "--check" in sys.argv:
        try:
            with open(OUTPUT, newline="", encoding="utf-8") as f:
                current = f.read()
        except FileNotFoundError:
            print(f"{OUTPUT} missing — run: python3 tool/play_data_safety.py")
            return 1
        if current != content:
            print(
                f"{OUTPUT} doesn't match template + answers. Don't edit the "
                "CSV — change the ANSWERS table in tool/play_data_safety.py "
                "(and docs/PLAN-PLAYSTORE.md in the same commit), then "
                "regenerate."
            )
            return 1
        print(f"{OUTPUT}: matches template + answers ({answered} set)")
        return 0

    with open(OUTPUT, "w", newline="", encoding="utf-8") as f:
        f.write(content)
    print(f"{OUTPUT}: {answered} answers set")
    return 0


if __name__ == "__main__":
    sys.exit(main())
