"""Headless local coding-agent adapters. Credentials remain managed by the CLIs."""

from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import tempfile
from pathlib import Path

DEFAULT_MODELS = {"codex": "gpt-5.6-luna", "claude-code": "claude-sonnet-5"}
DEFAULT_PROVIDER = "codex"
DEFAULT_EFFORT = "high"
AGENT_TIMEOUT_SECONDS = 300
MAX_RESPONSE_BYTES = 1_000_000
COMMANDS = {"codex": ("codex", "STILLNOTE_CODEX_BIN"), "claude-code": ("claude", "STILLNOTE_CLAUDE_BIN")}
LABELS = {"codex": "Codex", "claude-code": "Claude Code"}


class SummaryError(ValueError):
    """An actionable error safe to expose without CLI output or credentials."""


def agent_status() -> dict:
    return {
        provider: {"installed": bool(shutil.which(os.environ.get(variable) or command)), "command": command}
        for provider, (command, variable) in COMMANDS.items()
    }


def _executable(provider: str) -> str:
    command, variable = COMMANDS[provider]
    executable = shutil.which(os.environ.get(variable) or command)
    if not executable:
        raise SummaryError(
            f"{LABELS[provider]} CLI was not found. Install {command}, sign in, and restart Stillnote. "
            f"For a custom installation, set {variable} to its executable path."
        )
    return executable


def _stop(process: subprocess.Popen) -> None:
    # Kill the process group as well as the CLI so timeout cannot leave agent
    # subprocesses running after their temporary workspace has been removed.
    try:
        if os.name == "posix":
            os.killpg(process.pid, signal.SIGKILL)
        else:
            process.kill()
    except ProcessLookupError:
        pass
    process.wait()


def _run(command: list[str], prompt: str, directory: Path, provider: str) -> bytes:
    label = LABELS[provider]
    # Transcript content is never a command-line argument or shell program.
    # Spool stdout to a private temporary file, keeping CLI chatter out of RAM
    # and application logs. stderr is discarded because it may echo the prompt.
    with tempfile.TemporaryFile() as output:
        try:
            process = subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=output,
                stderr=subprocess.DEVNULL,
                cwd=directory,
                start_new_session=os.name == "posix",
            )
        except OSError:
            raise SummaryError(
                f"Could not start {label}. Check its installation and executable permissions."
            ) from None
        try:
            process.communicate(input=prompt.encode("utf-8"), timeout=AGENT_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            _stop(process)
            raise SummaryError(
                f"{label} timed out. Retry with a shorter transcript or check the CLI connection."
            ) from None
        except BaseException:
            _stop(process)
            raise
        if process.returncode:
            raise SummaryError(
                f"{label} could not finish the summary (exit {process.returncode}). "
                "Check CLI sign-in, model access, usage limits, and that the CLI is up to date."
            )
        output.seek(0)
        return output.read(MAX_RESPONSE_BYTES + 1)


def request_json(provider: str, model: str, effort: str, instructions: str, prompt: str, schema: dict) -> str:
    executable = _executable(provider)
    with tempfile.TemporaryDirectory(prefix="stillnote-agent-") as temporary:
        directory = Path(temporary)
        if provider == "codex":
            schema_path = directory / "schema.json"
            response_path = directory / "response.json"
            schema_path.write_text(json.dumps(schema), encoding="utf-8")
            command = [
                executable,
                "exec",
                "--model",
                model,
                "--config",
                f'model_reasoning_effort="{effort}"',
                "--sandbox",
                "read-only",
                "--skip-git-repo-check",
                "--ephemeral",
                "--ignore-user-config",
                "--config",
                "project_doc_max_bytes=0",
                "--config",
                'approval_policy="never"',
                "--config",
                'web_search="disabled"',
                "--disable",
                "shell_tool",
                "--disable",
                "unified_exec",
                "--output-schema",
                str(schema_path),
                "--output-last-message",
                str(response_path),
                "--color",
                "never",
                "-",
            ]
            _run(command, instructions + "\n\n" + prompt, directory, provider)
            try:
                with response_path.open("rb") as response:
                    content = response.read(MAX_RESPONSE_BYTES + 1)
            except OSError:
                raise SummaryError(
                    "Codex did not return a final summary. Check model access and retry."
                ) from None
        else:
            command = [
                executable,
                "--print",
                "--model",
                model,
                "--effort",
                effort,
                "--output-format",
                "json",
                "--json-schema",
                json.dumps(schema),
                "--system-prompt",
                instructions,
                "--tools",
                "",
                "--disable-slash-commands",
                "--strict-mcp-config",
                "--mcp-config",
                '{"mcpServers":{}}',
                "--setting-sources",
                "user",
                "--settings",
                '{"disableAllHooks":true}',
                "--permission-mode",
                "dontAsk",
                "--no-session-persistence",
            ]
            content = _run(command, prompt, directory, provider)
        if len(content) > MAX_RESPONSE_BYTES:
            raise SummaryError(
                f"{LABELS[provider]} returned an unexpectedly large response. Try a shorter transcript."
            )
        try:
            text = content.decode("utf-8")
            if provider == "claude-code":
                envelope = json.loads(text)
                if not isinstance(envelope, dict):
                    raise ValueError
                if envelope.get("is_error") or envelope.get("subtype") != "success":
                    raise SummaryError(
                        "Claude Code could not complete the summary. Check CLI sign-in, model access, "
                        "usage limits, and retry."
                    )
                # --json-schema returns the validated object in structured_output;
                # older releases can return the final JSON text in result.
                structured = envelope.get("structured_output")
                text = json.dumps(structured) if isinstance(structured, dict) else envelope.get("result")
            if not isinstance(text, str) or not text.strip():
                raise ValueError
            return text
        except (UnicodeError, ValueError) as error:
            if isinstance(error, SummaryError):
                raise
            raise SummaryError(
                f"{LABELS[provider]} returned invalid output. Update the CLI and retry."
            ) from None
