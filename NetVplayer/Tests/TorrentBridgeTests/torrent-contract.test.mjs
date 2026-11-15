import test from 'node:test'
import assert from 'node:assert/strict'
import { magnetIdentity } from '../../Resources/TorrentBridge/torrent-contract.mjs'
const hex = '0123456789abcdef0123456789abcdef01234567'
test('BTIH spellings preserve one stable identity', () => {
  assert.equal(magnetIdentity(`magnet:?xt=urn:btih:${hex}`).infoHash, hex)
  assert.equal(magnetIdentity('MAGNET:?XT=URN:BTIH:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA').infoHash, '0'.repeat(40))
  assert.equal(magnetIdentity('magnet:?xt=urn:btih:77777777777777777777777777777777').infoHash, 'f'.repeat(40))
  assert.equal(magnetIdentity(`magnet:?xt=urn:btih:${hex.toUpperCase()}&xt=urn:btih:${hex}`).infoHash, hex)
})
test('ambiguous, malformed and non-BTIH identities are rejected', () => {
  for (const uri of [`magnet:?xt=bad:${hex}`, `magnet:?xt=urn:btih:${hex}&xt=urn:btih:bad`, `magnet:?xt=urn:btih:${hex}&xt=urn:btih:${'f'.repeat(40)}`, `magnet:?xt=urn:btih:${hex}#fragment`, `magnet:path?xt=urn:btih:${hex}`, `magnet:?xt=urn:btih:${hex}\n`]) assert.throws(() => magnetIdentity(uri))
})
test('WebTorrent gets literal canonical xt while tracker input stays intact', () => {
  const uri = `MAGNET:?XT=URN%3ABTIH%3A${hex}&tr=https%3A%2F%2Ftracker.invalid%2Fannounce&dn=Original+Name`
  assert.equal(magnetIdentity(uri).torrentURI, `magnet:?xt=urn:btih:${hex}&tr=https%3A%2F%2Ftracker.invalid%2Fannounce&dn=Original+Name`)
})
test('non-BTIH topics keep their original bytes beside the canonical BTIH', () => {
  const topic = 'XT=urn%3Abtmh%3A1220abcdef'
  const uri = `magnet:?xt=URN%3ABTIH%3A${hex.toUpperCase()}&${topic}`
  assert.equal(magnetIdentity(uri).torrentURI, `magnet:?xt=urn:btih:${hex}&${topic}`)
})
