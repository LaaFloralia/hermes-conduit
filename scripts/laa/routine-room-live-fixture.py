"""Loopback-only read adapter for the actual production hosted-room DB.
No content is logged or cached. No auth configuration is changed.
"""
import importlib.util,json,pathlib,urllib.parse
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
source=pathlib.Path(__file__).resolve().parents[2] / 'bridge/src/routines/delivery.py'
s=importlib.util.spec_from_file_location('routine_delivery',source);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);m.bootstrap()
from gateway import hosted_rooms as rooms
path=pathlib.Path.home() / '.hermes/shared-state.db'
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_GET(self):
  query=urllib.parse.urlparse(self.path);params=urllib.parse.parse_qs(query.query)
  if query.path=='/room':
   result=next(r for r in rooms.list_rooms(path) if r['room_id']==m.ROOM_ID)
  elif query.path=='/events':
   result=rooms.read_events(path,room_id=m.ROOM_ID,since_seq=int(params.get('since',['0'])[0]),limit=200)
  elif query.path=='/target':
   page=rooms.read_events(path,room_id=m.ROOM_ID,since_seq=0,limit=500)
   event=next(e for e in reversed(page['events']) if e['event_id'].startswith('routine:'))
   result={'session_id':f"{m.PREFIX}{m.ROOM_ID}:{event['seq']}:{event['event_id']}"}
  else:
   self.send_error(404);return
  body=json.dumps(result,ensure_ascii=False).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
ThreadingHTTPServer(('127.0.0.1',19739),Handler).serve_forever()
