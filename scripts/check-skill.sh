#!/usr/bin/env bash
# Validates the published skills and proves every command they document exists in the CLI, so a
# skill installed with `npx skills add` can never tell an agent to run something that was renamed.
set -euo pipefail
cd "$(dirname "$0")/.."

cli="${STILLNOTE_CLI:-}"
if [[ -z "$cli" ]]; then
  # Keep SwiftPM's dependency warnings out of the way unless the build actually fails.
  if ! build_log="$(swift build --product StillnoteCLI 2>&1)"; then
    printf '%s\n' "$build_log"
    exit 1
  fi
  cli="$(swift build --show-bin-path)/StillnoteCLI"
fi
[[ -x "$cli" ]] || { echo "check-skill: no stillnote binary at $cli"; exit 1; }

status=0
shopt -s nullglob
skills=(skills/*/SKILL.md)
(( ${#skills[@]} > 0 )) || { echo 'check-skill: no skills found under skills/'; exit 1; }

for manifest in "${skills[@]}"; do
  directory="$(dirname "$manifest")"
  expected="$(basename "$directory")"
  echo "check-skill: $manifest"

  # Frontmatter: a --- delimited block at the very top carrying name and description.
  if [[ "$(head -n 1 "$manifest")" != '---' ]]; then
    echo "  error: must open with a '---' frontmatter block"
    status=1
    continue
  fi
  frontmatter="$(awk 'NR>1 { if ($0 == "---") exit; print }' "$manifest")"
  name="$(printf '%s\n' "$frontmatter" | sed -n 's/^name:[[:space:]]*//p' | head -n 1)"
  description="$(printf '%s\n' "$frontmatter" | sed -n 's/^description:[[:space:]]*//p' | head -n 1)"

  [[ -n "$name" ]] || { echo "  error: frontmatter needs a name"; status=1; }
  [[ -n "$description" ]] || { echo "  error: frontmatter needs a description"; status=1; }
  if [[ -n "$name" && "$name" != "$expected" ]]; then
    echo "  error: name '$name' does not match directory '$expected'"
    status=1
  fi
  if [[ -n "$name" && ! "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    echo "  error: name '$name' must be lowercase with hyphens"
    status=1
  fi
  # The description is what an agent matches against, so an unhelpfully short one is a bug.
  if (( ${#description} < 40 )); then
    echo "  error: description is too short to trigger the skill reliably"
    status=1
  fi
  if grep -q '^# ' "$manifest"; then :; else
    echo "  error: needs a top-level heading"
    status=1
  fi
done

# Every `stillnote <command>` the skills mention has to be a real command, and every command has
# to be documented somewhere. The catalog is the source of truth, so compare against it rather
# than a second hand-kept list. Only code spans and fenced blocks count: a prose heading such as
# "stillnote command reference" is not an instruction to run anything.
if ! "$cli" help --json | python3 scripts/lib/check_skill_commands.py skills; then
  status=1
fi

if (( status == 0 )); then
  echo "check-skill: ${#skills[@]} skill(s) validated against $("$cli" --version)"
fi
exit "$status"
