"""Exercise the release wrapper without credentials, Xcode, or Apple services."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


class ReleaseQueueTests(unittest.TestCase):
    def test_next_upload_can_start_during_apple_processing(self):
        source = (Path(__file__).parents[1] / 'laa/testflight.sh').read_text()
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            script = root / 'repo/scripts/laa/testflight.sh'
            script.parent.mkdir(parents=True)
            helper = root / 'storage.py'
            helper.write_text('import os, sys\nos.execvp(sys.argv[2], sys.argv[2:])\n')
            slot = root / 'slot.sh'
            slot.write_text('#!/bin/bash\nexec /usr/bin/python3 /Users/laa/hq/harness/lock_run.py "$TEST_SLOT" 10 "$@"\n')
            node = root / 'bin/node'
            node.parent.mkdir()
            node.write_text('#!/bin/bash\nprintf "%s wait-start\\n" "$TEST_LABEL" >> "$TEST_LOG"\nsleep 3\nprintf "%s wait-end\\n" "$TEST_LABEL" >> "$TEST_LOG"\n')
            node.chmod(0o755)
            fake_build = '''if [ "${LAA_TF_BUILD_PHASE:-}" = 1 ]; then
  printf '%s build\\n' "$TEST_LABEL" >> "$TEST_LOG"
  printf '%s\\n' "$TEST_NUMBER" > "$LAA_TF_RESULT_FILE"
  sleep 0.3
  exit 0
fi
'''
            source = source.replace('storage=/Users/laa/hq/harness/build_storage.py', f'storage={helper}')
            source = source.replace('slot=/Users/laa/hq/harness/build-slot.sh', f'slot={slot}')
            source = source.replace('work=""\nteam=', fake_build + 'work=""\nteam=', 1)
            script.write_text(source)
            log = root / 'timeline'
            home = root / 'home'
            home.mkdir()
            common = dict(os.environ, HOME=str(home), PATH=f'{node.parent}:/usr/bin:/bin',
                          TEST_SLOT=str(root / 'slot.lock'), TEST_LOG=str(log))
            first = subprocess.Popen(['/bin/bash', str(script)], env=dict(common, TEST_LABEL='one', TEST_NUMBER='101'),
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            second = None
            try:
                deadline = time.monotonic() + 8
                while time.monotonic() < deadline:
                    if log.exists() and 'one wait-start' in log.read_text():
                        break
                    time.sleep(0.05)
                else:
                    self.fail('first release never reached Apple processing')
                second = subprocess.Popen(['/bin/bash', str(script)], env=dict(common, TEST_LABEL='two', TEST_NUMBER='102'),
                                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                out2, err2 = second.communicate(timeout=10)
                out1, err1 = first.communicate(timeout=10)
                self.assertEqual(first.returncode, 0, (out1, err1))
                self.assertEqual(second.returncode, 0, (out2, err2))
                events = log.read_text().splitlines()
                self.assertLess(events.index('one wait-start'), events.index('two build'))
                self.assertLess(events.index('two build'), events.index('one wait-end'))
            finally:
                for process in (first, second):
                    if process is not None and process.poll() is None:
                        process.terminate()
                        process.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
