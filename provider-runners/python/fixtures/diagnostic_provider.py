"""Offline transport diagnostic. No sites, network requests, or media URLs."""


class Spider:
    def init(self, ext, site=None):
        pass

    def homeContent(self, _filter):
        return {"class": [], "list": []}

    def searchContent(self, key, _quick, _pg="1"):
        return {"list": []}

    def action(self, value):
        return {"diagnostic": "ok", "contains_sources": False}

    def destroy(self):
        pass
