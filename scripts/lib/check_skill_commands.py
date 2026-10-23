"""Cross-check the commands a skill documents against the CLI's own catalog.

Reads `stillnote help --json` on stdin and the skill directories as arguments. Only inline code
spans and fenced code blocks are treated as commands, so prose that happens to contain the word
`stillnote` is not mistaken for an instruction. It checks each documented long option too, so the
published skill cannot retain an option after the CLI removes or renames it.
"""

import json
import re
import sys
from pathlib import Path

FENCE = re.compile(r"^\s*```")
CODE_SPAN = re.compile(r"`([^`]+)`")
INVOCATION = re.compile(r"\bstillnote\s+([a-z][a-z0-9-]*)(?:\s+([a-z][a-z0-9-]*))?")
LONG_OPTION = re.compile(r"(?<![\w-])--([a-z][a-z0-9-]*)(?:=\S+)?")


def code_fragments(text: str) -> list[str]:
    fragments: list[str] = []
    in_fence = False
    fence_lines: list[str] = []
    for line in text.splitlines():
        if FENCE.match(line):
            if in_fence:
                fragments.append("\n".join(fence_lines))
                fence_lines = []
                in_fence = False
            else:
                in_fence = True
            continue
        if in_fence:
            fence_lines.append(line)
        else:
            # A command-reference table puts its invocation and options in separate inline code
            # spans. Joining the spans from one row preserves that association without treating
            # prose as a command.
            spans = CODE_SPAN.findall(line)
            if spans:
                fragments.append(" ".join(spans))
    if in_fence:
        fragments.append("\n".join(fence_lines))
    return fragments


def invocations(roots: list[Path]):
    for root in roots:
        for path in sorted(root.rglob("*.md")):
            for fragment in code_fragments(path.read_text(encoding="utf-8")):
                matches = list(INVOCATION.finditer(fragment))
                for index, match in enumerate(matches):
                    end = matches[index + 1].start() if index + 1 < len(matches) else len(fragment)
                    yield path, match.group(1), match.group(2) or "", fragment[match.end():end]


def resolve(first: str, second: str, known: set[str]) -> str | None:
    # Longest match wins, exactly as the parser does: `summary show` never reads as `summary`.
    return next(
        (candidate for candidate in ([f"{first} {second}"] if second else []) + [first]
         if candidate in known),
        None,
    )


def main() -> int:
    catalog = json.load(sys.stdin)
    result = catalog["result"]
    specs = {" ".join(spec["path"]): spec for spec in result["commands"]}
    known = set(specs)
    if not known:
        print("check-skill: the CLI listed no commands")
        return 1

    status = 0
    documented: set[str] = set()
    global_options = set(result.get("global_value_options", [])) | set(
        result.get("global_boolean_options", [])
    )
    for path, first, second, tail in invocations([Path(root) for root in sys.argv[1:]]):
        match = resolve(first, second, known)
        if match is None:
            spelled = f"{first} {second}".strip()
            print(
                f"check-skill: {path} documents 'stillnote {spelled}', "
                "which the CLI does not provide"
            )
            status = 1
            continue
        documented.add(match)
        spec = specs[match]
        allowed = global_options | set(spec["value_options"]) | set(spec["boolean_options"])
        for option in LONG_OPTION.findall(tail):
            if option not in allowed:
                print(
                    f"check-skill: {path} documents 'stillnote {match} --{option}', "
                    "but that command does not accept it"
                )
                status = 1

    for command in sorted(known - documented):
        print(f"check-skill: 'stillnote {command}' exists but no skill documents it")
        status = 1

    return status


if __name__ == "__main__":
    sys.exit(main())
