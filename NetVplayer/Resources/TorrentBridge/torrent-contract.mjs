// BTIH identity is canonical hex in the host, regardless of magnet spelling.
export function magnetIdentity(value) {
  if (Buffer.byteLength(value) > 64 * 1024 || /[\x00-\x1f\x7f]/.test(value)) throw new Error('Invalid magnet')
  const uri = new URL(value)
  if (uri.protocol.toLowerCase() !== 'magnet:' || uri.host || uri.hash || uri.pathname) throw new Error('Invalid magnet')
  const hashes = []
  for (const [key, topic] of uri.searchParams) {
    if (key.toLowerCase() !== 'xt' || !topic.toLowerCase().startsWith('urn:btih:')) continue
    const raw = topic.slice(9).toLowerCase()
    if (/^[0-9a-f]{40}$/.test(raw)) { hashes.push(raw); continue }
    if (!/^[a-z2-7]{32}$/.test(raw)) throw new Error('Invalid BTIH')
    let buffer = 0; let bits = 0; const bytes = []
    for (const char of raw) {
      buffer = (buffer << 5) | 'abcdefghijklmnopqrstuvwxyz234567'.indexOf(char)
      bits += 5
      if (bits >= 8) { bits -= 8; bytes.push((buffer >> bits) & 255); buffer &= (1 << bits) - 1 }
    }
    hashes.push(Buffer.from(bytes).toString('hex'))
  }
  if (!hashes.length || hashes.some(hash => hash !== hashes[0])) throw new Error('Ambiguous or missing BTIH')
  // WebTorrent's parser expects a literal, lowercase xt prefix. Keep other fields.
  const fields = value.slice(value.indexOf('?') + 1).split('&').map(field => {
    const [[key, topic] = []] = new URLSearchParams(field)
    return key?.toLowerCase() === 'xt' && topic?.toLowerCase().startsWith('urn:btih:')
      ? `xt=urn:btih:${hashes[0]}` : field
  })
  return { infoHash: hashes[0], torrentURI: `magnet:?${fields.join('&')}` }
}
