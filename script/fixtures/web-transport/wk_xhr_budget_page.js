/* Original page request and body consumption; observation adds no media GET. */
(() => {
  const query=new URLSearchParams(location.search), type=query.get('type');
  const target=new URL(query.get('target'),location.href);
  target.searchParams.set('case',query.get('case'));
  const digest=async bytes=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),b=>b.toString(16).padStart(2,'0')).join('');
  window.pagePending=new Promise(resolve=>{
    const xhr=new XMLHttpRequest(), events=[];
    xhr.open('GET',target.href);xhr.responseType=type;xhr.withCredentials=true;
    for (const name of ['readystatechange','load','error','abort','loadend'])
      xhr.addEventListener(name,()=>events.push(name+':'+xhr.readyState),{once:name!=='readystatechange'});
    xhr.onloadend=async()=>{
      const response=xhr.response;
      let bytes, textUnits=null;
      if(type==='arraybuffer') bytes=new Uint8Array(response);
      else if(type==='blob') bytes=new Uint8Array(await response.arrayBuffer());
      else {const text=xhr.responseText;textUnits=text.length;bytes=new TextEncoder().encode(text);}
      const sha256=await digest(bytes);
      setTimeout(()=>resolve({type,status:xhr.status,url:xhr.responseURL,
        responseIdentity:response===xhr.response,sendReturnedUndefined:window.__sendResult===undefined,
        events,bytes:bytes.byteLength,sha256,textUnits,documentCookie:document.cookie}),0);
    };
    window.__sendResult=xhr.send();
  });
})();
