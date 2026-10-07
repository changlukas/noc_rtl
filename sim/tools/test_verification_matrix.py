import unittest
from verification_matrix import coverage_bins, TARGETS, metadata, stimulus_settings

class MatrixExportTest(unittest.TestCase):
    def test_all_pattern_ids(self):
        self.assertEqual(set(TARGETS), {f"P{i:02d}" for i in range(1,23)})
        self.assertIn("write_strobe_cg",metadata("P09")["coverage_targets"])

    def test_instance_counts_not_type_counts(self):
        text = """Group : top::cg
Summary for Variable cp_lane
NAME COUNT AT LEAST
lane_0 99 1
---
Group Instance : sample_cov
Summary for Variable cp_lane
NAME COUNT AT LEAST
lane_0 2 1
NAME COUNT AT LEAST NUMBER
lane_1 0 1 1
---
Summary for Cross size_lane
SIZE LANE COUNT AT LEAST
size_0 lane_0 2 1
Excluded/Illegal bins
invalid 0 Excluded
"""
        rows=coverage_bins(text,"fresh")
        self.assertEqual(len(rows),3)
        self.assertEqual(rows[0][5],2)
        self.assertEqual(rows[1][-1],"Uncovered")
        self.assertEqual(rows[2][4],"size_0 / lane_0")

    def test_compact_uncovered_cross(self):
        text = """Group : top::cg
Group Instance : cov
Summary for Variable direction
NAME COUNT AT LEAST
read 1 1
write 1 1
---
Summary for Variable event
NAME COUNT AT LEAST NUMBER
observed 0 1 1
---
Summary for Cross combined
direction event COUNT AT LEAST NUMBER
* * -- -- 2
"""
        rows=coverage_bins(text,"fresh")
        self.assertEqual(len(rows),5)
        self.assertEqual(rows[-1][4],"write / observed")
        self.assertIsNone(rows[-1][5])
        self.assertEqual(rows[-1][-1],"Uncovered")

    def test_native_test_attribution(self):
        text = """Group : top::cg
Group Instance : cov
Summary for Variable cp_full
NAME COUNT AT LEAST TEST COUNT TEST COUNT
observed 7 1 T3 4 T8 3
"""
        row = coverage_bins(text, "fresh", {"T3": "run-1", "T8": "run-2"})[0]
        self.assertEqual(row[5:8], [7, 1, "Covered"])
        self.assertEqual(row[8], "run-1 (4), run-2 (3)")
        with self.assertRaises(KeyError):
            coverage_bins(text, "fresh", {"T3": "run-1"})

    def test_stimulus_settings_exclude_checks_and_runner_details(self):
        schedule = dict(check_min_outstanding=32, min_unique="8", seed="17",
                        init_phase="1", preload="1", data_case="1", reorder_test="2",
                        stress_test="1", backpressure="0", capacity_target="rob",
                        response_hold_cycles="256", response_random_delay="1",
                        response_error="0", source_response_hold_cycles="1024")
        self.assertEqual(stimulus_settings(schedule),
                         "source_response_hold_cycles=1024 response_random_delay=1 response_hold_cycles=256")
        self.assertEqual(schedule["check_min_outstanding"], 32)

    def test_empty_report_rejected(self):
        with self.assertRaises(ValueError):
            coverage_bins("", "fresh")

if __name__=="__main__": unittest.main()
