/* Original fixture page: only DOM/native media loads. No fetch, XHR, or observer GET. */
(() => {
  'use strict';
  const cfg=window.nativeConfig, events=[];
  let v=document.getElementById('original');
  if (!v) {
    v=document.createElement('video');v.id='original';v.preload='auto';v.muted=true;v.playsInline=true;
    if (cfg.crossorigin) v.crossOrigin=cfg.crossorigin;
    document.body.append(v);
  }
  for (const name of ['loadstart','loadedmetadata','loadeddata','canplay','playing','timeupdate','pause','abort','emptied','error']) {
    v.addEventListener(name,()=>events.push(name));
  }
  const snapshot=()=>({currentSrc:v.currentSrc,src:v.src,source:v.querySelector('source')?.src ?? '',
    readyState:v.readyState,networkState:v.networkState,error:v.error?.code ?? 0,duration:Number.isFinite(v.duration)?v.duration:null,
    currentTime:v.currentTime,width:v.videoWidth,height:v.videoHeight,paused:v.paused,events:[...events],
    documentCookie:document.cookie,apiCalls:{...window.__mediaAPICalls},
    quality:v.getVideoPlaybackQuality?.().totalVideoFrames ?? null,
    resources:performance.getEntriesByType('resource').filter(e=>e.name.includes('/media/')).map(e=>({name:e.name,initiatorType:e.initiatorType,transferSize:e.transferSize,encodedBodySize:e.encodedBodySize}))});
  window.nativeSnapshot=snapshot;
  window.cancelOriginal=()=>{v.pause();v.removeAttribute('src');v.querySelectorAll('source').forEach(s=>s.remove());v.load();return snapshot();};
  window.pagePending=(async()=>{
    const start=performance.now();
    while (v.readyState<2 && !v.error && performance.now()-start<6000) await new Promise(r=>setTimeout(r,20));
    let playError=null;
    if (v.readyState>=2) {
      try {
        await v.play();
        const t=performance.now();
        while (v.currentTime<0.25 && !v.error && performance.now()-t<4000) await new Promise(r=>setTimeout(r,20));
        v.pause();
      } catch(e) {playError=e.name;}
    }
    let canvas=null;
    if (v.readyState>=2) {
      const c=document.createElement('canvas');c.width=2;c.height=2;
      try {
        const ctx=c.getContext('2d');ctx.drawImage(v,0,0,2,2);
        const pixels=ctx.getImageData(0,0,2,2).data;
        canvas={readable:true,pixelBytes:pixels.length};
      } catch(e) {canvas={readable:false,error:e.name};}
    }
    return {...snapshot(),outcome:v.error?'error':v.readyState>=2?'loaded':'timeout',playError,canvas};
  })();
  if (cfg.mode==='dynamic-src') v.src=cfg.target;
})();
