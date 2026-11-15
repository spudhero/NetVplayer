/* Test target only. This deliberately does NOT claim bounded WebKit tee queues.
 * No fetch is issued here. Original Promise, Response and XHR objects go to page.
 * The acknowledged native bridge is bounded; Response.clone() upstream is not.
 */
(() => {
  'use strict';
  const SESSION = '__SESSION__', CHUNK = 8192, LIMIT = 1048576;
  const post = window.webkit.messageHandlers.responseClone.postMessage.bind(window.webkit.messageHandlers.responseClone);
  const nativeFetch = window.fetch, nativeSend = XMLHttpRequest.prototype.send;
  const emit = message => post({session: SESSION, ...message});
  const note = (reason, extra = {}) => { void emit({op:'note', reason, ...extra}).catch(() => {}); };
  const base64 = bytes => { let s=''; for (const b of bytes) s += String.fromCharCode(b); return btoa(s); };
  const eligibleURL = url => { try { return new URL(url, location.href).pathname.startsWith('/media/'); } catch { return false; } };

  async function transfer(stream, meta) {
    let cap, reader;
    try {
      // Native supplies a random transfer capability, bound to session + frame.
      const opened = await emit({op:'open', ...meta, claimedOrigin:'https://forged.invalid'});
      cap = opened.cap;
      reader = stream.getReader();
      let seq=0, total=0;
      while (true) {
        const {done, value} = await reader.read();
        if (done) break;
        // A browser read/tee chunk is NOT subject to CHUNK. Only bridge messages are.
        if (total + value.byteLength > LIMIT) throw Error('decoded-body-limit');
        for (let offset=0; offset<value.length; offset+=CHUNK) {
          const part = value.subarray(offset, offset+CHUNK);
          await emit({op:'chunk',cap,seq,offset:total,data:base64(part)});
          total += part.length; seq++;
        }
      }
      await emit({op:'close',cap,seq,total});
    } catch (e) {
      if (cap) { try { await emit({op:'cancel',cap,reason:String(e.message)}); } catch {} }
      note('capture-stopped', {detail:String(e.message)});
    } finally {
      // Never await tee cancellation: it can wait for the original page branch.
      if (reader) { void reader.cancel().catch(() => {}); reader.releaseLock(); }
      else { void stream.cancel().catch(() => {}); }
    }
  }

  function observeFetch(response) {
    if (!eligibleURL(response.url)) return;
    if (!['basic','cors'].includes(response.type) || !response.body) { note('unreadable', {type:response.type}); return; }
    const declared = Number(response.headers.get('Content-Length'));
    if (declared > LIMIT) { note('declared-body-limit'); return; }
    let copy;
    try { copy=response.clone(); } catch (e) { note('clone-failed',{detail:e.name}); return; }
    void transfer(copy.body, {api:'fetch',url:response.url,type:response.type,status:response.status,redirected:response.redirected,byteSemantics:'response-body'});
  }
  window.fetch = function(...args) {
    const pending=Reflect.apply(nativeFetch,this,args);
    // Return the ORIGINAL promise, and never replace the page's Response/body APIs.
    void pending.then(response => { try { observeFetch(response); } catch { note('observer-error'); } }, () => { note('fetch-rejected'); });
    return pending;
  };

  XMLHttpRequest.prototype.send = function(...args) {
    const xhr=this;
    const loaded = () => {
      if (!eligibleURL(xhr.responseURL) || xhr.status===0) return;
      const type=xhr.responseType;
      let stream, semantics='response-body';
      if (type==='arraybuffer') stream=new Blob([xhr.response.slice(0)]).stream();
      else if (type==='blob') stream=xhr.response.stream();
      else if (type==='' || type==='text') {
        // Decoded strings cannot attest original HTTP bytes (charset/BOM/decoding).
        stream=new Blob([xhr.responseText]).stream(); semantics='utf8-reencoded-text';
      } else { note('xhr-unsupported-type',{type}); return; }
      void transfer(stream,{api:'xhr',url:xhr.responseURL,type,status:xhr.status,byteSemantics:semantics});
    };
    xhr.addEventListener('load',loaded,{once:true});
    xhr.addEventListener('loadend',()=>xhr.removeEventListener('load',loaded),{once:true});
    try { return Reflect.apply(nativeSend,this,args); }
    catch(e) { xhr.removeEventListener('load',loaded); throw e; }
  };
})();
