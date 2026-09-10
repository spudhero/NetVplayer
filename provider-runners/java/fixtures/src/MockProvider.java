package com.netvplayer.fixture;

import java.io.ByteArrayInputStream;
import java.util.List;
import java.util.Map;

public final class MockProvider {
    public void init(Object ext) { }

    public Map<String, Object> homeContent(boolean filter) {
        return Map.of("class", List.of(Map.of("type_id", "movie", "type_name", "Movies")), "list", List.of());
    }

    public Map<String, Object> homeVideoContent() { return Map.of("list", List.of()); }

    public Map<String, Object> categoryContent(String tid, String page, boolean filter, Map<String, Object> extend) {
        return Map.of("page", Integer.parseInt(page), "pagecount", 1, "limit", 20, "total", 1,
            "list", List.of(Map.of("vod_id", tid, "vod_name", "Java POC")));
    }

    public Map<String, Object> detailContent(List<String> ids) {
        return Map.of("list", List.of(Map.of("vod_id", ids.getFirst(), "vod_name", "Java POC",
            "vod_play_from", "poc", "vod_play_url", "Episode$java://poc")));
    }

    public Map<String, Object> searchContent(String key, boolean quick, String page) {
        return Map.of("list", List.of(Map.of("vod_id", key, "vod_name", key)));
    }

    public Map<String, Object> playerContent(String flag, String id, List<String> vipFlags) {
        return Map.of("parse", 0, "flag", flag, "url", "https://example.invalid/" + id + ".m3u8",
            "header", Map.of("Referer", "https://example.invalid/"));
    }

    public Map<String, Object> liveContent(String url) { return Map.of("parse", 0, "url", url); }
    public boolean manualVideoCheck() { return true; }
    public boolean isVideoFormat(String url) { return url.endsWith(".m3u8") || url.endsWith(".mp4"); }
    public Object[] localProxy(Map<String, String> parameters) {
        return new Object[] { 206, "application/octet-stream", new ByteArrayInputStream("poc-bytes".getBytes()), Map.of("Accept-Ranges", "bytes"), true };
    }
    public Map<String, String> action(String action) { return Map.of("action", action); }
    public void destroy() { }
}
