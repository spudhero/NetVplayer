/* Test candidate: local fetch-clone lifetime and pre-clone concurrency admission.
 * Original Promise/Response objects and requests stay with the page.
 * This does not bound WebKit's upstream tee queue or attest arbitrary page code.
 */
(() => {
  'use strict';
  const SESSION = '__SESSION__', CHUNK = 8192, LIMIT = 1048576;
  const LIFETIME = __CAPTURE_LIFETIME_MS__, MAX_ACTIVE = 2;
  const apply = Reflect.apply, then = Promise.prototype.then;
  const post = window.webkit.messageHandlers.responseClone.postMessage.bind(window.webkit.messageHandlers.responseClone);
  const nativeFetch = window.fetch, cloneResponse = Response.prototype.clone;
  const getHeader = Headers.prototype.get;
  const getters = Object.fromEntries(['url', 'type', 'body', 'headers', 'status', 'redirected']
    .map(name => [name, Object.getOwnPropertyDescriptor(Response.prototype, name).get]));
  const field = (response, name) => apply(getters[name], response, []);
  const getReader = ReadableStream.prototype.getReader, cancelStream = ReadableStream.prototype.cancel;
  const readReader = ReadableStreamDefaultReader.prototype.read;
  const cancelReader = ReadableStreamDefaultReader.prototype.cancel;
  const releaseReader = ReadableStreamDefaultReader.prototype.releaseLock;
  const typed = Object.getPrototypeOf(Uint8Array.prototype);
  const getLength = Object.getOwnPropertyDescriptor(typed, 'length').get;
  const getByteLength = Object.getOwnPropertyDescriptor(typed, 'byteLength').get;
  const fromCharCode = String.fromCharCode, encode64 = window.btoa;
  const NativeURL = URL, nativeNumber = Number;
  const schedule = window.setTimeout, unschedule = window.clearTimeout;
  const addEvent = EventTarget.prototype.addEventListener;
  const active = new Set();
  const emit = message => post({session: SESSION, ...message});
  const note = (reason, detail = '') => { void emit({op: 'note', reason, detail}).catch(() => {}); };
  const base64 = (bytes, offset, length) => {
    // Read the source range directly; no page-defined byte-view constructor runs.
    let text = '';
    for (let index = 0; index < length; index++) text += fromCharCode(bytes[offset + index]);
    return apply(encode64, window, [text]);
  };
  const eligible = url => { try { return new NativeURL(url, location.href).pathname.startsWith('/media/'); } catch { return false; } };

  async function transfer(stream, metadata) {
    let cap, reader, stopped = '', readerCancelled = false, cancelSent = false;
    const stop = reason => {
      if (!stopped) stopped = reason;
      if (reader && !readerCancelled) {
        readerCancelled = true;
        // Cancellation closes pending reads; its promise may await the page tee.
        void apply(cancelReader, reader, [stopped]).catch(() => {});
      }
      if (cap && !cancelSent) {
        cancelSent = true;
        void emit({op: 'cancel', cap, reason: stopped}).catch(() => {});
      }
    };
    active.add(stop);
    const timer = apply(schedule, window, [() => stop('local-capture-deadline'), LIFETIME]);
    try {
      const opened = await emit({op: 'open', ...metadata, claimedOrigin: 'https://forged.invalid'});
      cap = opened.cap;
      if (stopped) { stop(stopped); throw Error(stopped); }
      reader = apply(getReader, stream, []);
      let seq = 0, total = 0;
      while (true) {
        const {done, value} = await apply(readReader, reader, []);
        if (stopped) throw Error(stopped);
        if (done) break;
        if (total + apply(getByteLength, value, []) > LIMIT) throw Error('decoded-body-limit');
        const length = apply(getLength, value, []);
        for (let offset = 0; offset < length; offset += CHUNK) {
          if (stopped) throw Error(stopped);
          const remaining = length - offset, count = remaining < CHUNK ? remaining : CHUNK;
          await emit({op: 'chunk', cap, seq, offset: total, data: base64(value, offset, count)});
          if (stopped) throw Error(stopped);
          total += count; seq++;
        }
      }
      if (stopped) throw Error(stopped);
      await emit({op: 'close', cap, seq, total});
    } catch (error) {
      stop(String(error.message));
      note('capture-stopped', stopped);
    } finally {
      apply(unschedule, window, [timer]);
      if (reader) {
        if (!readerCancelled) void apply(cancelReader, reader, []).catch(() => {});
        apply(releaseReader, reader, []);
      } else {
        void apply(cancelStream, stream, []).catch(() => {});
      }
      active.delete(stop);
    }
  }

  function observe(response) {
    const url = field(response, 'url'), type = field(response, 'type');
    if (!eligible(url)) return;
    if (!['basic', 'cors'].includes(type) || !field(response, 'body')) { note('unreadable'); return; }
    if (nativeNumber(apply(getHeader, field(response, 'headers'), ['Content-Length'])) > LIMIT) {
      note('declared-body-limit'); return;
    }
    // Claim a local slot synchronously before another Response.clone() can run.
    if (active.size >= MAX_ACTIVE) { note('local-capacity'); return; }
    let copy;
    try { copy = apply(cloneResponse, response, []); } catch (error) { note('clone-failed', error.name); return; }
    void transfer(field(copy, 'body'), {api: 'fetch', url, type, status: field(response, 'status'),
      redirected: field(response, 'redirected'), byteSemantics: 'response-body'});
  }
  apply(addEvent, window, ['pagehide', () => { for (const stop of active) stop('pagehide'); }]);
  window.fetch = function(...args) {
    const pending = apply(nativeFetch, this, args);
    void apply(then, pending, [response => { try { observe(response); } catch { note('observer-error'); } },
      () => { note('fetch-rejected'); }]);
    return pending;
  };
})();
