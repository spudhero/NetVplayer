(() => {
    const c = contextConfig, results = [];
    const url = (c.api === 'xhr' && c.mode === 'credentials' ? 'https://sibling.example.test' : location.origin) + '/context/media?case=' + c.case;
    const xhr = new XMLHttpRequest();
    let fetchCalls = 0, xhrCalls = 0, playCalls = 0;
    const play = HTMLMediaElement.prototype.play;
    HTMLMediaElement.prototype.play = function() { playCalls++; return play.apply(this, arguments); };
    const report = stage => window.webkit.messageHandlers.context.postMessage({stage, results: stage === 'done' ? results : results.slice(-1), fetchCalls, xhrCalls, playCalls, url, documentURL: location.href});
    async function request(index) {
        const changed = index > 0;
        const method = c.mode === 'method' && !changed ? 'POST' : 'GET';
        let headers = {};
        if (c.mode === 'headers' || c.mode === 'first-accepted') headers = changed ? {'X-Phase': 'second'} : {'Authorization': 'Local first', 'X-Phase': 'first'};
        if (c.mode === 'duplicate') headers = changed ? {'x-b': 'two', 'x-a': 'one'} : {'X-A': 'one', 'X-B': 'two'};
        if (c.mode === 'flood') headers = {'X-Index': String(index)};
        if (c.mode === 'oversize') headers = {'X-Long': 'x'.repeat(17000)};
        const api = c.mode === 'source' && changed ? 'xhr' : c.api;
        const credentials = c.mode === 'credentials' ? (changed ? 'include' : 'omit') : 'same-origin';
        const body = method === 'POST' ? 'original-body' : undefined;
        if (api === 'fetch') {
            fetchCalls++;
            const input = new Request(url, {method, headers, credentials, body});
            const promise = fetch(input);
            const response = await promise;
            const before = response.bodyUsed, text = await response.text();
            results.push({api, index, method, credentials, status: response.status, text, promise: promise instanceof Promise, response: response instanceof Response, bodyUsedBefore: before, bodyUsedAfter: response.bodyUsed, inputBodyUsed: input.bodyUsed});
        } else {
            xhrCalls++;
            results.push(await new Promise((resolve, reject) => {
                xhr.open(method, url); xhr.withCredentials = credentials === 'include';
                Object.entries(headers).forEach(([name, value]) => xhr.setRequestHeader(name, value));
                let sendResult;
                xhr.onload = () => resolve({api, index, method, credentials, status: xhr.status, text: xhr.responseText, readyState: xhr.readyState, sendUndefined: sendResult === undefined});
                xhr.onerror = reject;
                sendResult = xhr.send(body);
            }));
        }
        report('response');
    }
    if (c.mode === 'dom-first') {
        const media = document.createElement('video'); media.preload = 'none'; media.src = url; document.body.appendChild(media);
    }
    const initial = request(0);
    window.advance = async () => {
        await initial;
        const count = c.mode === 'flood' ? 520 : c.mode === 'duplicate' ? 20 : 2;
        for (let i = 1; i < count; i++) await request(i);
        const media = document.createElement('video'); media.preload = 'none'; media.src = '/context/fallback.mp4'; document.body.appendChild(media);
        report('done');
    };
    initial.catch(error => window.webkit.messageHandlers.context.postMessage({stage: 'error', error: String(error)}));
})();
