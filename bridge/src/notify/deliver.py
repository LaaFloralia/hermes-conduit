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
os.environ['HERMES_HOME'] = str(home / '.hermes/profiles/laa-monet')
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
    if payload.get('type') == 'decision.badge':
        # The sole content-free control event: relay routing needs the count
        # in plaintext to set aps.badge without a notification extension.
        # Send no other fields, under the existing pairing credential.
        badge = payload.get('badge')
        if type(badge) is not int or not 0 <= badge <= 2**31 - 1:
            raise ValueError('invalid badge')
        event = {'type': 'decision.badge', 'event_id': payload['event_id'], 'badge': badge}
        targets = client.paired_devices()
        delivered = bool(targets)
        for _, state in targets:
            try:
                answer = client.request_json(f"{state['relay_url'].rstrip('/')}/v1/events", method='POST',
                                             credential=state['credential'], payload=event, timeout=5)
                delivered = (answer.get('delivered') is True or answer.get('duplicate') is True) and delivered
            except Exception:
                delivered = False
        result = {'delivered': delivered}
    elif client.load_state() is None:
        result = {'delivered': False, 'reason': 'not_paired'}
    else:
        client.send_now(payload, timeout=15)
        result = {'delivered': True}
except Exception:
    result = {'delivered': False, 'reason': 'delivery_unavailable'}
print(json.dumps(result))
