import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "scripts/lib/check_skill_commands.py"


class CheckSkillCommandsTests(unittest.TestCase):
    catalog = {
        "result": {
            "commands": [
                {
                    "path": ["search"],
                    "value_options": ["in"],
                    "boolean_options": ["exact"],
                }
            ],
            "global_value_options": ["timeout"],
            "global_boolean_options": ["json", "help"],
        }
    }

    def check(self, markdown: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "reference.md"
            path.write_text(markdown, encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(CHECKER), directory],
                input=json.dumps(self.catalog), text=True, capture_output=True, check=False
            )

    def test_accepts_command_and_global_options(self):
        result = self.check(
            "# Reference\n\n"
            "| Command | Options |\n| --- | --- |\n"
            "| `stillnote search <query>` | `--in`, `--exact`, `--json`, `--timeout <seconds>` |\n"
        )
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_rejects_a_documented_option_the_command_does_not_accept(self):
        result = self.check(
            "# Reference\n\n"
            "| Command | Options |\n| --- | --- |\n"
            "| `stillnote search <query>` | `--wrong-option` |\n"
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("stillnote search --wrong-option", result.stdout)
        self.assertIn("does not accept it", result.stdout)


if __name__ == "__main__":
    unittest.main()
