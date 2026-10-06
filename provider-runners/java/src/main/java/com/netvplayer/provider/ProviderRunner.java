package com.netvplayer.provider;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonNull;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.PrintStream;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.ParameterizedType;
import java.lang.reflect.Type;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.ServiceLoader;
import java.util.regex.Pattern;

public final class ProviderRunner {
    private static final int PROTOCOL = 1;
    private static final Gson GSON = new GsonBuilder().disableHtmlEscaping().create();
    private static final int MAX_PROXY_BYTES = Integer.parseInt(
        System.getenv().getOrDefault("NETVPLAYER_MAX_PROXY_BYTES", String.valueOf(32 * 1024 * 1024)));
    private static final Pattern URL_PATTERN = Pattern.compile("https?://[^\\s\\\"'<>]+");
    private static final Pattern HEADER_PATTERN = Pattern.compile("(?i)(cookie|authorization|proxy-authorization|x-api-key)\\s*:\\s*[^\\r\\n]+");
    private final Object rootProvider;
    private Object activeProvider;
    private final String providerId;
    private final PrintStream wire;

    private ProviderRunner(Object provider, String providerId, PrintStream wire) {
        this.rootProvider = provider;
        this.activeProvider = provider;
        this.providerId = providerId;
        this.wire = wire;
    }

