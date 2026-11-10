"""Synthetic checks for the regression measurement report; no Bridge calls."""
import unittest
import plistlib
import tempfile
from pathlib import Path
from summarize import summarize
from run import focus_test_sources, TESTS


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


class FocusedProjectTests(unittest.TestCase):
    def test_only_selected_tests_are_compiled_and_app_sources_are_preserved(self):
        objects = {
            'app': {'isa': 'PBXNativeTarget', 'name': 'Conduit', 'buildPhases': ['app-phase']},
            'app-phase': {'isa': 'PBXSourcesBuildPhase', 'files': ['application-source']},
        }
        for target in ['ConduitTests', 'ConduitUITests']:
            files = []
            names = [test.split('/')[1] + '.swift' for test in TESTS if test.startswith(target + '/')]
            names += ['UnrelatedDebugOnly.swift']
            for index, name in enumerate(names):
                file = target + str(index)
                objects[file] = {'isa': 'PBXBuildFile', 'fileRef': file + '-ref'}
                objects[file + '-ref'] = {'isa': 'PBXFileReference', 'path': name}
                files.append(file)
            objects[target] = {'isa': 'PBXNativeTarget', 'name': target, 'buildPhases': [target + '-phase']}
            objects[target + '-phase'] = {'isa': 'PBXSourcesBuildPhase', 'files': files}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'project.pbxproj'
            path.write_bytes(plistlib.dumps({'objects': objects}))
            focus_test_sources(Path(directory))
            result = plistlib.loads(path.read_bytes())['objects']
        self.assertEqual(result['app-phase']['files'], ['application-source'])
        self.assertEqual(len(result['ConduitTests-phase']['files']), 4)
        self.assertEqual(len(result['ConduitUITests-phase']['files']), 1)


if __name__ == '__main__':
    unittest.main()
