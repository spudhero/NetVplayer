// The original page alone creates the candidate, after a real native media event.
(() => {
    const c = lifecycleConfig, v = document.getElementById('original');
    const state = {events: [], candidate: null, fetch: 0, xhr: 0, playCalls: 0};
    for (const [object, name, field] of [[window, 'fetch', 'fetch'],
        [XMLHttpRequest.prototype, 'send', 'xhr'], [HTMLMediaElement.prototype, 'play', 'playCalls']]) {
        const original = object[name];
        object[name] = function (...args) { state[field]++; return Reflect.apply(original, this, args); };
    }
    function snapshot() {
        return {...state, readyState: v.readyState, time: v.currentTime,
            width: v.videoWidth, height: v.videoHeight, duration: Number.isFinite(v.duration) ? v.duration : null,
            preload: v.preload, autoplay: v.autoplay, muted: v.muted, cookie: document.cookie,
            visibility: document.visibilityState, href: location.href};
    }
    function send(stage, extra = {}) {
        window.webkit.messageHandlers.lifecycle.postMessage({stage, ...snapshot(), ...extra});
    }
    window.lifecycleSnapshot = snapshot;
    for (const name of ['loadstart', 'loadedmetadata', 'loadeddata', 'canplay', 'playing', 'timeupdate', 'error']) {
        v.addEventListener(name, event => {
            state.events.push({name, trusted: event.isTrusted, time: v.currentTime, at: performance.now()});
            send('event', {name, trusted: event.isTrusted});
            const required = c.mode === 'autoplay' ? name === 'timeupdate' && v.currentTime >= .25 : name === 'loadedmetadata';
            if (!required || state.candidate || c.mode === 'none' || c.mode === 'hold') return;
            if (c.next) { send('replace'); location.replace(c.next); return; }
            // No eligible URL exists until the native event handler generates it.
            const candidate = new URL('/candidate/' + crypto.randomUUID() + '.mp4', location.href);
            candidate.searchParams.set('case', c.case);
            state.candidate = candidate.href;
            send('candidate-created');
            const output = document.createElement('video');
            output.preload = 'none';
            output.src = state.candidate;
            document.body.append(output);
        });
    }
    v.src = c.target || new URL('/media/native.mp4?case=' + encodeURIComponent(c.case), location.href).href;
    send('ready');
})();