    public static void main(String[] args) throws Exception {
        Map<String, String> options = parseArguments(args);
        Path providerPath = Path.of(required(options, "provider")).toRealPath();
        Path packageRoot = Path.of(System.getenv().getOrDefault(
            "NETVPLAYER_PROVIDER_ROOT", providerPath.getParent().toString())).toRealPath();
        if (!providerPath.startsWith(packageRoot) || !providerPath.toString().endsWith(".jar")) {
            throw new IllegalArgumentException("provider entrypoint must be a package-local JAR");
        }
        String providerId = System.getenv().getOrDefault(
            "NETVPLAYER_PROVIDER_ID", providerPath.getFileName().toString().replaceFirst("\\.jar$", ""));

        PrintStream wire = System.out;
        System.setOut(System.err);
        Object provider = loadProvider(providerPath, packageRoot, options.get("class"));
        ProviderRunner runner = new ProviderRunner(provider, providerId, wire);
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) {
                JsonObject request;
                JsonObject response;
                try {
                    request = JsonParser.parseString(line).getAsJsonObject();
                    response = runner.handle(request);
                } catch (Exception error) {
                    System.err.println(error.getClass().getSimpleName() + ": " + safeMessage(error));
                    response = failure("", "invalid_request", message(error), error.getClass().getSimpleName());
                    request = new JsonObject();
                }
                wire.println(GSON.toJson(response));
                wire.flush();
                if ("shutdown".equals(string(request, "operation", ""))) break;
            }
        } finally {
            runner.destroy();
        }
    }

    private JsonObject handle(JsonObject request) {
        String requestId = string(request, "request_id", "");
        try {
            if (integer(request, "protocol", 0) != PROTOCOL) throw new IllegalArgumentException("unsupported protocol");
            String requestedProvider = string(request, "provider_id", "");
            if (!requestedProvider.isEmpty() && !providerId.equals(requestedProvider)) {
                throw new IllegalArgumentException("provider_id does not match the launched package");
            }
            String operation = string(request, "operation", "");
            JsonObject arguments = request.has("arguments") && request.get("arguments").isJsonObject()
                ? request.getAsJsonObject("arguments") : new JsonObject();
            return switch (operation) {
                case "handshake" -> success(requestId, handshake());
                case "health" -> success(requestId, object("status", "ok"));
                case "cancel" -> success(requestId, object(
                    "cancelled", string(arguments, "target_request_id", "")));
                case "shutdown" -> {
                    destroy();
                    yield success(requestId, object("shutdown", true));
                }
                default -> operation(requestId, operation, arguments, request);
            };
        } catch (Exception error) {
            Throwable cause = unwrap(error);
            System.err.println(cause.getClass().getSimpleName() + ": " + safeMessage(cause));
            return failure(requestId, "provider_error", safeMessage(cause), cause.getClass().getSimpleName());
        }
    }

    private JsonObject operation(String requestId, String operation, JsonObject arguments, JsonObject request) throws Exception {
        if ("init".equals(operation) && rootProvider instanceof NetVplayerProviderFactory factory) {
            JsonObject site = request.has("site") && request.get("site").isJsonObject()
                ? request.getAsJsonObject("site") : new JsonObject();
            activeProvider = factory.providerFor(
                site,
                element(arguments, "extend", element(arguments, "ext", ""))
            );
        }
        Object value;
        if (activeProvider instanceof NetVplayerProvider typed) {
            value = typed.invoke(operation, arguments);
        } else {
            Invocation invocation = catVodInvocation(operation, arguments);
            value = invokeReflective(invocation.methodName(), invocation.arguments());
        }
        if ("proxy".equals(operation)) {
            JsonObject response = success(requestId, JsonNull.INSTANCE);
            response.add("proxy", proxyPayload(value));
            return response;
        }
        return success(requestId, jsonValue(value));
    }

    private JsonObject handshake() {
        JsonObject value = new JsonObject();
        value.addProperty("protocol", PROTOCOL);
        value.addProperty("provider_id", providerId);
        value.addProperty("runtime", "java");
        JsonArray operations = new JsonArray();
        for (String operation : List.of("init", "home", "home_video", "category", "detail", "search",
            "player", "live", "manual_video_check", "is_video_format", "proxy", "action", "destroy")) {
            operations.add(operation);
        }
        value.add("operations", operations);
        return value;
    }

    private Invocation catVodInvocation(String operation, JsonObject arguments) {
        return switch (operation) {
            case "init" -> new Invocation("init", new Object[] { element(arguments, "extend", element(arguments, "ext", "")) });
            case "home" -> new Invocation("homeContent", new Object[] { bool(arguments, "filter", true) });
            case "home_video" -> new Invocation("homeVideoContent", new Object[] {});
            case "category" -> new Invocation("categoryContent", new Object[] {
                string(arguments, "category_id", string(arguments, "tid", "")),
                string(arguments, "page", string(arguments, "pg", "1")),
                bool(arguments, "filter", true),
                element(arguments, "extend", new JsonObject())
            });
            case "detail" -> new Invocation("detailContent", new Object[] {
                element(arguments, "ids", array(string(arguments, "id", "")))
            });
            case "search" -> new Invocation("searchContent", new Object[] {
                string(arguments, "keyword", string(arguments, "key", "")),
                bool(arguments, "quick", false),
                string(arguments, "page", string(arguments, "pg", "1"))
            });
            case "player" -> new Invocation("playerContent", new Object[] {
                string(arguments, "flag", ""),
                string(arguments, "id", string(arguments, "url", "")),
                element(arguments, "vip_flags", element(arguments, "vipFlags", new JsonArray()))
            });
            case "live" -> new Invocation("liveContent", new Object[] { string(arguments, "url", "") });
            case "manual_video_check" -> new Invocation("manualVideoCheck", new Object[] {});
            case "is_video_format" -> new Invocation("isVideoFormat", new Object[] { string(arguments, "url", "") });
            case "proxy" -> new Invocation("localProxy", new Object[] {
                element(arguments, "parameters", element(arguments, "params", arguments))
            });
            case "action" -> new Invocation("action", new Object[] {
                string(arguments, "action", ""), string(arguments, "value", "")
            });
            case "destroy" -> new Invocation("destroy", new Object[] {});
            default -> throw new IllegalArgumentException("unsupported operation: " + operation);
        };
    }

    private Object invokeReflective(String name, Object[] arguments) throws Exception {
        List<Method> candidates = new ArrayList<>();
        for (Method method : activeProvider.getClass().getMethods()) {
            if (method.getName().equals(name)) candidates.add(method);
        }
        if (candidates.isEmpty() && "localProxy".equals(name)) return invokeReflective("proxy", arguments);
        Method method = candidates.stream().filter(item -> item.getParameterCount() == arguments.length)
            .findFirst().orElseGet(() -> candidates.stream()
                .filter(item -> "searchContent".equals(name) && item.getParameterCount() == 2)
                .findFirst().orElse(null));
        if (method == null && "action".equals(name) && arguments.length == 2) {
            return invokeReflective(name, new Object[] { arguments[0] });
        }
        if (method == null) throw new NoSuchMethodException(name);
        int count = method.getParameterCount();
        Object[] converted = new Object[count];
        Type[] types = method.getGenericParameterTypes();
        for (int index = 0; index < count; index++) converted[index] = convert(arguments[index], types[index]);
        method.setAccessible(true);
        return method.invoke(activeProvider, converted);
    }

    private static Object convert(Object value, Type type) {
        if (value == null) return null;
        Class<?> raw = type instanceof Class<?> valueClass ? valueClass
            : type instanceof ParameterizedType parameterized ? (Class<?>) parameterized.getRawType() : Object.class;
        if (raw.isInstance(value)) return value;
        if (raw == String.class) return value instanceof JsonElement element ? element.getAsString() : String.valueOf(value);
        if (raw == boolean.class || raw == Boolean.class) return value instanceof JsonElement element ? element.getAsBoolean() : value;
        if (value instanceof JsonElement element) return GSON.fromJson(element, type);
        return GSON.fromJson(GSON.toJsonTree(value), type);
    }

    private static JsonElement jsonValue(Object value) {
        if (value == null) return JsonNull.INSTANCE;
        if (value instanceof JsonElement element) return element;
        if (value instanceof byte[] bytes) {
            JsonObject object = new JsonObject();
            object.addProperty("body_base64", Base64.getEncoder().encodeToString(bytes));
            return object;
        }
        if (value instanceof String text) {
            String trimmed = text.trim();
            if ((trimmed.startsWith("{") && trimmed.endsWith("}"))
                || (trimmed.startsWith("[") && trimmed.endsWith("]"))) {
                try { return JsonParser.parseString(trimmed); } catch (RuntimeException ignored) { }
            }
        }
        return GSON.toJsonTree(value);
    }

    private static JsonObject proxyPayload(Object value) throws Exception {
        if (value instanceof Object[] array) return proxyArray(List.of(array));
        if (value instanceof List<?> list) return proxyArray(list);
        JsonElement element = jsonValue(value);
        if (!element.isJsonObject()) throw new IllegalArgumentException("proxy/localProxy must return an object or CatVod response array");
        JsonObject object = element.getAsJsonObject();
        if (!object.has("status_code")) object.addProperty("status_code", integer(object, "code", 200));
        object.remove("code");
        if (!object.has("headers")) object.add("headers", new JsonObject());
        return object;
    }

    private static JsonObject proxyArray(List<?> values) throws Exception {
        JsonObject object = new JsonObject();
        object.addProperty("status_code", values.isEmpty() ? 200 : Integer.parseInt(String.valueOf(values.get(0))));
        if (values.size() > 1 && values.get(1) != null) object.addProperty("content_type", String.valueOf(values.get(1)));
        Object body = values.size() > 2 ? values.get(2) : null;
        if (body instanceof InputStream stream) body = readProxyStream(stream);
        object.add("headers", values.size() > 3 ? GSON.toJsonTree(values.get(3)) : new JsonObject());
        boolean base64 = values.size() > 4 && Boolean.parseBoolean(String.valueOf(values.get(4)));
        if (body instanceof byte[] bytes) object.addProperty("body_base64", Base64.getEncoder().encodeToString(bytes));
        else if (body != null && base64) object.addProperty("body_base64", Base64.getEncoder().encodeToString(String.valueOf(body).getBytes(StandardCharsets.UTF_8)));
        else if (body != null) object.addProperty("body", String.valueOf(body));
        return object;
    }

    private static byte[] readProxyStream(InputStream stream) throws Exception {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        byte[] buffer = new byte[64 * 1024];
        int count;
        while ((count = stream.read(buffer)) >= 0) {
            if (output.size() + count > MAX_PROXY_BYTES) {
                throw new IllegalArgumentException("proxy stream exceeds the configured byte limit");
            }
            output.write(buffer, 0, count);
        }
        return output.toByteArray();
    }

    private void destroy() {
        try {
            if (activeProvider instanceof NetVplayerProvider typed) typed.invoke("destroy", new JsonObject());
            else invokeReflective("destroy", new Object[] {});
        } catch (NoSuchMethodException ignored) {
        } catch (Exception error) {
            System.err.println("destroy: " + safeMessage(unwrap(error)));
        }
        activeProvider = rootProvider;
    }

    private static Object loadProvider(Path jar, Path packageRoot, String className) throws Exception {
        List<URL> urls = new ArrayList<>();
        urls.add(jar.toUri().toURL());
        Path dependencies = packageRoot.resolve("dependencies");
        if (Files.isDirectory(dependencies)) {
            try (var paths = Files.walk(dependencies)) {
                for (Path path : paths.filter(item -> item.toString().endsWith(".jar")).sorted().toList()) {
                    Path resolved = path.toRealPath();
                    if (!resolved.startsWith(packageRoot)) {
                        throw new IllegalArgumentException("Java dependency escaped the signed package");
                    }
                    urls.add(resolved.toUri().toURL());
                }
            }
        }
        URLClassLoader loader = new URLClassLoader(urls.toArray(URL[]::new), ProviderRunner.class.getClassLoader());
        if (className != null && !className.isBlank()) return loader.loadClass(className).getDeclaredConstructor().newInstance();
        return ServiceLoader.load(NetVplayerProvider.class, loader).findFirst()
            .orElseThrow(() -> new IllegalArgumentException("provider class or NetVplayerProvider service is required"));
    }

    private static JsonObject success(String requestId, JsonElement result) {
        JsonObject response = new JsonObject();
        response.addProperty("request_id", requestId);
        response.addProperty("ok", true);
        response.add("result", result == null ? JsonNull.INSTANCE : result);
        response.add("error", JsonNull.INSTANCE);
        return response;
    }

    private static JsonObject failure(String requestId, String code, String message, String diagnostic) {
        JsonObject error = new JsonObject();
        error.addProperty("code", code);
        error.addProperty("message", message);
        error.addProperty("retryable", false);
        error.addProperty("diagnostic", diagnostic);
        JsonObject response = new JsonObject();
        response.addProperty("request_id", requestId);
        response.addProperty("ok", false);
        response.add("result", JsonNull.INSTANCE);
        response.add("error", error);
        return response;
    }

    private static JsonObject object(String key, Object value) {
        JsonObject object = new JsonObject();
        object.add(key, GSON.toJsonTree(value));
        return object;
    }

    private static JsonArray array(String value) {
        JsonArray array = new JsonArray();
        array.add(value);
        return array;
    }

    private static Object element(JsonObject object, String key, Object fallback) {
        return object.has(key) && !object.get(key).isJsonNull() ? object.get(key) : fallback;
    }

    private static String string(JsonObject object, String key, String fallback) {
        return object.has(key) && !object.get(key).isJsonNull() ? object.get(key).getAsString() : fallback;
    }

    private static int integer(JsonObject object, String key, int fallback) {
        return object.has(key) && !object.get(key).isJsonNull() ? object.get(key).getAsInt() : fallback;
    }

    private static boolean bool(JsonObject object, String key, boolean fallback) {
        return object.has(key) && !object.get(key).isJsonNull() ? object.get(key).getAsBoolean() : fallback;
    }

    private static Map<String, String> parseArguments(String[] args) {
        Map<String, String> result = new LinkedHashMap<>();
        for (int index = 0; index < args.length; index++) {
            if (args[index].startsWith("--") && index + 1 < args.length) result.put(args[index].substring(2), args[++index]);
        }
        return result;
    }

    private static String required(Map<String, String> values, String key) {
        String value = values.get(key);
        if (value == null || value.isBlank()) throw new IllegalArgumentException("--" + key + " is required");
        return value;
    }

    private static Throwable unwrap(Throwable error) {
        return error instanceof InvocationTargetException invocation && invocation.getCause() != null
            ? invocation.getCause() : error;
    }

    private static String message(Throwable error) {
        return error.getMessage() == null ? error.getClass().getSimpleName() : error.getMessage();
    }

    private static String safeMessage(Throwable error) {
        return safeMessage(message(error));
    }

    private static String safeMessage(String value) {
        return HEADER_PATTERN.matcher(URL_PATTERN.matcher(value).replaceAll("<redacted-url>"))
            .replaceAll("$1: <redacted>");
    }

    private record Invocation(String methodName, Object[] arguments) { }
}
