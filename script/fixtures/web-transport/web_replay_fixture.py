#!/usr/bin/env python3
"""Loopback-only browser/replay collector; contains no source-service requests."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
import json, os, threading

os.umask(0o077)
rows=[]
lock=threading.Lock()
output=Path(os.environ['NETVPLAYER_WEB_REPLAY_RECORDS'])
output.parent.mkdir(parents=True,exist_ok=True)
capture=output.open('x')

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_OPTIONS(self):
        self.record(403)
        self.send_response(403);self.send_header('Content-Length','0');self.end_headers()
    def record(self,status):
        row={'path':urlsplit(self.path).path,'query':urlsplit(self.path).query,
             'method':self.command,'headers':{k.lower():v for k,v in self.headers.items()},
             'actor':self.headers.get('X-Fixture-Actor','browser'),'status':status}
        with lock:
            rows.append(row);capture.write(json.dumps(row)+'\n');capture.flush()
    def do_GET(self):
        path=urlsplit(self.path).path
        if path=='/records':
            with lock: payload=json.dumps(rows).encode()
            self.reply(200,payload,'application/json',[]);return
        extra=[];mime='text/html';status=200
        if path.startswith('/page/'):
            scenario=path.rsplit('/',1)[1]
            media='/media/'+scenario+'.m3u8'
            target=media
            config="{credentials:'include'}"
            if scenario=='omit':config="{credentials:'omit'}"
            elif scenario=='same-origin':config='{}'
            elif scenario=='cross-host':target='http://localhost:'+str(self.server.server_port)+media
            elif scenario=='outside-path':target='/outside'+media
            elif scenario=='cors-denied':
                target='http://localhost:'+str(self.server.server_port)+media
                config="{credentials:'include',headers:{'X-Local-Token':'declared-only'}}"
            elif scenario in ['native-include','native-omit','native-range']:
                target='/media/'+scenario+'.mp4'
                if scenario=='native-omit':config="{credentials:'omit'}"
                if scenario=='native-range':config="{credentials:'omit',headers:{Range:'bytes=1-2'}}"
            if scenario.startswith('xhr'):
                if scenario=='xhr-cross-host':target='http://localhost:'+str(self.server.server_port)+media
                script="await new Promise(resolve=>{let x=new XMLHttpRequest();x.open('GET',"+json.dumps(target)+");x.onloadend=resolve;x.send()})"
            elif scenario=='cache':
                script="let cache=await caches.open('local-fixture');let response=await fetch('/media/cache.m3u8',{credentials:'include'});await cache.put('/media/cache.m3u8',response.clone());let a=await response.text();await fetch('/rotate');let b=await (await cache.match('/media/cache.m3u8')).text();window.cacheProof=[a,b];"
            else:
                script="try { await (await fetch("+json.dumps(target)+","+config+")).arrayBuffer() } catch (_) {}"
            script="(async()=>{"+script+";await fetch('/settled?scenario="+scenario+"'+(window.cacheProof?'&cache='+encodeURIComponent(JSON.stringify(window.cacheProof)):''))})()"
            payload=('<script>'+script+'</script>').encode()
            if scenario!='no-seed':extra=[('Set-Cookie','account=fresh; Path=/media; HttpOnly')]
            if scenario=='expired':extra=[('Set-Cookie','account=gone; Path=/media; HttpOnly; Max-Age=0')]
        elif path=='/rotate':
            payload=b'rotated';extra=[('Set-Cookie','account=second; Path=/media; HttpOnly')]
        elif '/media/' in path:
            scenario=path.rsplit('/',1)[1].split('.')[0]
            if scenario.startswith('redirect-'):
                status=302;payload=b''
                if scenario=='redirect-same':
                    destination='/media/final.m3u8';extra=[('Set-Cookie','account=redirected; Path=/media; HttpOnly')]
                elif scenario=='redirect-path':destination='/outside/media/final.m3u8'
                else:destination='http://localhost:'+str(self.server.server_port)+'/media/final.m3u8'
                extra.append(('Location',destination))
            else:
                expected={'include':'account=fresh','same-origin':'account=fresh','xhr':'account=fresh',
                          'cache':'account=fresh','hold':'account=fresh','native-include':'account=fresh'}.get(scenario,'')
                if scenario=='final' and path.startswith('/media/') and self.headers.get('Host','').startswith('127.0.0.1:'):
                    expected='account=redirected'
                cookie=self.headers.get('Cookie','')
                if cookie!=expected:status=403
                mime='application/vnd.apple.mpegurl'
                payload=(cookie if scenario=='cache' else '#EXTM3U\n#EXT-X-ENDLIST\n').encode()
                if scenario=='cache':extra=[('Cache-Control','private, max-age=3600')]
                if path.endswith('.mp4'):
                    mime='video/mp4'
                    payload=Path(os.environ['NETVPLAYER_FEATURE_FIXTURE']).read_bytes() if status==200 else b'cookie-required'
                    if status==200 and self.headers.get('Range')=='bytes=1-2':
                        extra.append(('Content-Range','bytes 1-2/'+str(len(payload))))
                        payload=payload[1:3];status=206
        else:payload=b'ok'
        self.record(status)
        self.reply(status,payload,mime,extra)
    def reply(self,status,payload,mime,extra):
        self.send_response(status)
        self.send_header('Access-Control-Allow-Origin',self.headers.get('Origin','*'))
        self.send_header('Access-Control-Allow-Credentials','true')
        self.send_header('Content-Type',mime);self.send_header('Content-Length',str(len(payload)))
        if not any(k=='Cache-Control' for k,v in extra):self.send_header('Cache-Control','no-store')
        for k,v in extra:self.send_header(k,v)
        self.end_headers()
        try:self.wfile.write(payload)
        except (BrokenPipeError,ConnectionResetError):pass

server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
print(server.server_port,flush=True)
server.serve_forever()
