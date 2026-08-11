from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "analyze-run.py"
SPEC = importlib.util.spec_from_file_location("analyze_run", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
ANALYZE_RUN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ANALYZE_RUN)


RESOURCE_MODULE_PATH = Path(__file__).resolve().parents[2] / "scripts" / "collect-resources.py"
RESOURCE_SPEC = importlib.util.spec_from_file_location("collect_resources", RESOURCE_MODULE_PATH)
assert RESOURCE_SPEC is not None and RESOURCE_SPEC.loader is not None
COLLECT_RESOURCES = importlib.util.module_from_spec(RESOURCE_SPEC)
RESOURCE_SPEC.loader.exec_module(COLLECT_RESOURCES)


class AnalysisTest(unittest.TestCase):
    def test_nearest_rank_percentiles(self) -> None:
        values = [1, 2, 3, 4, 5]

        self.assertEqual(3, ANALYZE_RUN.nearest_rank(values, 50))
        self.assertEqual(5, ANALYZE_RUN.nearest_rank(values, 90))
        self.assertEqual(5, ANALYZE_RUN.nearest_rank(values, 99))

    def test_binary_and_iec_memory_units(self) -> None:
        self.assertEqual(1024**2, COLLECT_RESOURCES.parse_bytes("1MiB"))
        self.assertEqual(1_500_000, COLLECT_RESOURCES.parse_bytes("1.5MB"))
        self.assertEqual(2 * 1024**3, COLLECT_RESOURCES.parse_bytes("2 GiB"))

    def test_resource_totals_are_summarized(self) -> None:
        rows = [
            {"cpu": "10.0", "memory": "100"},
            {"cpu": "30.0", "memory": "300"},
        ]

        result = ANALYZE_RUN.summarize_numeric(rows, "cpu", "memory")

        self.assertEqual(2, result["sample_count"])
        self.assertEqual(20.0, result["average_cpu_percent"])
        self.assertEqual(30.0, result["maximum_cpu_percent"])
        self.assertEqual(200.0, result["average_memory_bytes"])
        self.assertEqual(300.0, result["maximum_memory_bytes"])


if __name__ == "__main__":
    unittest.main()
