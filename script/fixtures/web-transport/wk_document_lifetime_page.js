'use strict';
const parameters = new URL(location.href).searchParams;
const label = parameters.get('case'), count = Number(parameters.get('count') || 1);
window.pageSettled = false;
window.__pageHeaders = [];
window.pagePending = Promise.all(Array.from({length: count}, async (_, index) => {
  const target = new URL('/media/lifetime', location.href);
  target.searchParams.set('case', label + '-' + index);
  target.searchParams.set('hold', parameters.get('hold') || '1');
  const pending = fetch(target.href, {credentials: 'include', cache: 'no-store'});
  const native = window.__lifetimeNative[index];
  const response = await pending;
  const before = response.bodyUsed;
  window.__pageHeaders.push({sameNativePromise: pending === native.promise, sameNativeResponse: response === native.response,
    bodyUsedBefore: before, status: response.status, documentCookie: document.cookie});
  const bytes = new Uint8Array(await response.arrayBuffer());
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  let secondReadError;
  try { await response.arrayBuffer(); } catch (error) { secondReadError = error.name; }
  return {sameNativePromise: pending === native.promise, sameNativeResponse: response === native.response,
    bodyUsedBefore: before, bodyUsedAfter: response.bodyUsed, secondReadError,
    status: response.status, bytes: bytes.byteLength,
    sha256: Array.from(digest, byte => byte.toString(16).padStart(2, '0')).join(''),
    documentCookie: document.cookie};
})).then(value => { window.pageSettled = true; return value; });
