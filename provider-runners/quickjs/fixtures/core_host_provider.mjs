export class Spider {
    init() {
        console.log("quickjs-core-host-fixture");
        return {
            base64: typeof base64Encode === "function" ? base64Encode("你好") : "missing",
            decoded: typeof base64Decode === "function" ? base64Decode("5L2g5aW9") : "missing",
            md5: typeof md5X === "function" ? md5X("abc") : "missing",
            url: typeof joinUrl === "function" ? joinUrl("https://example.test/catalog/page", "../detail") : "missing",
            query: typeof joinUrl === "function" ? joinUrl("https://example.test/catalog/page?old=1#old", "?new=2#new") : "missing",
        };
    }

    destroy() {}
}
