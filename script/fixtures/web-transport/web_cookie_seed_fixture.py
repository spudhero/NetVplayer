#!/usr/bin/env python3
"""Loopback CONNECT receiver. Never resolves names or opens outbound sockets."""
import argparse, json, os, ssl, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs
from pathlib import Path

HOSTS = {'video.example.test','child.video.example.test','sibling.example.test',
         'other.test','example.test.evil.test','video.tenant.github.io',
         'video.example.co.uk','video.b.ck','video.www.ck','video.xn--bcher-kva.test'}

def main():
    p=argparse.ArgumentParser();p.add_argument('--root',type=Path,required=True);a=p.parse_args()
    os.umask(0o077);rows=[];lock=threading.Lock()
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(a.root/'cert.pem',a.root/'key.pem')
    capture=(a.root/'requests.jsonl').open('x')
    class Handler(BaseHTTPRequestHandler):
        protocol_version='HTTP/1.1'
        def log_message(self,*args):pass
        def do_CONNECT(self):
            host,_,port=self.path.rpartition(':')
            if host not in HOSTS or port not in ['80','443']:
                self.send_error(403);return
            self.send_response(200);self.end_headers();self.wfile.flush()
            self.tunnel_host=host;self.tls=port=='443'
            if self.tls:
                self.connection=context.wrap_socket(self.connection,server_side=True)
                self.rfile=self.connection.makefile('rb',-1);self.wfile=self.connection.makefile('wb',0)
            self.close_connection=False
        def do_GET(self):
            u=urlsplit(self.path);q=parse_qs(u.query);host=self.headers.get('Host','').split(':')[0]
            if host not in HOSTS and u.path!='/records':self.send_error(403);return
            if u.path=='/records':
                with lock:body=json.dumps(rows)
                mime='application/json'
            else:
                row=dict(host=host,path=u.path,query=u.query,tls=getattr(self,'tls',False),cookie=self.headers.get('Cookie',''),headers=dict(self.headers))
                with lock:rows.append(row);capture.write(json.dumps(row)+'\n');capture.flush()
                body='ok';mime='text/plain'
                if u.path in ['/scope/start','/scope/response','/scope/hold']:
                    probes=['/scope/probe','/scope/deep/probe','/scopeevil/probe','/outside/probe',
                            'http://child.video.example.test/scope/probe','http://sibling.example.test/scope/probe',
                            'http://other.test/scope/probe','http://example.test.evil.test/scope/probe']
                    if self.tls:probes=[x.replace('http:','https:') for x in probes]
                    js=''
                    if u.path=='/scope/hold':js="await fetch('/scope/held');"
                    else:
                        js='for(const url of '+json.dumps(probes)+") await fetch(url,{mode:'no-cors',credentials:'include'});"
                        js+="await fetch('/scope/js?value='+encodeURIComponent(document.cookie));"
                        if q.get('cross')==['1']:js+="location.href='https://other.test/cross/top';"
                        elif q.get('downgrade')==['1']:js+="location.href='http://"+host+"/downgrade';"
                        else:js+="window.webkit?.messageHandlers.done?.postMessage('done');let v=document.createElement('video');v.src='/done.m3u8';document.body.append(v);"
                    body='<script>(async()=>{'+js+'})().catch(e=>window.webkit?.messageHandlers.done?.postMessage(String(e)))</script>';mime='text/html'
                elif u.path=='/cross/top':
                    body="<script>location.href='https://video.example.test/scope/landing'</script>";mime='text/html'
                elif u.path=='/scope/landing':
                    body="<script>window.webkit.messageHandlers.done.postMessage('done')</script>";mime='text/html'
                elif u.path=='/downgrade':
                    body="<script>fetch('/scope/plain').then(()=>window.webkit.messageHandlers.done.postMessage('done'))</script>";mime='text/html'
            data=body.encode();self.send_response(200)
            if u.path=='/scope/response':self.send_header('Set-Cookie',q['seed'][0])
            self.send_header('Content-Type',mime);self.send_header('Content-Length',str(len(data)));self.end_headers()
            try:self.wfile.write(data)
            except (BrokenPipeError,ConnectionResetError):pass
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    print(server.server_port,flush=True);server.serve_forever()
if __name__=='__main__':main()
