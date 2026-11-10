#!/usr/bin/env python3
"""Read-only latency probes; response bodies and private URLs are never logged."""
import argparse
import json
import statistics
import time
import urllib.request
from datetime import datetime, timezone


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--endpoint', action='append', required=True, metavar='LABEL=URL')
    parser.add_argument('--repeats', type=int, default=5)
    parser.add_argument('--timeout', type=float, default=10)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    results = {}
    for endpoint in args.endpoint:
        label, url = endpoint.split('=', 1)
        samples = []
        for _ in range(args.repeats):
            sampled_at = datetime.now(timezone.utc).isoformat()
            start = time.perf_counter()
            status, error = None, None
            try:
                with urllib.request.urlopen(url, timeout=args.timeout) as response:
                    status = response.status
                    # Include the response transfer, discard the private body.
                    while response.read(65536):
                        pass
            except Exception as exc:
                # Exception messages may contain URLs or credentials.
                error = type(exc).__name__
            samples.append(dict(sampled_at=sampled_at, ms=round((time.perf_counter() - start) * 1000, 2),
                                status=status, error=error))
        successful = [item['ms'] for item in samples if item['error'] is None]
        results[label] = dict(samples=samples, completed=len(successful),
                              median_ms=statistics.median(successful) if successful else None)
    with open(args.output, 'w') as output:
        json.dump(results, output, indent=2)
        output.write('\n')
    print(json.dumps(results))


if __name__ == '__main__':
    main()
