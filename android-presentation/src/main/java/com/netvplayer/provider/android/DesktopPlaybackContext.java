package com.netvplayer.provider.android;

import java.net.HttpURLConnection;
import java.net.Proxy;
import java.net.URI;

/** Checks the app's bounded, source-bound current playback lease, never an external service. */
final class DesktopPlaybackContext {
    private DesktopPlaybackContext() {}

    static String interactionRequest() {
        String root = System.getProperty("netvplayer.android.persistentDataDir", "");
        if (root.isEmpty()) return "";
        try {
            java.nio.file.Path file = java.nio.file.Path.of(root, ".runtime", "interaction-request");
            if (java.nio.file.Files.size(file) != 36) return "";
            String value = java.nio.file.Files.readString(file);
            return value.matches("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}") ? value : "";
        } catch (java.io.IOException unavailable) { return ""; }
    }

    /** Only presentation state crosses to the host; never images, text or account fields. */
    static void interactionState(String request, String state) {
        if (request.isEmpty() || !request.equals(interactionRequest())) return;
        java.nio.file.Path directory = java.nio.file.Path.of(System.getProperty("netvplayer.android.persistentDataDir"), ".runtime");
        java.nio.file.Path file = directory.resolve("interaction-" + request + ".state");
        java.nio.file.Path temporary = null;
        try {
            String previous = java.nio.file.Files.exists(file) ? java.nio.file.Files.readString(file) : "";
            if (previous.equals("canceled") || previous.equals(state) || (previous.isEmpty() && state.equals("idle"))) return;
            temporary = java.nio.file.Files.createTempFile(directory, "interaction-", ".tmp");
            java.nio.file.Files.writeString(temporary, state);
            java.nio.file.Files.move(temporary, file, java.nio.file.StandardCopyOption.ATOMIC_MOVE,
                java.nio.file.StandardCopyOption.REPLACE_EXISTING);
            System.err.println("[ANDROID_PLATFORM_UI] interaction_" + state);
        } catch (java.io.IOException unavailable) {
            System.err.println("[ANDROID_PLATFORM_UI] interaction_signal_failed");
        } finally {
            if (temporary != null) try { java.nio.file.Files.deleteIfExists(temporary); } catch (java.io.IOException ignored) {}
        }
    }

    static String authorizationDrive() {
        String root = System.getProperty("netvplayer.android.persistentDataDir", "");
        if (!root.isEmpty()) {
            java.nio.file.Path file = java.nio.file.Path.of(root, ".runtime", "authorization-drive");
            try {
                if (java.nio.file.Files.exists(file)) {
                    if (java.nio.file.Files.size(file) > 32) return "";
                    String drive = java.nio.file.Files.readString(file).strip();
                    return java.util.Set.of("baidu", "ali", "quark", "uc").contains(drive) ? drive : "";
                }
            } catch (java.io.IOException unavailable) { return ""; }
        }
        return System.getProperty("netvplayer.android.authorizationDrive", "");
    }

    static boolean active() {
        String source = System.getProperty("netvplayer.android.sourceIdentity", "");
        if (!source.matches("[0-9a-f]{64}")) return false;
        HttpURLConnection connection = null;
        try {
            connection = (HttpURLConnection) URI.create("http://127.0.0.1:9978/media?source=" + source)
                .toURL().openConnection(Proxy.NO_PROXY);
            connection.setConnectTimeout(500);
            connection.setReadTimeout(500);
            connection.setInstanceFollowRedirects(false);
            connection.setUseCaches(false);
            connection.setRequestMethod("HEAD");
            return connection.getResponseCode() == 200;
        } catch (Exception unavailable) {
            return false;
        } finally { if (connection != null) connection.disconnect(); }
    }
}
