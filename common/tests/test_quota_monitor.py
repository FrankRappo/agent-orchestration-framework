#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("quota_monitor", HERE.parent / "quota_monitor.py")
quota = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(quota)


class QuotaMonitorTests(unittest.TestCase):
    def test_zcode_buckets_and_admission(self):
        buckets, plans = quota.parse_zcode([HERE / "fixtures" / "zcode.txt"])
        self.assertEqual("Test Plan", plans[0]["name"])
        by_name = {item["name"]: item for item in buckets}
        self.assertEqual(20.0, by_name["GLM-5.3"]["used_percent"])
        self.assertEqual("critical", by_name["GLM-5.3-Flash"]["status"])
        decision = quota.admission(buckets, "zcode", "GLM-5.3-Flash", 15, 10**9)
        self.assertEqual("deny", decision["decision"])

    def test_codex_window_names(self):
        buckets = quota.parse_codex([HERE / "fixtures" / "codex.jsonl"])
        by_window = {item["window"]: item for item in buckets}
        self.assertEqual(40.0, by_window["five_hour"]["used_percent"])
        self.assertEqual("warning", by_window["weekly"]["status"])

    def test_any_usable_zcode_bucket_admits_same_model(self):
        now = int(quota.time.time())
        buckets = [
            {"provider": "zcode", "model": "GLM-5.3-Flash", "used_percent": 99, "observed_at": now},
            {"provider": "zcode", "model": "GLM-5.3-Flash", "used_percent": 10, "observed_at": now},
        ]
        decision = quota.admission(buckets, "zcode", "GLM-5.3-Flash", 15, 10**9)
        self.assertEqual("allow", decision["decision"])


if __name__ == "__main__":
    unittest.main()
