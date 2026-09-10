import fs from 'node:fs'
import http from 'node:http'
import path from 'node:path'
import process from 'node:process'
import WebTorrent from 'webtorrent'

const [magnetURI, readyPath, storagePath, parentPIDText] = process.argv.slice(2)
const parentPID = Number(parentPIDText)
const videoExtensions = new Set(['.mp4', '.mkv', '.m4v', '.mov', '.avi', '.webm', '.ts', '.m2ts'])
const maximumMetadataBytes = 4 * 1024 * 1024
const expectedInfoHash = new URL(magnetURI).searchParams.get('xt')?.split(':').pop()?.toLowerCase()
let readyWritten = false
let server
let metadataTimeout
let metadataSource = 'dht'

function cancelMetadataTimeout() {
  if (!metadataTimeout) return
  clearTimeout(metadataTimeout)
  metadataTimeout = undefined
}

function writeReady(payload) {
  if (readyWritten) return
  readyWritten = true
  const temporaryPath = `${readyPath}.tmp`
  fs.writeFileSync(temporaryPath, JSON.stringify(payload), 'utf8')
  fs.renameSync(temporaryPath, readyPath)
}

function fail(error) {
  cancelMetadataTimeout()
  const message = error instanceof Error ? error.message : String(error)
  writeReady({ error: message || 'WebTorrent 启动失败' })
  process.exitCode = 1
  setTimeout(() => process.exit(1), 50).unref()
}

function contentType(filename) {
  switch (path.extname(filename).toLowerCase()) {
    case '.mp4':
    case '.m4v':
      return 'video/mp4'
    case '.webm':
      return 'video/webm'
    case '.ts':
    case '.m2ts':
      return 'video/mp2t'
    default:
      return 'application/octet-stream'
  }
}

function parseRange(value, length) {
  if (!value) return null
  const match = /^bytes=(\d*)-(\d*)$/.exec(value.trim())
  if (!match) return undefined
  if (!match[1]) {
    const suffixLength = Number(match[2])
    if (!Number.isFinite(suffixLength) || suffixLength <= 0) return undefined
    return { start: Math.max(length - suffixLength, 0), end: length - 1 }
  }
  const start = Number(match[1])
  const requestedEnd = match[2] ? Number(match[2]) : length - 1
  if (!Number.isFinite(start) || !Number.isFinite(requestedEnd) || start >= length || requestedEnd < start) {
    return undefined
  }
  return { start, end: Math.min(requestedEnd, length - 1) }
}

async function resolveTorrentInput() {
  if (!expectedInfoHash || expectedInfoHash.length !== 40) return magnetURI
  try {
    const response = await fetch(`https://itorrents.org/torrent/${expectedInfoHash.toUpperCase()}.torrent`, {
      signal: AbortSignal.timeout(10000)
    })
    if (!response.ok) return magnetURI
    const declaredLength = Number(response.headers.get('content-length') ?? 0)
    if (declaredLength > maximumMetadataBytes) return magnetURI
    const bytes = new Uint8Array(await response.arrayBuffer())
    if (!bytes.length || bytes.length > maximumMetadataBytes || bytes[0] !== 0x64) return magnetURI
    metadataSource = 'itorrents'
    return Buffer.from(bytes)
  } catch {
    return magnetURI
  }
}

fs.mkdirSync(storagePath, { recursive: true })
const client = new WebTorrent({ destroyStoreOnDestroy: false })
client.on('error', fail)

let torrent
try {
  torrent = client.add(await resolveTorrentInput(), { path: storagePath })
} catch {
  metadataSource = 'dht'
  torrent = client.add(magnetURI, { path: storagePath })
}
torrent.on('error', fail)
torrent.once('ready', () => {
  cancelMetadataTimeout()
  if (expectedInfoHash && torrent.infoHash.toLowerCase() !== expectedInfoHash) {
    fail(new Error('元数据 info hash 与磁力链接不匹配'))
    return
  }
  const playableFiles = torrent.files.filter(file => videoExtensions.has(path.extname(file.name).toLowerCase()))
  const candidates = playableFiles.length ? playableFiles : torrent.files
  const file = candidates.sort((left, right) => right.length - left.length)[0]
  if (!file) {
    fail(new Error('磁力元数据中没有可播放文件'))
    return
  }

  server = http.createServer((request, response) => {
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      response.writeHead(405, { Allow: 'GET, HEAD' })
      response.end()
      return
    }
    const range = parseRange(request.headers.range, file.length)
    if (range === undefined) {
      response.writeHead(416, { 'Content-Range': `bytes */${file.length}` })
      response.end()
      return
    }

    const headers = {
      'Accept-Ranges': 'bytes',
      'Cache-Control': 'no-store',
      'Content-Type': contentType(file.name)
    }
    if (range) {
      headers['Content-Length'] = String(range.end - range.start + 1)
      headers['Content-Range'] = `bytes ${range.start}-${range.end}/${file.length}`
      response.writeHead(206, headers)
    } else {
      headers['Content-Length'] = String(file.length)
      response.writeHead(200, headers)
    }
    if (request.method === 'HEAD') {
      response.end()
      return
    }

    const stream = file.createReadStream(range ?? {})
    request.on('aborted', () => stream.destroy())
    response.on('close', () => stream.destroy())
    stream.on('error', error => {
      if (!response.headersSent) response.writeHead(500)
      response.destroy(error)
    })
    stream.pipe(response)
  })

  server.listen(0, '127.0.0.1', () => {
    const address = server.address()
    const encodedName = encodeURIComponent(file.name)
    writeReady({
      url: `http://127.0.0.1:${address.port}/stream/${encodedName}`,
      name: file.name,
      length: file.length,
      infoHash: torrent.infoHash,
      metadataSource
    })
  })
})

function shutdown() {
  cancelMetadataTimeout()
  server?.close()
  client.destroy(() => process.exit(0))
  setTimeout(() => process.exit(0), 1000).unref()
}

process.on('SIGTERM', shutdown)
process.on('SIGINT', shutdown)

if (Number.isInteger(parentPID) && parentPID > 1) {
  setInterval(() => {
    try {
      process.kill(parentPID, 0)
    } catch {
      shutdown()
    }
  }, 5000).unref()
}

metadataTimeout = setTimeout(() => fail(new Error('等待磁力元数据超时')), 90000)
metadataTimeout.unref()
