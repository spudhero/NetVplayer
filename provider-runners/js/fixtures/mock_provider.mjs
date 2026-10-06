import { Readable } from "node:stream";
import { proxyBytes } from "./dependency.mjs";

export class Spider {
  init(ext) { this.ext = ext; }
  homeContent() { return { class: [{ type_id: "movie", type_name: "Movies" }], list: [] }; }
  homeVideoContent() { return { list: [] }; }
  categoryContent(tid, page) { return { page: Number(page), pagecount: 1, limit: 20, total: 1, list: [{ vod_id: tid, vod_name: "JS POC" }] }; }
  detailContent(ids) { return { list: [{ vod_id: ids[0], vod_name: "JS POC", vod_play_from: "poc", vod_play_url: "Episode$js://poc" }] }; }
  searchContent(key) { return { list: [{ vod_id: key, vod_name: key }] }; }
  playerContent(flag, id) { return { parse: 0, flag, url: `https://example.invalid/${id}.m3u8`, header: { Referer: "https://example.invalid/" } }; }
  liveContent(url) { return { parse: 0, url }; }
  manualVideoCheck() { return true; }
  isVideoFormat(url) { return /\.(m3u8|mp4)(\?|$)/.test(url); }
  localProxy() { return [206, "application/octet-stream", Readable.from([proxyBytes()]), { "Accept-Ranges": "bytes" }, true]; }
  action(action) { return { action }; }
  destroy() { this.ext = null; }
}
