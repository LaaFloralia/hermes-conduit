"""Use the installed Conduit plugin's pairing, redaction and E2E sender.
No credentials enter arguments, stdout or the Bridge's state.
"""
import json
import logging
import os
import sys
import types
from pathlib import Path

logging.disable(logging.CRITICAL)
home = Path.home()
sys.path.insert(0, str(home / '.local/share/hermes-agent'))
os.environ['HERMES_HOME'] = str(home / '.hermes/profiles/laa-ciel')
package = types.ModuleType('_laa_bridge_conduit')
package.__path__ = [str(home / '.hermes/plugins/conduit_push')]
sys.modules[package.__name__] = package
try:
    # The launcher uses a bare Python; Hermes keeps its installed dependencies
    # in a separately selected environment. Activate it before the plugin so
    # encryption cannot silently degrade because cryptography is absent.
    from pm.environments import activate_dependencies
    activate_dependencies(home / '.local/share/hermes-agent')
    from _laa_bridge_conduit import client
    payload = json.load(sys.stdin)
    if client.load_state() is None:
        result = {'delivered': False, 'reason': 'not_paired'}
    else:
        client.send_now(payload, timeout=15)
        result = {'delivered': True}
except Exception:
    result = {'delivered': False, 'reason': 'delivery_unavailable'}
print(json.dumps(result))
