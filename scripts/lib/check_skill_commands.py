"""Cross-check the commands a skill documents against the CLI's own catalog.

Reads `stillnote help --json` on stdin and the skill directories as arguments. Only inline code
spans and fenced code blocks are treated as commands, so prose that happens to contain the word
`stillnote` is not mistaken for an instruction.
"""

import json
import re
import sys
from pathlib import Path

FENCE = re.compile(r"^\s*```")
CODE_SPAN = re.compile(r"`([^`]+)`")
INVOCATION = re.compile(r"\bstillnote\s+([a-z][a-z0-9-]*)(?:\s+([a-z][a-z0-9-]*))?")


def code_fragments(text: str) -> list[str]:
    fragments: list[str] = []
    in_fence = False
    for line in text.splitlines():
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            fragments.append(line)
        else:
            fragments.extend(CODE_SPAN.findall(line))
    return fragments


def mentions(roots: list[Path]) -> dict[tuple[str, str], set[Path]]:
    found: dict[tuple[str, str], set[Path]] = {}
    for root in roots:
        for path in sorted(root.rglob("*.md")):
            for fragment in code_fragments(path.read_text(encoding="utf-8")):
                for first, second in INVOCATION.findall(fragment):
                    found.setdefault((first, second), set()).add(path)
    return found


def main() -> int:
    catalog = json.load(sys.stdin)
    known = {" ".join(spec["path"]) for spec in catalog["result"]["commands"]}
    if not known:
        print("check-skill: the CLI listed no commands")
        return 1

    status = 0
    resolved: set[str] = set()
    for (first, second), paths in sorted(
        mentions([Path(root) for root in sys.argv[1:]]).items()
    ):
        # Longest match wins, exactly as the parser does: `summary show` never reads as `summary`.
        match = next(
            (candidate for candidate in ([f"{first} {second}"] if second else []) + [first]
             if candidate in known),
            None,
        )
        if match is None:
            where = ", ".join(str(path) for path in sorted(paths))
            spelled = f"{first} {second}".strip()
            print(
                f"check-skill: {where} documents 'stillnote {spelled}', "
                "which the CLI does not provide"
            )
            status = 1
            continue
        resolved.add(match)

    for command in sorted(known - resolved):
        print(f"check-skill: 'stillnote {command}' exists but no skill documents it")
        status = 1

    return status


if __name__ == "__main__":
    sys.exit(main())
