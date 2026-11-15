/* Original fixture page logic, run from HTML script at navigation (no native fetch).
 * It also runs without the observer as the comparison for page-visible semantics.
 */
(() => {
  const q=new URLSearchParams(location.search), label=q.get('case'), scenario=q.get('scenario')||'fetch';
  const media=(path='body.mp4',extra={})=>{const u=new URL('/media/'+path,location.href);u.search=new URLSearchParams({case:label,...extra});return u.href;};
  const digest=async bytes=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),b=>b.toString(16).padStart(2,'0')).join('');
  async function read(response,promise) {
    const before=response.bodyUsed, nativeResponse=response===window.__nativeResponse;
    const clone=response.clone();
    const [body,copy]=await Promise.all([response.arrayBuffer(),clone.arrayBuffer()]);
    let twice;try{await response.arrayBuffer();twice='unexpected';}catch(e){twice=e.name;}
    return {status:response.status,type:response.type,url:response.url,redirected:response.redirected,
      bytes:body.byteLength,sha256:await digest(body),cloneSHA256:await digest(copy),bodyUsedBefore:before,bodyUsedAfter:response.bodyUsed,
      sameNativePromise:promise===window.__nativePromise,sameNativeResponse:nativeResponse,secondReadError:twice,documentCookie:document.cookie,
      contentType:response.headers.get('Content-Type'),contentRange:response.headers.get('Content-Range')};
  }
  async function fetchCase() {
    const options=JSON.parse(q.get('options')||'{}');
    const target=q.get('target')||media('body.mp4');
    const request=new Request(target,{credentials:'include',...options});
    const p=fetch(request);try{return await read(await p,p);}catch(e){return {error:e.name};}
  }
  async function xhrOnce(xhr,type,target) {
    const events=[];
    xhr.open('GET',target);xhr.responseType=type;xhr.withCredentials=q.get('omit')!=='1';
    return await new Promise(resolve=>{
      for(const event of ['readystatechange','load','error','abort','loadend']) xhr.addEventListener(event,()=>events.push(event),{once:event!=='readystatechange'});
      xhr.onloadend=async()=>{
        const r=xhr.response;let bytes=new ArrayBuffer(0),text=null;
        if(type==='arraybuffer' && r) bytes=r;
        else if(type==='blob' && r) bytes=await r.arrayBuffer();
        else if(type==='' || type==='text') {text=xhr.responseText;bytes=new TextEncoder().encode(text).buffer;}
        else if(type==='json') text=JSON.stringify(r);
        else if(type==='document') text=r?.documentElement?.outerHTML||null;
        // Yield so loadend listeners have completed in both instrumented/control pages.
        setTimeout(async()=>resolve({type,status:xhr.status,url:xhr.responseURL,responseIdentity:r===xhr.response,
          sendReturnedUndefined:window.__sendResult===undefined,events,bytes:bytes.byteLength,sha256:await digest(bytes),text}),0);
      };
      window.__sendResult=xhr.send();
      if(q.get('abort')==='1') setTimeout(()=>xhr.abort(),20);
    });
  }
  async function run() {
    if(scenario==='fetch') return await fetchCase();
    if(scenario==='spoof') {
      Response.prototype.clone=function(){return new Response('forged-page-body');};
      return await fetchCase();
    }
    if(scenario==='xhr') {
      const type=q.get('type')||'', target=q.get('target')||media(type==='json'?'json':type==='document'?'document':type==='text'||type===''?'text':'body.mp4');
      const xhr=new XMLHttpRequest();const first=await xhrOnce(xhr,type,target);
      if(q.get('reuse')==='1') return {first,second:await xhrOnce(xhr,type,target+'&reuse=1')};
      return first;
    }
    if(scenario==='cache') {
      const target=media('cache',{payload:'cookie'}), cache=await caches.open('original-page-cache');
      const p=fetch(target,{credentials:'include'}), response=await p;
      await cache.put(target,response.clone()); const first=await read(response,p);
      await fetch('/rotate'); const cached=await cache.match(target); const second=await cached.text();
      return {first,second,documentCookie:document.cookie};
    }
    if(scenario==='http-cache') {
      const target=media('http-cache',{cache:'1',payload:'cookie'});
      const p=fetch(target,{credentials:'include'});const first=await read(await p,p);
      await fetch('/rotate');const next=fetch(target,{credentials:'include',cache:'force-cache'});
      return {first,second:await read(await next,next)};
    }
    if(scenario==='abort') {
      window.abortController=new AbortController();
      window.originalPending=fetch(q.get('target'),{signal:abortController.signal});
      try {return await read(await originalPending,originalPending);}catch(e){return {error:e.name};}
    }
    if(scenario==='frames') {
      const results=[];
      return await new Promise(resolve=>{
        window.addEventListener('message',event=>{if(event.data?.fixture==='child'){results.push({origin:event.origin,result:event.data.result});if(results.length===2)resolve({children:results});}});
        for(const host of ['video.example.test','sibling.example.test']) {
          const src=new URL('/clone/page',`https://${host}`);
          src.search=new URLSearchParams({scenario:'fetch',case:label+'-'+host,seed:'0',child:'1',target:media('frame.mp4',{case:label+'-'+host,expect:host==='video.example.test'?'fresh':''}).replace('video.example.test',host)});
          const frame=document.createElement('iframe');frame.src=src.href;document.body.append(frame);
        }
      });
    }
    throw Error('unknown fixture scenario');
  }
  window.pageDone=false;
  window.pagePending=run().then(value=>{window.pageResult=value;window.pageDone=true;if(q.get('child')==='1')parent.postMessage({fixture:'child',result:value},'*');return value;},e=>{window.pageResult={fatal:e.name,message:e.message};window.pageDone=true;});
})();
