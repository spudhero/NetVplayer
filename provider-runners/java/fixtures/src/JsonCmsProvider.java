package com.netvplayer.fixture;

import com.google.gson.Gson;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import java.io.ByteArrayInputStream;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.StringJoiner;

/**
 * Standard-Java JSON CMS fixture. It intentionally uses only java.net.http and
 * the public CatVod-shaped methods that ProviderRunner adapts reflectively.
 */
public final class JsonCmsProvider {
    private static final Gson GSON = new Gson();
    private final HttpClient client = HttpClient.newHttpClient();
    private URI baseURI;

    public void init(Object extend) {
        String endpoint = "";
        if (extend instanceof JsonObject object && object.has("base_url")) {
            endpoint = object.get("base_url").getAsString();
        } else if (extend instanceof Map<?, ?> values && values.get("base_url") != null) {
            endpoint = String.valueOf(values.get("base_url"));
        } else if (extend != null) {
            endpoint = String.valueOf(extend);
        }
        if (endpoint.isBlank()) throw new IllegalArgumentException("base_url is required");
        baseURI = URI.create(endpoint);
        if (baseURI.getScheme() == null || baseURI.getHost() == null) {
            throw new IllegalArgumentException("base_url must be an absolute URL");
        }
    }

    public Map<String, Object> homeContent(boolean filter) throws Exception {
        return request(Map.of("ac", "list"));
    }

    public Map<String, Object> homeVideoContent() {
        return Map.of("list", List.of());
    }

    public Map<String, Object> categoryContent(
        String tid,
        String page,
        boolean filter,
        Map<String, Object> extend
    ) throws Exception {
        return request(Map.of("ac", "detail", "t", tid, "pg", page));
    }

    public Map<String, Object> detailContent(List<String> ids) throws Exception {
        return request(Map.of("ac", "detail", "ids", String.join(",", ids)));
    }

    public Map<String, Object> searchContent(String keyword, boolean quick, String page) throws Exception {
        return request(Map.of("ac", "detail", "pg", page, "wd", keyword));
    }

    public Map<String, Object> playerContent(String flag, String id, List<String> vipFlags) {
        return Map.of(
            "parse", 0,
            "flag", flag,
            "url", id,
            "header", Map.of("Referer", baseURI.toString())
        );
    }

    public Map<String, Object> liveContent(String url) {
        return Map.of("parse", 0, "url", url);
    }

    public boolean manualVideoCheck() { return true; }

    public boolean isVideoFormat(String url) {
        String lower = url.toLowerCase();
        return lower.endsWith(".m3u8") || lower.endsWith(".mp4");
    }

    public Object[] localProxy(Map<String, String> parameters) {
        return new Object[] {
            206,
            "application/json",
            new ByteArrayInputStream("poc-bytes".getBytes(StandardCharsets.UTF_8)),
            Map.of("Accept-Ranges", "bytes"),
            true
        };
    }

    public Map<String, String> action(String action) {
        return Map.of("action", action);
    }

    public void destroy() { }

    @SuppressWarnings("unchecked")
    private Map<String, Object> request(Map<String, String> params) throws Exception {
        if (baseURI == null) throw new IllegalStateException("provider is not initialized");
        StringJoiner query = new StringJoiner("&");
        for (Map.Entry<String, String> entry : params.entrySet()) {
            query.add(encode(entry.getKey()) + "=" + encode(entry.getValue()));
        }
        String separator = baseURI.toString().contains("?") ? "&" : "?";
        URI requestURI = URI.create(baseURI + separator + query);
        HttpRequest request = HttpRequest.newBuilder(requestURI).GET().build();
        HttpResponse<String> response = client.send(request, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
        if (response.statusCode() < 200 || response.statusCode() >= 400) {
            throw new IllegalStateException("CMS HTTP " + response.statusCode());
        }
        JsonElement parsed = JsonParser.parseString(response.body());
        if (!parsed.isJsonObject()) throw new IllegalStateException("CMS response is not an object");
        return GSON.fromJson(parsed, Map.class);
    }

    private static String encode(String value) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8);
    }
}
