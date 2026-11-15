(() => {
    const c = historyConfig, instance = Array.from(crypto.getRandomValues(new Uint8Array(16)), v => v.toString(16).padStart(2, '0')).join('');
    let shows = 0, fetchCalls = 0, xhrCalls = 0, playCalls = 0;
    const play = HTMLMediaElement.prototype.play;
    HTMLMediaElement.prototype.play = function() { playCalls++; return play.apply(this, arguments); };
    const report = (stage, extra = {}) => window.webkit.messageHandlers.history.postMessage({stage, page: c.page, frame: c.frame, instance, url: location.href, shows, fetchCalls, xhrCalls, playCalls, ...extra});
    if (c.page === 'a' && !c.frame && ['iframe', 'cross-frame'].includes(c.api)) {
        const frame = document.createElement('iframe');
        frame.src = (c.api === 'cross-frame' ? 'https://sibling.example.test' : '') + '/history/frame' + location.search;
        document.body.appendChild(frame);
    }
    let media;
    if (c.page === 'a' && (c.api === 'dom' || c.frame)) {
        media = document.createElement('video'); media.preload = 'none'; media.src = '/history/media?case=' + c.case; document.body.appendChild(media);
    }
    window.addEventListener('pageshow', event => {
        shows++; report('pageshow', {persisted: event.persisted, trusted: event.isTrusted});
        if (c.page !== 'a' || ['dom', 'iframe', 'cross-frame'].includes(c.api)) return;
        const url = '/history/media?case=' + c.case;
        const headers = {'X-History-Instance': instance, 'X-History-Show': String(shows)};
        if (c.api === 'fetch') {
            fetchCalls++;
            const promise = fetch(url, {headers});
            promise.then(async response => {
                const before = response.bodyUsed, text = await response.text();
                report('response', {status: response.status, text, before, after: response.bodyUsed, promise: promise instanceof Promise, response: response instanceof Response});
            }).catch(error => report('error', {error: String(error)}));
        } else {
            xhrCalls++; const xhr = new XMLHttpRequest(); xhr.open('GET', url);
            Object.entries(headers).forEach(([name, value]) => xhr.setRequestHeader(name, value));
            xhr.onload = () => report('response', {status: xhr.status, text: xhr.responseText, readyState: xhr.readyState});
            xhr.onerror = () => report('error'); xhr.send();
        }
    });
    window.addEventListener('pagehide', event => report('pagehide', {persisted: event.persisted, trusted: event.isTrusted}));
    window.advance = () => location.assign('/history/b' + location.search);
    window.returnToA = () => history.back();
    window.forwardToB = () => history.forward();
    window.reloadPage = () => location.reload();
    report('ready');
})();
