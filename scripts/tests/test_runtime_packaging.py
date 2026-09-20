"""Regression checks for release wheel inventory and platform rejection."""
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("package_runtime", Path(__file__).parents[1] / "package-runtime.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class WheelValidationTests(unittest.TestCase):
    def test_compatible_inventory(self):
        module.validate_wheels([Path("example-1.0-cp313-cp313-macosx_14_0_arm64.whl")], {"example": "1.0"})

    def test_rejects_newer_os_wrong_arch_and_python(self):
        for tag in ["cp313-cp313-macosx_26_0_arm64", "cp313-cp313-macosx_15_0_x86_64",
                    "cp312-cp312-macosx_15_0_arm64"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                module.validate_wheels([Path(f"example-1.0-{tag}.whl")], {"example": "1.0"})

    def test_rejects_missing_extra_and_wrong_versions(self):
        wheel = Path("example-1.0-py3-none-any.whl")
        for wheels, expected in [([], {"example": "1.0"}), ([wheel], {}),
                                 ([wheel], {"example": "2.0"}), ([wheel, wheel], {"example": "1.0"})]:
            with self.subTest(wheels=wheels, expected=expected), self.assertRaises(ValueError):
                module.validate_wheels(wheels, expected)


if __name__ == "__main__":
    unittest.main()
