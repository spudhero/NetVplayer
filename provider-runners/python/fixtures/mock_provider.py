import io

from fixture_dependency import proxy_bytes


class Spider:
    def __init__(self):
        self.ext = None
        self.site = None

    def init(self, ext, site=None):
        self.ext = ext
        self.site = site

    def homeContent(self, _filter):
        return {"class": [{"type_id": "movie", "type_name": "Movies"}], "list": []}

    def homeVideoContent(self):
        return {"list": []}

    def categoryContent(self, tid, pg, _filter, _extend):
        return {"page": int(pg), "pagecount": 1, "limit": 20, "total": 1, "list": [{"vod_id": tid, "vod_name": "Python POC"}]}

    def detailContent(self, ids):
        return {"list": [{"vod_id": ids[0], "vod_name": "Python POC", "vod_play_from": "poc", "vod_play_url": "Episode$python://poc"}]}

    def searchContent(self, key, _quick, _pg="1"):
        return {"list": [{"vod_id": key, "vod_name": key}]}

    def playerContent(self, flag, item_id, _vip_flags):
        return {"parse": 0, "flag": flag, "url": f"https://example.invalid/{item_id}.m3u8", "header": {"Referer": "https://example.invalid/"}}

    def liveContent(self, url):
        return {"url": url, "parse": 0}

    def manualVideoCheck(self):
        return True

    def isVideoFormat(self, url):
        return url.endswith((".m3u8", ".mp4"))

    def localProxy(self, _params):
        return [206, "application/octet-stream", io.BytesIO(proxy_bytes()), {"Accept-Ranges": "bytes"}, True]

    def action(self, action):
        if action == "site":
            return {"site": self.site}
        return {"action": action}

    def destroy(self):
        self.ext = None
        self.site = None
