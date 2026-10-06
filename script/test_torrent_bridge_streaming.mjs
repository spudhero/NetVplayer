import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { once } from 'node:events'

test('torrent bridge serves the selected episode, with Range and attachment exclusion', async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'netvplayer-torrent-test-'))
  let child
  try {
    const original = await fs.readFile(new URL('../NetVplayer/Resources/TorrentBridge/torrent-bridge.mjs', import.meta.url), 'utf8')
    assert.ok(original.includes("from 'webtorrent'"))
    await fs.writeFile(path.join(directory, 'bridge.mjs'), original.replace("from 'webtorrent'", "from './fixture.mjs'"))
    await fs.writeFile(path.join(directory, 'fixture.mjs'), `
      import { EventEmitter } from 'node:events'
      import { Readable } from 'node:stream'
      globalThis.fetch = async () => { throw new Error('No external metadata lookup in this test') }
      export default class FixtureClient extends EventEmitter {
        add(uri, options) {
          if (!options.deselect) throw new Error('Metadata discovery must not download every file')
          const torrent = new EventEmitter()
          torrent.infoHash = new URL(uri).searchParams.get('xt').split(':').pop()
          torrent.files = [['03.mkv', 'largest-third-episode'], ['02.mkv', 'second'],
                           ['poster.txt', 'attachment'], ['01.mkv', 'first']].map(([name, text]) => ({
            name, length: Buffer.byteLength(text),
            createReadStream({ start = 0, end = Buffer.byteLength(text) - 1 } = {}) {
              return Readable.from([Buffer.from(text).subarray(start, end + 1)])
            }
          }))
          queueMicrotask(() => torrent.emit('ready'))
          return torrent
        }
        destroy(callback) { callback() }
      }
    `)
    const readyPath = path.join(directory, 'ready.json')
    child = spawn(process.execPath, [path.join(directory, 'bridge.mjs'),
      'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567', readyPath, directory, String(process.pid)],
      { stdio: ['ignore', 'ignore', 'pipe'] })
    let diagnostics = ''
    child.stderr.on('data', data => { diagnostics += data })
    let ready
    for (let attempt = 0; attempt < 100; attempt++) {
      try { ready = JSON.parse(await fs.readFile(readyPath, 'utf8')); break } catch {}
      if (child.exitCode !== null) throw new Error(diagnostics || 'Bridge exited before ready')
      await new Promise(resolve => setTimeout(resolve, 30))
    }
    assert.ok(ready, diagnostics || 'Bridge did not become ready')
    assert.equal(ready.error, undefined)
    assert.deepEqual(ready.files.map(file => file.name), ['01.mkv', '02.mkv', '03.mkv'])
    assert.deepEqual(ready.files.map(file => file.index), [3, 1, 0])
    assert.equal(await (await fetch(ready.url)).text(), 'first')
    assert.equal(await (await fetch(ready.files[1].url)).text(), 'second')
    const range = await fetch(ready.files[1].url, { headers: { Range: 'bytes=1-3' } })
    assert.equal(range.status, 206)
    assert.equal(range.headers.get('content-range'), 'bytes 1-3/6')
    assert.equal(await range.text(), 'eco')
    const head = await fetch(ready.files[2].url, { method: 'HEAD' })
    assert.equal(head.headers.get('content-length'), '21')
    assert.equal(await head.text(), '')
    const origin = new URL(ready.url).origin
    assert.equal((await fetch(origin + '/stream/2/poster.txt')).status, 404)
    assert.equal((await fetch(origin + '/stream/1/03.mkv')).status, 404)
    assert.equal((await fetch(ready.url, { headers: { Range: 'bytes=100-' } })).status, 416)
  } finally {
    if (child && child.exitCode === null) {
      const exited = once(child, 'exit')
      child.kill('SIGTERM')
      await exited
    }
    await fs.rm(directory, { recursive: true, force: true })
  }
})
