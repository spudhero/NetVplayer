/* Test target only. Snapshots mitigate tested fetch and XHR prototype replacements,
 * not arbitrary page attestation, DOM transport or bounded WebKit tee queues.
 * No fetch is issued here. Original Promise, Response and XHR objects go to page.
 * The acknowledged native bridge is bounded; Response.clone() upstream is not.
 */
(() => {
  'use strict';
  const SESSION = '__SESSION__', CHUNK = 8192, LIMIT = 1048576;
  const post = window.webkit.messageHandlers.responseClone.postMessage.bind(window.webkit.messageHandlers.responseClone);
  const nativeFetch = window.fetch, nativeSend = XMLHttpRequest.prototype.send;
  // Capture before page scripts. Do not look up these methods/getters again
  // when a response arrives or while acknowledged bridge chunks are read.
  const apply = Reflect.apply, then = Promise.prototype.then;
  const cloneResponse = Response.prototype.clone, getHeader = Headers.prototype.get;
  const responseGetters = Object.fromEntries(['url','type','body','headers','status','redirected']
    .map(name => [name, Object.getOwnPropertyDescriptor(Response.prototype, name).get]));
  const field = (response, name) => apply(responseGetters[name], response, []);
  const getReader = ReadableStream.prototype.getReader, cancelStream = ReadableStream.prototype.cancel;
  const readReader = ReadableStreamDefaultReader.prototype.read;
  const cancelReader = ReadableStreamDefaultReader.prototype.cancel;
  const releaseReader = ReadableStreamDefaultReader.prototype.releaseLock;
  const typedArrayPrototype = Object.getPrototypeOf(Uint8Array.prototype);
  const getLength = Object.getOwnPropertyDescriptor(typedArrayPrototype, 'length').get;
  const getByteLength = Object.getOwnPropertyDescriptor(typedArrayPrototype, 'byteLength').get;
  const fromCharCode = String.fromCharCode, encode64 = window.btoa;
  const NativeURL = URL, nativeNumber = Number;

  const addListener = EventTarget.prototype.addEventListener;
  const removeListener = EventTarget.prototype.removeEventListener;
  const xhrGetters = Object.fromEntries(['responseURL','responseType','response','responseText','status']
    .map(name => [name, Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, name).get]));
  const xhrField = (xhr, name) => apply(xhrGetters[name], xhr, []);
  const NativeBlob = Blob, blobStream = Blob.prototype.stream;
  const arrayBufferSlice = ArrayBuffer.prototype.slice;

  const emit = message => post({session: SESSION, ...message});
  const note = (reason, extra = {}) => { void emit({op:'note', reason, ...extra}).catch(() => {}); };
  const base64 = (bytes, offset, length) => {
    // Read the source range directly; no page-defined byte-view constructor runs.
    let text = '';
    for (let index = 0; index < length; index++) text += fromCharCode(bytes[offset + index]);
    return apply(encode64, window, [text]);
  };
  const eligibleURL = url => { try { return new NativeURL(url, location.href).pathname.startsWith('/media/'); } catch { return false; } };

  async function transfer(stream, meta) {
    let cap, reader;
    try {
      // Native supplies a random transfer capability, bound to session + frame.
      const opened = await emit({op:'open', ...meta, claimedOrigin:'https://forged.invalid'});
      cap = opened.cap;
      reader = apply(getReader,stream,[]);
      let seq=0, total=0;
      while (true) {
        const {done, value} = await apply(readReader,reader,[]);
        if (done) break;
        // A browser read/tee chunk is NOT subject to CHUNK. Only bridge messages are.
        if (total + apply(getByteLength,value,[]) > LIMIT) throw Error('decoded-body-limit');
        const length = apply(getLength,value,[]);
        for (let offset=0; offset<length; offset+=CHUNK) {
          const remaining = length-offset, count = remaining < CHUNK ? remaining : CHUNK;
          await emit({op:'chunk',cap,seq,offset:total,data:base64(value,offset,count)});
          total += count; seq++;
        }
      }
      await emit({op:'close',cap,seq,total});
    } catch (e) {
      if (cap) { try { await emit({op:'cancel',cap,reason:String(e.message)}); } catch {} }
      note('capture-stopped', {detail:String(e.message)});
    } finally {
      // Never await tee cancellation: it can wait for the original page branch.
      if (reader) { void apply(cancelReader,reader,[]).catch(() => {}); apply(releaseReader,reader,[]); }
      else { void apply(cancelStream,stream,[]).catch(() => {}); }
    }
  }

  function observeFetch(response) {
    const url=field(response,'url'), type=field(response,'type');
    if (!eligibleURL(url)) return;
    if (!['basic','cors'].includes(type) || !field(response,'body')) { note('unreadable', {type}); return; }
    const declared = nativeNumber(apply(getHeader,field(response,'headers'),['Content-Length']));
    if (declared > LIMIT) { note('declared-body-limit'); return; }
    let copy;
    try { copy=apply(cloneResponse,response,[]); } catch (e) { note('clone-failed',{detail:e.name}); return; }
    void transfer(field(copy,'body'), {api:'fetch',url,type,status:field(response,'status'),redirected:field(response,'redirected'),byteSemantics:'response-body'});
  }
  window.fetch = function(...args) {
    const pending=apply(nativeFetch,this,args);
    // Return the ORIGINAL promise, and never replace the page's Response/body APIs.
    void apply(then,pending,[response => { try { observeFetch(response); } catch { note('observer-error'); } }, () => { note('fetch-rejected'); }]);
    return pending;
  };

  XMLHttpRequest.prototype.send = function(...args) {
    const xhr=this;
    const loaded = () => {
      const url=xhrField(xhr,'responseURL'), status=xhrField(xhr,'status');
      if (!eligibleURL(url) || status===0) return;
      const type=xhrField(xhr,'responseType');
      let stream, semantics='response-body';
      if (type==='arraybuffer') {
        const copy=apply(arrayBufferSlice,xhrField(xhr,'response'),[0]);
        stream=apply(blobStream,new NativeBlob([copy]),[]);
      } else if (type==='blob') stream=apply(blobStream,xhrField(xhr,'response'),[]);
      else if (type==='' || type==='text') {
        // Re-encoding a decoded string does not establish original HTTP bytes.
        stream=apply(blobStream,new NativeBlob([xhrField(xhr,'responseText')]),[]);
        semantics='utf8-reencoded-text';
      } else { note('xhr-unsupported-type',{type}); return; }
      void transfer(stream,{api:'xhr',url,type,status,byteSemantics:semantics});
    };
    apply(addListener,xhr,['load',loaded,{once:true}]);
    apply(addListener,xhr,['loadend',()=>apply(removeListener,xhr,['load',loaded]),{once:true}]);
    try { return apply(nativeSend,this,args); }
    catch(e) { apply(removeListener,xhr,['load',loaded]); throw e; }
  };
})();
