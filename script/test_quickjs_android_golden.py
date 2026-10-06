#!/usr/bin/env python3
"""Compile the Android QuickJS helper sources against small host-side stubs."""

from __future__ import annotations

import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
FONGMI_ROOT_ENV = "NETVPLAYER_FONGMI_ROOT"
FONGMI_REQUIRED_ENV = "NETVPLAYER_REQUIRE_FONGMI_REFERENCE"
FONGMI_SENTINELS = (
    "LICENSE.md",
    "quickjs/src/main/java/com/fongmi/quickjs/utils/Crypto.java",
    "quickjs/src/main/java/com/fongmi/quickjs/crawler/Spider.java",
    "app/src/main/java/com/fongmi/android/tv/server/process/Proxy.java",
    "catvod/src/main/java/com/github/catvod/utils/UriUtil.java",
)


class QuickJSAndroidGoldenTests(unittest.TestCase):
    def fongmi_root(self) -> Path:
        value = os.environ.get(FONGMI_ROOT_ENV)
        if not value:
            if os.environ.get(FONGMI_REQUIRED_ENV) == "1":
                self.fail(f"{FONGMI_ROOT_ENV} is required by this verification run")
            self.skipTest(
                f"set {FONGMI_ROOT_ENV} to an external FongMi/TV checkout"
            )
        root = Path(value).expanduser().resolve()
        missing = [relative for relative in FONGMI_SENTINELS if not (root / relative).is_file()]
        if missing:
            self.fail(
                f"{FONGMI_ROOT_ENV} is missing audited FongMi/TV paths: "
                + ", ".join(missing)
            )
        return root

    def test_required_reference_rejects_missing_configuration(self) -> None:
        with mock.patch.dict(os.environ, {FONGMI_REQUIRED_ENV: "1"}):
            os.environ.pop(FONGMI_ROOT_ENV, None)
            with self.assertRaisesRegex(AssertionError, "is required"):
                self.fongmi_root()

    def test_invalid_reference_root_fails_before_golden_checks(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "LICENSE.md").write_text("GNU GENERAL PUBLIC LICENSE\n", encoding="utf-8")
            with mock.patch.dict(
                os.environ,
                {FONGMI_ROOT_ENV: str(root), FONGMI_REQUIRED_ENV: "1"},
            ):
                with self.assertRaisesRegex(AssertionError, "missing audited"):
                    self.fongmi_root()

    def test_android_crypto_local_module_and_url_contracts(self) -> None:
        fongmi_root = self.fongmi_root()
        if shutil.which("javac") is None or shutil.which("java") is None:
            self.skipTest("JDK is required for the Android QuickJS golden harness")

        with tempfile.TemporaryDirectory(prefix="netvplayer-quickjs-android-golden-") as temporary:
            root = Path(temporary)
            sources = root / "sources"
            classes = root / "classes"
            self._write_sources(sources)
            java_sources = [
                *sources.rglob("*.java"),
                fongmi_root / "quickjs/src/main/java/com/fongmi/quickjs/utils/Crypto.java",
                fongmi_root / "quickjs/src/main/java/com/fongmi/quickjs/utils/JSUtil.java",
                fongmi_root / "quickjs/src/main/java/com/fongmi/quickjs/method/Local.java",
                fongmi_root / "quickjs/src/main/java/com/fongmi/quickjs/utils/Module.java",
                fongmi_root / "quickjs/src/main/java/com/fongmi/quickjs/bean/Res.java",
                fongmi_root / "quickjs/src/main/java/com/fongmi/quickjs/bean/Req.java",
                fongmi_root / "quickjs/src/main/java/com/fongmi/quickjs/utils/Connect.java",
                fongmi_root / "catvod/src/main/java/com/github/catvod/utils/UriUtil.java",
            ]
            compile_result = subprocess.run(
                ["javac", "-d", str(classes), *(str(path) for path in java_sources)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)

            run_result = subprocess.run(
                ["java", "-cp", str(classes), "AndroidGolden"],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(run_result.returncode, 0, run_result.stderr)
            values = dict(
                line.split("=", 1)
                for line in run_result.stdout.splitlines()
                if "=" in line
            )

            self.assertEqual(values["md5"], "5d41402abc4b2a76b9719d911017c592")
            self.assertEqual(values["aes_cbc"], "rkbumbtCClkN+Jkds7bQJw==")
            self.assertEqual(values["aes_ecb"], "Z0x+8454yr2c7JwSWCOmOQ==")
            self.assertEqual(values["aes_cbc_plain"], "hello")
            self.assertEqual(values["aes_ecb_plain"], "hello")
            self.assertEqual(values["aes_invalid_mode"], "")
            self.assertEqual(values["aes_invalid_iv"], "")
            self.assertEqual(values["aes_invalid_base64"], "")
            self.assertEqual(values["rsa_public_plain"], "hello")
            self.assertEqual(values["rsa_private_plain"], "hello")
            self.assertEqual(values["rsa_pem_plain"], "hello")
            self.assertEqual(values["rsa_invalid_key"], "")
            self.assertEqual(values["rsa_invalid_pem"], "")
            self.assertEqual(values["rsa_truncated_pem"], "")
            self.assertEqual(values["rsa_encrypted_private_pem"], "")
            self.assertEqual(values["rsa_unknown_mode_plain"], "hello")
            self.assertEqual(values["local_missing"], "")
            self.assertEqual(values["local_empty"], "")
            self.assertEqual(values["local_token"], "persisted")
            self.assertEqual(values["local_deleted"], "")
            self.assertEqual(values["module_remote"], "remote-module")
            self.assertEqual(values["module_asset"], "asset-module")
            self.assertEqual(values["module_lib"], "lib-module")
            self.assertEqual(values["module_unsupported"], "null")
            self.assertEqual(values["module_uppercase_http"], "null")
            self.assertEqual(values["module_uppercase_assets"], "null")
            self.assertEqual(values["module_remote_reads"], "1")
            self.assertEqual(values["module_asset_reads"], "2")
            self.assertEqual(values["module_remote_reads_after_clear"], "2")
            self.assertEqual(values["module_lru_values"], "true")
            self.assertEqual(values["module_lru_reads"], "52")
            self.assertEqual(values["url_relative"], "https://example.test/a/detail?new=2#next")
            self.assertEqual(values["url_query"], "https://example.test/a/b/page?new=2#next")
            self.assertEqual(values["url_fragment"], "https://example.test/a/b/page?old=1#next")
            self.assertEqual(values["url_empty"], "https://example.test/a/b/page?old=1")
            self.assertEqual(values["url_network"], "https://cdn.example.test/media.ts")
            self.assertEqual(values["url_absolute"], "https://cdn.example.test/media.ts")
            self.assertEqual(values["url_double_slash"], "https://example.test/a//b/c")
            self.assertEqual(values["url_above_root"], "https://example.test/x")
            self.assertEqual(values["bytes_signed"], "[0, 127, -1, -128]")
            self.assertEqual(values["proxy_text_stream"], "[104, 101, 108, 108, 111]")
            self.assertEqual(values["proxy_base64_stream"], "[0, -1, -128]")
            self.assertEqual(values["req_defaults"], "0,1,10000,json,get,UTF-8")
            self.assertEqual(values["connect_methods"], "GET,POST,HEAD,GET")
            self.assertEqual(values["connect_client_policy"], "false,2500")
            self.assertEqual(values["connect_raw_body"], "latin-body")
            self.assertEqual(values["connect_empty_body"], "0")
            self.assertEqual(values["connect_json_body"], '{"value":1}')
            self.assertEqual(values["connect_form_body"], "FormBody")
            self.assertEqual(values["connect_multipart_body"], "MultipartBody,true")
            self.assertEqual(values["connect_buffer_0"], "é")
            self.assertEqual(values["connect_buffer_1"], "[0, 127, -1, -128]")
            self.assertEqual(values["connect_buffer_2"], "AH//gA==")
            self.assertEqual(values["connect_buffer_3"], "[0, 127, -1, -128]")
            self.assertEqual(values["connect_buffer_unknown"], "false")
            self.assertEqual(values["connect_headers"], "one,[first, second]")
            self.assertEqual(values["connect_error"], ",,true")

    def test_android_proxy_contract_materializes_quickjs_values(self) -> None:
        fongmi_root = self.fongmi_root()
        spider = (
            fongmi_root / "quickjs/src/main/java/com/fongmi/quickjs/crawler/Spider.java"
        ).read_text(encoding="utf-8")
        server = (
            fongmi_root / "app/src/main/java/com/fongmi/android/tv/server/process/Proxy.java"
        ).read_text(encoding="utf-8")

        self.assertIn("String json = submit(proxy::stringify).get();", spider)
        self.assertIn("result[2] = getStream(array.opt(2), base64);", spider)
        self.assertIn('String proxy = (String) call("proxy", array, object);', spider)
        self.assertIn("Res res = Res.objectFrom(proxy);", spider)
        self.assertIn("result[2] = res.getStream();", spider)
        self.assertIn("NanoHTTPD.newChunkedResponse", server)
        self.assertIn("(InputStream) rs[2]", server)

    def test_android_quickjs_reference_does_not_define_jsp_helpers(self) -> None:
        root = self.fongmi_root() / "quickjs/src/main"
        sources = "\n".join(
            path.read_text(encoding="utf-8", errors="replace")
            for path in sorted(root.rglob("*"))
            if path.suffix in {".java", ".js"}
        )
        for helper in ("pdfa", "pdfh", "pdfl"):
            self.assertNotRegex(sources, rf"\b{helper}\b")
        self.assertNotRegex(sources, r"\bjsp\s*\.")

    @staticmethod
    def _write_sources(root: Path) -> None:
        files = {
            "android/util/Base64.java": """
                package android.util;
                public final class Base64 {
                    public static final int DEFAULT = 0;
                    public static final int NO_WRAP = 2;
                    public static byte[] decode(String value, int flags) {
                        return java.util.Base64.getMimeDecoder().decode(value);
                    }
                    public static String encodeToString(byte[] value, int flags) {
                        return java.util.Base64.getEncoder().encodeToString(value);
                    }
                }
            """,
            "android/text/TextUtils.java": """
                package android.text;
                public final class TextUtils {
                    public static boolean isEmpty(CharSequence value) {
                        return value == null || value.length() == 0;
                    }
                }
            """,
            "androidx/annotation/Keep.java": """
                package androidx.annotation;
                public @interface Keep {}
            """,
            "androidx/annotation/Nullable.java": """
                package androidx.annotation;
                public @interface Nullable {}
            """,
            "com/whl/quickjs/wrapper/JSMethod.java": """
                package com.whl.quickjs.wrapper;
                public @interface JSMethod {}
            """,
            "com/whl/quickjs/wrapper/JSArray.java": """
                package com.whl.quickjs.wrapper;
                public final class JSArray {
                    private final java.util.List<Object> values = new java.util.ArrayList<>();
                    public void set(Object value, int index) {
                        while (values.size() <= index) values.add(null);
                        values.set(index, value);
                    }
                    @Override public String toString() { return values.toString(); }
                }
            """,
            "com/whl/quickjs/wrapper/JSObject.java": """
                package com.whl.quickjs.wrapper;
                public final class JSObject {
                    private final java.util.Map<String, Object> values = new java.util.LinkedHashMap<>();
                    public void setProperty(String key, Object value) { values.put(key, value); }
                    public Object getProperty(String key) { return values.get(key); }
                    public boolean hasProperty(String key) { return values.containsKey(key); }
                }
            """,
            "com/whl/quickjs/wrapper/QuickJSContext.java": """
                package com.whl.quickjs.wrapper;
                public final class QuickJSContext {
                    public JSArray createNewJSArray() { return new JSArray(); }
                    public JSObject createNewJSObject() { return new JSObject(); }
                }
            """,
            "com/github/catvod/utils/Util.java": """
                package com.github.catvod.utils;
                public final class Util {
                    public static String md5(String value) throws Exception {
                        byte[] digest = java.security.MessageDigest.getInstance("MD5")
                            .digest(value.getBytes(java.nio.charset.StandardCharsets.UTF_8));
                        StringBuilder result = new StringBuilder();
                        for (byte item : digest) result.append(String.format("%02x", item & 0xff));
                        return result.toString();
                    }
                    public static byte[] decode(String value) {
                        return java.util.Base64.getDecoder().decode(value);
                    }
                    public static String base64(byte[] value) {
                        return java.util.Base64.getEncoder().encodeToString(value);
                    }
                }
            """,
            "com/github/catvod/utils/Json.java": """
                package com.github.catvod.utils;
                public final class Json {
                    public static java.util.Map<String, String> toMap(com.google.gson.JsonElement value) {
                        return value == null ? java.util.Collections.emptyMap() : value.asMap();
                    }
                }
            """,
            "com/google/gson/Gson.java": """
                package com.google.gson;
                public final class Gson {
                    public <T> T fromJson(String value, Class<T> type) {
                        throw new UnsupportedOperationException();
                    }
                }
            """,
            "com/google/gson/JsonElement.java": """
                package com.google.gson;
                public class JsonElement {
                    private final String text;
                    private final java.util.Map<String, String> values;
                    public JsonElement() { this("null", java.util.Collections.emptyMap()); }
                    public JsonElement(String text, java.util.Map<String, String> values) {
                        this.text = text;
                        this.values = values;
                    }
                    public java.util.Map<String, String> asMap() { return values; }
                    @Override public String toString() { return text; }
                }
            """,
            "com/google/gson/annotations/SerializedName.java": """
                package com.google.gson.annotations;
                public @interface SerializedName { String value(); }
            """,
            "com/github/catvod/utils/Prefers.java": """
                package com.github.catvod.utils;
                public final class Prefers {
                    private static final java.util.Map<String, String> VALUES = new java.util.HashMap<>();
                    public static String getString(String key) { return VALUES.getOrDefault(key, ""); }
                    public static void put(String key, Object value) { if (value != null) VALUES.put(key, String.valueOf(value)); }
                    public static void remove(String key) { VALUES.remove(key); }
                }
            """,
            "android/util/LruCache.java": """
                package android.util;
                public class LruCache<K, V> {
                    private final java.util.LinkedHashMap<K, V> values = new java.util.LinkedHashMap<>(16, 0.75f, true);
                    private final int maximumSize;
                    public LruCache(int maximumSize) { this.maximumSize = maximumSize; }
                    public V get(K key) { return values.get(key); }
                    public V put(K key, V value) {
                        V previous = values.put(key, value);
                        while (values.size() > maximumSize) values.remove(values.keySet().iterator().next());
                        return previous;
                    }
                    public void evictAll() { values.clear(); }
                }
            """,
            "com/github/catvod/net/OkHttp.java": """
                package com.github.catvod.net;
                public final class OkHttp {
                    public static int reads = 0;
                    public static boolean lastRedirect;
                    public static int lastTimeout;
                    public static String string(String url) {
                        reads += 1;
                        String prefix = "https://golden.example/lru/";
                        return url.startsWith(prefix) ? "module-lru-" + url.substring(prefix.length()) : "remote-module";
                    }
                    public static okhttp3.OkHttpClient client(boolean redirect, int timeout) {
                        lastRedirect = redirect;
                        lastTimeout = timeout;
                        return new okhttp3.OkHttpClient();
                    }
                }
            """,
            "com/google/common/net/HttpHeaders.java": """
                package com.google.common.net;
                public final class HttpHeaders {
                    public static final String CONTENT_TYPE = "Content-Type";
                }
            """,
            "okhttp3/MediaType.java": """
                package okhttp3;
                public final class MediaType {
                    public final String value;
                    private MediaType(String value) { this.value = value; }
                    public static MediaType get(String value) { return new MediaType(value); }
                }
            """,
            "okhttp3/RequestBody.java": """
                package okhttp3;
                public class RequestBody {
                    public byte[] bytes = new byte[0];
                    public MediaType mediaType;
                    protected RequestBody() {}
                    public static RequestBody create(String value, MediaType mediaType) {
                        RequestBody body = new RequestBody();
                        body.bytes = value.getBytes(java.nio.charset.StandardCharsets.UTF_8);
                        body.mediaType = mediaType;
                        return body;
                    }
                    public static RequestBody create(byte[] value) {
                        RequestBody body = new RequestBody();
                        body.bytes = value;
                        return body;
                    }
                    public String text() { return new String(bytes, java.nio.charset.StandardCharsets.UTF_8); }
                }
            """,
            "okhttp3/FormBody.java": """
                package okhttp3;
                public final class FormBody extends RequestBody {
                    public final java.util.Map<String, String> values = new java.util.LinkedHashMap<>();
                    public static final class Builder {
                        private final FormBody body = new FormBody();
                        public Builder add(String key, String value) { body.values.put(key, value); return this; }
                        public FormBody build() { return body; }
                    }
                }
            """,
            "okhttp3/MultipartBody.java": """
                package okhttp3;
                public final class MultipartBody extends RequestBody {
                    public static final MediaType FORM = MediaType.get("multipart/form-data");
                    public final String boundary;
                    public final java.util.Map<String, String> values;
                    private MultipartBody(String boundary, java.util.Map<String, String> values) {
                        this.boundary = boundary;
                        this.values = values;
                    }
                    public static final class Builder {
                        private final String boundary;
                        private final java.util.Map<String, String> values = new java.util.LinkedHashMap<>();
                        public Builder(String boundary) { this.boundary = boundary; }
                        public Builder setType(MediaType type) { return this; }
                        public Builder addFormDataPart(String key, String value) { values.put(key, value); return this; }
                        public MultipartBody build() { return new MultipartBody(boundary, values); }
                    }
                }
            """,
            "okhttp3/Headers.java": """
                package okhttp3;
                public final class Headers {
                    private final java.util.Map<String, java.util.List<String>> values;
                    public Headers(java.util.Map<String, java.util.List<String>> values) { this.values = values; }
                    public static Headers of(java.util.Map<String, String> values) {
                        java.util.Map<String, java.util.List<String>> mapped = new java.util.LinkedHashMap<>();
                        for (java.util.Map.Entry<String, String> entry : values.entrySet()) {
                            mapped.put(entry.getKey(), java.util.List.of(entry.getValue()));
                        }
                        return new Headers(mapped);
                    }
                    public String get(String key) {
                        for (java.util.Map.Entry<String, java.util.List<String>> entry : values.entrySet()) {
                            if (entry.getKey().equalsIgnoreCase(key)) return entry.getValue().get(0);
                        }
                        return null;
                    }
                    public java.util.Map<String, java.util.List<String>> toMultimap() { return values; }
                }
            """,
            "okhttp3/Request.java": """
                package okhttp3;
                public final class Request {
                    public final String url;
                    public final String method;
                    public final Headers headers;
                    public final RequestBody body;
                    private Request(String url, String method, Headers headers, RequestBody body) {
                        this.url = url;
                        this.method = method;
                        this.headers = headers;
                        this.body = body;
                    }
                    public static final class Builder {
                        private String url;
                        private String method;
                        private Headers headers;
                        private RequestBody body;
                        public Builder url(String value) { url = value; return this; }
                        public Builder headers(Headers value) { headers = value; return this; }
                        public Builder get() { method = "GET"; body = null; return this; }
                        public Builder head() { method = "HEAD"; body = null; return this; }
                        public Builder post(RequestBody value) { method = "POST"; body = value; return this; }
                        public Request build() { return new Request(url, method, headers, body); }
                    }
                }
            """,
            "okhttp3/Call.java": """
                package okhttp3;
                public final class Call {
                    public final Request request;
                    public Call(Request request) { this.request = request; }
                    public Response execute() { return null; }
                }
            """,
            "okhttp3/OkHttpClient.java": """
                package okhttp3;
                public final class OkHttpClient {
                    public Call newCall(Request request) { return new Call(request); }
                }
            """,
            "okhttp3/ResponseBody.java": """
                package okhttp3;
                public final class ResponseBody {
                    private final byte[] value;
                    public ResponseBody(byte[] value) { this.value = value; }
                    public byte[] bytes() { return value.clone(); }
                }
            """,
            "okhttp3/Response.java": """
                package okhttp3;
                public final class Response implements AutoCloseable {
                    private final int code;
                    private final Headers headers;
                    private final ResponseBody body;
                    public Response(int code, Headers headers, byte[] body) {
                        this.code = code;
                        this.headers = headers;
                        this.body = new ResponseBody(body);
                    }
                    public int code() { return code; }
                    public Headers headers() { return headers; }
                    public ResponseBody body() { return body; }
                    @Override public void close() {}
                }
            """,
            "com/github/catvod/utils/Asset.java": """
                package com.github.catvod.utils;
                public final class Asset {
                    public static int reads = 0;
                    public static String read(String name) {
                        reads += 1;
                        return name.startsWith("js/lib/") ? "lib-module" : "asset-module";
                    }
                }
            """,
            "AndroidGolden.java": """
                import com.fongmi.quickjs.method.Local;
                import com.fongmi.quickjs.bean.Res;
                import com.fongmi.quickjs.bean.Req;
                import com.fongmi.quickjs.utils.Crypto;
                import com.fongmi.quickjs.utils.Connect;
                import com.fongmi.quickjs.utils.JSUtil;
                import com.fongmi.quickjs.utils.Module;
                import com.github.catvod.net.OkHttp;
                import com.github.catvod.utils.Asset;
                import com.github.catvod.utils.UriUtil;
                import java.nio.charset.StandardCharsets;
                import java.security.KeyPair;
                import java.security.KeyPairGenerator;
                import java.util.Base64;
                import com.whl.quickjs.wrapper.JSArray;
                import com.whl.quickjs.wrapper.QuickJSContext;

                public class AndroidGolden {
                    private static void print(String key, Object value) { System.out.println(key + "=" + value); }

                    private static Res proxyRes(int buffer, String content) throws Exception {
                        Res value = new Res();
                        java.lang.reflect.Field bufferField = Res.class.getDeclaredField("buffer");
                        java.lang.reflect.Field contentField = Res.class.getDeclaredField("content");
                        bufferField.setAccessible(true);
                        contentField.setAccessible(true);
                        bufferField.set(value, buffer);
                        contentField.set(value, content);
                        return value;
                    }

                    private static <T> T field(T value, String name, Object fieldValue) throws Exception {
                        java.lang.reflect.Field field = value.getClass().getDeclaredField(name);
                        field.setAccessible(true);
                        field.set(value, fieldValue);
                        return value;
                    }

                    private static Req request(String method, int buffer, int redirect, int timeout) throws Exception {
                        Req value = new Req();
                        field(value, "method", method);
                        field(value, "buffer", buffer);
                        field(value, "redirect", redirect);
                        field(value, "timeout", timeout);
                        return value;
                    }

                    private static com.google.gson.JsonElement json(
                        String text,
                        java.util.Map<String, String> values
                    ) {
                        return new com.google.gson.JsonElement(text, values);
                    }

                    private static okhttp3.Response response(byte[] body) {
                        java.util.Map<String, java.util.List<String>> headers = new java.util.LinkedHashMap<>();
                        headers.put("x-one", java.util.List.of("one"));
                        headers.put("x-many", java.util.List.of("first", "second"));
                        return new okhttp3.Response(206, new okhttp3.Headers(headers), body);
                    }

                    public static void main(String[] args) throws Exception {
                        String key = "0123456789abcdef";
                        String iv = "abcdef9876543210";
                        String cbc = Crypto.aes("AES/CBC/PKCS5", true, "hello", false, key, iv, true);
                        String ecb = Crypto.aes("AES/ECB/PKCS5", true, "hello", false, key, null, true);
                        print("md5", Crypto.md5("hello"));
                        print("aes_cbc", cbc);
                        print("aes_ecb", ecb);
                        print("aes_cbc_plain", Crypto.aes("AES/CBC/PKCS5", false, cbc, true, key, iv, false));
                        print("aes_ecb_plain", Crypto.aes("AES/ECB/PKCS5", false, ecb, true, key, null, false));
                        print("aes_invalid_mode", Crypto.aes("AES/GCM/NoPadding", true, "hello", false, key, null, true));
                        print("aes_invalid_iv", Crypto.aes("AES/ECB/PKCS5", true, "hello", false, key, iv, true));
                        print("aes_invalid_base64", Crypto.aes("AES/ECB/PKCS5", false, "a", true, key, null, false));

                        KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
                        generator.initialize(1024);
                        KeyPair pair = generator.generateKeyPair();
                        String publicKey = Base64.getEncoder().encodeToString(pair.getPublic().getEncoded());
                        String privateKey = Base64.getEncoder().encodeToString(pair.getPrivate().getEncoded());
                        String publicPEM = "-----BEGIN PUBLIC KEY-----\\n" + publicKey + "\\n-----END PUBLIC KEY-----";
                        String privatePEM = "-----BEGIN PRIVATE KEY-----\\n" + privateKey + "\\n-----END PRIVATE KEY-----";
                        String publicCipher = Crypto.rsa("RSA/PKCS1", true, true, "hello", false, publicKey, true);
                        String privateCipher = Crypto.rsa("RSA/PKCS1", false, true, "hello", false, privateKey, true);
                        print("rsa_public_plain", Crypto.rsa("RSA/PKCS1", false, false, publicCipher, true, privateKey, false));
                        print("rsa_private_plain", Crypto.rsa("RSA/PKCS1", true, false, privateCipher, true, publicKey, false));
                        String pemCipher = Crypto.rsa("RSA/PKCS1", true, true, "hello", false, publicPEM, true);
                        print("rsa_pem_plain", Crypto.rsa("RSA/PKCS1", false, false, pemCipher, true, privatePEM, false));
                        String unknownModeCipher = Crypto.rsa("RSA/OAEP", true, true, "hello", false, publicKey, true);
                        print("rsa_unknown_mode_plain", Crypto.rsa("RSA/PKCS1", false, false, unknownModeCipher, true, privateKey, false));
                        print("rsa_invalid_key", Crypto.rsa("RSA/PKCS1", true, true, "hello", false, "not-a-key", true));
                        print("rsa_invalid_pem", Crypto.rsa("RSA/PKCS1", true, true, "hello", false, "-----BEGIN RSA PRIVATE KEY-----\\nAQ==\\n-----END RSA PRIVATE KEY-----", true));
                        print("rsa_truncated_pem", Crypto.rsa("RSA/PKCS1", true, true, "hello", false, "-----BEGIN PUBLIC KEY-----\\nAQ==\\n-----END PUBLIC KEY-----", true));
                        String encryptedPrivatePEM = "-----BEGIN ENCRYPTED PRIVATE KEY-----\\n" + privateKey + "\\n-----END ENCRYPTED PRIVATE KEY-----";
                        print("rsa_encrypted_private_pem", Crypto.rsa("RSA/PKCS1", false, false, publicCipher, true, encryptedPrivatePEM, false));

                        Local local = new Local();
                        print("local_missing", local.get("golden", "missing"));
                        local.set("golden", "empty", "");
                        print("local_empty", local.get("golden", "empty"));
                        local.set("golden", "token", "persisted");
                        print("local_token", local.get("golden", "token"));
                        local.delete("golden", "token");
                        print("local_deleted", local.get("golden", "token"));

                        Module module = Module.get();
                        print("module_remote", module.fetch("https://golden.example/module"));
                        module.fetch("https://golden.example/module");
                        print("module_asset", module.fetch("assets/fixture.js"));
                        print("module_lib", module.fetch("lib/fixture.js"));
                        print("module_unsupported", module.fetch("fixture.js"));
                        print("module_uppercase_http", module.fetch("HTTP://golden.example/module"));
                        print("module_uppercase_assets", module.fetch("ASSETS://fixture.js"));
                        print("module_remote_reads", OkHttp.reads);
                        print("module_asset_reads", Asset.reads);
                        module.clear();
                        module.fetch("https://golden.example/module");
                        print("module_remote_reads_after_clear", OkHttp.reads);
                        int moduleLRUReadsBefore = OkHttp.reads;
                        boolean moduleLRUValues = true;
                        for (int index = 0; index < 51; index++) {
                            String value = module.fetch("https://golden.example/lru/" + index);
                            moduleLRUValues &= value.equals("module-lru-" + index);
                        }
                        module.fetch("https://golden.example/lru/0");
                        print("module_lru_values", moduleLRUValues);
                        print("module_lru_reads", OkHttp.reads - moduleLRUReadsBefore);

                        String baseURL = "https://example.test/a/b/page?old=1#frag";
                        print("url_relative", UriUtil.resolve(baseURL, "../detail?new=2#next"));
                        print("url_query", UriUtil.resolve(baseURL, "?new=2#next"));
                        print("url_fragment", UriUtil.resolve(baseURL, "#next"));
                        print("url_empty", UriUtil.resolve(baseURL, ""));
                        print("url_network", UriUtil.resolve(baseURL, "//cdn.example.test/a/../media.ts"));
                        print("url_absolute", UriUtil.resolve(baseURL, "https://cdn.example.test/a/../media.ts"));
                        print("url_double_slash", UriUtil.resolve(baseURL, "/a//b/./c"));
                        print("url_above_root", UriUtil.resolve(baseURL, "../../../../x"));
                        JSArray signedBytes = JSUtil.toArray(new QuickJSContext(), new byte[] {0, 127, -1, -128});
                        print("bytes_signed", signedBytes);
                        print("proxy_text_stream", java.util.Arrays.toString(proxyRes(0, "hello").getStream().readAllBytes()));
                        print("proxy_base64_stream", java.util.Arrays.toString(proxyRes(2, "AP+A").getStream().readAllBytes()));

                        Req defaults = new Req();
                        print("req_defaults", defaults.getBuffer() + "," + defaults.getRedirect() + "," + defaults.getTimeout()
                            + "," + defaults.getPostType() + "," + defaults.getMethod() + "," + defaults.getCharset());
                        okhttp3.Call getCall = Connect.to("https://golden.example/get", request("get", 0, 1, 10000));
                        Req post = request("post", 0, 1, 10000);
                        field(post, "body", "latin-body");
                        field(post, "headers", json("{}", java.util.Map.of("Content-Type", "text/plain; charset=ISO-8859-1")));
                        okhttp3.Call postCall = Connect.to("https://golden.example/post", post);
                        okhttp3.Call headCall = Connect.to("https://golden.example/head", request("header", 0, 1, 10000));
                        okhttp3.Call fallbackCall = Connect.to("https://golden.example/fallback", request("PUT", 0, 0, 2500));
                        print("connect_methods", getCall.request.method + "," + postCall.request.method + ","
                            + headCall.request.method + "," + fallbackCall.request.method);
                        print("connect_client_policy", com.github.catvod.net.OkHttp.lastRedirect + ","
                            + com.github.catvod.net.OkHttp.lastTimeout);
                        print("connect_raw_body", postCall.request.body.text());

                        Req emptyPost = request("post", 0, 1, 10000);
                        field(emptyPost, "body", "discarded");
                        print("connect_empty_body", Connect.to("https://golden.example/empty", emptyPost).request.body.bytes.length);
                        Req jsonPost = request("post", 0, 1, 10000);
                        field(jsonPost, "postType", "json");
                        field(jsonPost, "data", json("{\\\"value\\\":1}", java.util.Map.of()));
                        print("connect_json_body", Connect.to("https://golden.example/json", jsonPost).request.body.text());
                        Req formPost = request("post", 0, 1, 10000);
                        field(formPost, "postType", "form");
                        field(formPost, "data", json("{}", java.util.Map.of("a", "1")));
                        print("connect_form_body", Connect.to("https://golden.example/form", formPost).request.body.getClass().getSimpleName());
                        Req multipartPost = request("post", 0, 1, 10000);
                        field(multipartPost, "postType", "form-data");
                        field(multipartPost, "data", json("{}", java.util.Map.of("a", "1")));
                        okhttp3.MultipartBody multipart = (okhttp3.MultipartBody) Connect.to(
                            "https://golden.example/multipart", multipartPost
                        ).request.body;
                        print("connect_multipart_body", multipart.getClass().getSimpleName() + ","
                            + multipart.boundary.startsWith("--dio-boundary-"));

                        Req latin1 = request("get", 0, 1, 10000);
                        field(latin1, "headers", json("{}", java.util.Map.of("content-type", "text/plain;charset=ISO-8859-1")));
                        com.whl.quickjs.wrapper.JSObject buffer0 = Connect.success(
                            new QuickJSContext(), latin1, response(new byte[] {(byte) 0xe9})
                        );
                        print("connect_buffer_0", buffer0.getProperty("content"));
                        com.whl.quickjs.wrapper.JSObject buffer1 = Connect.success(
                            new QuickJSContext(), request("get", 1, 1, 10000), response(new byte[] {0, 127, -1, -128})
                        );
                        print("connect_buffer_1", buffer1.getProperty("content"));
                        com.whl.quickjs.wrapper.JSObject buffer2 = Connect.success(
                            new QuickJSContext(), request("get", 2, 1, 10000), response(new byte[] {0, 127, -1, -128})
                        );
                        print("connect_buffer_2", buffer2.getProperty("content"));
                        com.whl.quickjs.wrapper.JSObject buffer3 = Connect.success(
                            new QuickJSContext(), request("get", 3, 1, 10000), response(new byte[] {0, 127, -1, -128})
                        );
                        print("connect_buffer_3", java.util.Arrays.toString((byte[]) buffer3.getProperty("content")));
                        com.whl.quickjs.wrapper.JSObject bufferUnknown = Connect.success(
                            new QuickJSContext(), request("get", 4, 1, 10000), response(new byte[] {1})
                        );
                        print("connect_buffer_unknown", bufferUnknown.hasProperty("content"));
                        com.whl.quickjs.wrapper.JSObject responseHeaders = (com.whl.quickjs.wrapper.JSObject) buffer0.getProperty("headers");
                        print("connect_headers", responseHeaders.getProperty("x-one") + "," + responseHeaders.getProperty("x-many"));
                        com.whl.quickjs.wrapper.JSObject error = Connect.error(new QuickJSContext());
                        print("connect_error", error.getProperty("content") + "," + error.getProperty("code") + ","
                            + (error.getProperty("headers") instanceof com.whl.quickjs.wrapper.JSObject));
                    }
                }
            """,
        }
        for relative, content in files.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(textwrap.dedent(content).strip() + "\n", encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
