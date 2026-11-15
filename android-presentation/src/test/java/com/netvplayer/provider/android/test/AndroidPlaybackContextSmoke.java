package com.netvplayer.provider.android.test;

import android.app.Activity;
import android.content.Context;
import com.netvplayer.provider.android.DesktopAndroidUI;
import com.netvplayer.provider.android.ExperimentContext;
import com.netvplayer.provider.android.NativeExecution;
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;

/** Offline loopback fixture: real framework Activity lifecycle, no Provider or accounts. */
public final class AndroidPlaybackContextSmoke {
    private static void check(boolean value, String name) {
        if (!value) throw new AssertionError(name);
        System.out.println("PLAYBACK_CONTEXT_CASE " + name);
    }
    public static void main(String[] args) throws Exception {
        String source = "a".repeat(64);
        AtomicBoolean active = new AtomicBoolean(false);
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 9978), 0);
        server.createContext("/media", exchange -> {
            boolean matches = ("source=" + source).equals(exchange.getRequestURI().getRawQuery());
            exchange.sendResponseHeaders(active.get() && matches ? 200 : 204, -1);
            exchange.close();
        });
        server.start();
        try {
            System.setProperty("netvplayer.android.sourceIdentity", source);
            NativeExecution.initialize();
            Context context = ExperimentContext.create();
            DesktopAndroidUI.begin(context);
            DesktopAndroidUI.end();
            Map<Object, DesktopAndroidUI.ActivityRecord> records = DesktopAndroidUI.activityRecords();
            check(records.values().isEmpty(), "no_media_no_playback_activity");
            active.set(true);
            var live = records.values();
            check(live.size() == 1, "current_same_source_has_one_activity");
            Activity activity = live.iterator().next().activity;
            check(activity.getComponentName().getClassName().contains("PlayActivity"), "playback_component_contract");
            check(!activity.isDestroyed(), "playback_activity_alive_during_request");
            check(!Boolean.TRUE.equals(DesktopAndroidUI.status().get("visible")), "no_extra_waiting_window");
            System.setProperty("netvplayer.android.sourceIdentity", "b".repeat(64));
            check(records.values().isEmpty() && activity.isDestroyed(), "different_source_destroys_old_activity");
            System.setProperty("netvplayer.android.sourceIdentity", source);
            check(records.values().size() == 1, "new_matching_request_can_resume");
            active.set(false);
            check(records.values().isEmpty(), "request_end_retires_playback_activity");
            DesktopAndroidUI.close();
            check(records.isEmpty(), "close_is_idempotent");
            System.out.println("PLAYBACK_CONTEXT_OK");
        } finally { server.stop(0); }
        System.exit(0);
    }
}
