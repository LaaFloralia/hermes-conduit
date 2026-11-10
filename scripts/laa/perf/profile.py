#!/usr/bin/env python3
"""Capture the simulator app's CPU, hangs, SwiftUI updates and signposts.

Run while the navigation test is exercising the app. Traces may contain private
on-screen text; keep them in local work/build storage, never commit them.
"""
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--device', default='DFFD3966-F54E-4C7A-A161-59201C7EA105')
parser.add_argument('--process', default='Conduit')
parser.add_argument('--seconds', type=int, default=30)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
if not 1 <= args.seconds <= 60:
    parser.error('--seconds must be between 1 and 60')
subprocess.run(['xcrun', 'xctrace', 'record', '--template', 'Time Profiler',
                '--instrument', 'Hangs', '--instrument', 'SwiftUI', '--instrument', 'os_signpost',
                '--device', args.device, '--attach', args.process, '--time-limit', f'{args.seconds}s',
                '--output', str(args.output), '--no-prompt'], check=True)
with args.output.with_suffix('.toc.xml').open('w') as output:
    subprocess.run(['xcrun', 'xctrace', 'export', '--input', str(args.output), '--toc'],
                   stdout=output, check=True)
