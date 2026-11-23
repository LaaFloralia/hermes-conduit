"""Synthetic checks for the regression measurement report; no Bridge calls."""
import unittest
from summarize import summarize


class SummaryTests(unittest.TestCase):
    def test_only_completed_samples_contribute_to_median(self):
        result = summarize('\n'.join([
            'prefix LAA_PERF {"metric":"open","iteration":1,"ms":3,"ready":true}',
            'LAA_PERF {"metric":"open","iteration":2,"ms":1000,"ready":false}',
            'LAA_PERF {"metric":"open","iteration":3,"ms":7,"ready":true}',
            'LAA_PERF_UNAVAILABLE live_send',
        ]))
        self.assertEqual(result['metrics']['open']['median_ms'], 5)
        self.assertEqual(result['metrics']['open']['count'], 2)
        self.assertEqual(result['failed_samples_ms'], {'open': [1000]})
        self.assertEqual(result['incomplete_metrics'], ['open'])
        self.assertEqual(result['unavailable'], ['live_send'])

    def test_missing_and_failed_metrics_are_never_zero_or_success(self):
        result = summarize('LAA_PERF {"metric":"offline","iteration":1,"ms":8000,"ready":false}')
        self.assertEqual(result['metrics'], {})
        self.assertEqual(result['failed_samples_ms'], {'offline': [8000]})

    def test_complete_five_runs_are_reported(self):
        result = summarize('\n'.join(
            'LAA_PERF {"metric":"open","iteration":%d,"ms":%d,"ready":true}' % (i, i)
            for i in range(1, 6)))
        self.assertEqual(result['metrics']['open']['median_ms'], 3)
        self.assertEqual(result['incomplete_metrics'], [])


if __name__ == '__main__':
    unittest.main()
