(() => {
    const c = generationConfig, instance = Array.from(crypto.getRandomValues(new Uint8Array(16)), v => v.toString(16).padStart(2, '0')).join('');
    let fetchCalls = 0, xhrCalls = 0, playCalls = 0;
    const fetch = window.fetch, send = XMLHttpRequest.prototype.send, play = HTMLMediaElement.prototype.play;
    window.fetch = function() { fetchCalls++; return fetch.apply(this, arguments); };
    XMLHttpRequest.prototype.send = function() { xhrCalls++; return send.apply(this, arguments); };
    HTMLMediaElement.prototype.play = function() { playCalls++; return play.apply(this, arguments); };
    function report(stage, extra = {}) {
        window.webkit.messageHandlers.generation.postMessage({stage, instance, phase: c.phase, frame: c.frame,
            url: location.href, fetchCalls, xhrCalls, playCalls, ...extra});
    }
    function emit(label) {
        const media = document.createElement('video'); media.preload = 'none';
        media.src = '/candidate/' + label + '?case=' + c.case;
        document.body.appendChild(media); report('candidate', {candidate: media.src});
    }
    window.emitLate = () => emit('late');
    let child, removed;
    function makeFrame() {
        child = document.createElement('iframe'); child.name = 'same-frame-name';
        child.src = (c.mode === 'frame-cross' ? 'https://sibling.example.test' : location.origin) +
            '/generation/frame?case=' + c.case + '&mode=' + c.mode;
        document.body.appendChild(child);
    }
    window.advance = () => {
        report('advance');
        if (c.mode === 'navigate') location.replace(location.href + '&next=1');
        else if (c.mode === 'reload') location.reload();
        else if (c.mode === 'hash') { location.hash = 'same-document'; report('same-document'); }
        else if (c.mode === 'frame-cross') child.src = child.src;
        else if (c.mode === 'frame-replace' || c.mode === 'frame-remove') {
            removed = child.contentWindow; child.remove(); report('removed');
            try { removed.emitLate(); report('late-attempted'); } catch (_) { report('late-context-gone'); }
            if (c.mode === 'frame-replace') makeFrame(); else emit('current');
        } else if (c.mode === 'sibling') {
            child.remove(); makeFrame(); report('sibling-replaced');
        }
    };
    report('ready');
    if (c.frame) {
        if (c.mode !== 'sibling') { emit(c.phase === 'old' ? 'old' : 'current'); if (c.phase === 'old') emit('queued'); }
    } else if (c.mode.startsWith('frame-')) makeFrame();
    else {
        emit(c.phase === 'old' ? 'old' : 'current');
        if (c.phase === 'old') emit('queued');
        if (c.mode === 'sibling') makeFrame();
    }
})();
