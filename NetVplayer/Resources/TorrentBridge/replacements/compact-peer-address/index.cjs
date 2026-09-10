'use strict'

function requireBuffer(value) {
  if (!Buffer.isBuffer(value)) {
    throw new TypeError('compact peer address must be a Buffer')
  }
  return value
}

function formatIPv6(buffer) {
  const groups = []
  for (let index = 0; index < 8; index += 1) {
    groups.push(buffer.readUInt16BE(index * 2))
  }

  let bestStart = -1
  let bestLength = 0
  for (let start = 0; start < groups.length;) {
    if (groups[start] !== 0) {
      start += 1
      continue
    }
    let end = start
    while (end < groups.length && groups[end] === 0) end += 1
    const length = end - start
    if (length > bestLength) {
      bestStart = start
      bestLength = length
    }
    start = end
  }

  const parts = groups.map(group => group.toString(16))
  if (bestStart < 0) return parts.join(':')
  const left = parts.slice(0, bestStart).join(':')
  const right = parts.slice(bestStart + bestLength).join(':')
  return `${left}::${right}`
}

function compactPeerAddress(value) {
  const buffer = requireBuffer(value)
  if (buffer.length === 6) {
    const host = `${buffer[0]}.${buffer[1]}.${buffer[2]}.${buffer[3]}`
    return `${host}:${buffer.readUInt16BE(4)}`
  }
  if (buffer.length === 18) {
    return `[${formatIPv6(buffer.subarray(0, 16))}]:${buffer.readUInt16BE(16)}`
  }
  throw new Error('invalid compact peer address: expected 6 or 18 bytes')
}

function decodeMany(value, width, decoder) {
  const buffer = requireBuffer(value)
  if (buffer.length % width !== 0) {
    throw new Error(`compact peer buffer length must be a multiple of ${width}`)
  }
  const output = []
  for (let offset = 0; offset < buffer.length; offset += width) {
    output.push(decoder(buffer.subarray(offset, offset + width)))
  }
  return output
}

compactPeerAddress.multi = value => decodeMany(value, 6, compactPeerAddress)
compactPeerAddress.multi6 = value => decodeMany(value, 18, compactPeerAddress)

module.exports = compactPeerAddress
