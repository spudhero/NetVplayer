package com.netvplayer.provider.android.test;

import android.app.*;
import android.content.Context;
import com.netvplayer.provider.android.*;
import fixture.AndroidDialogContract;
import java.awt.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;
import javax.swing.*;

/** Original controls with synthetic pixels; no SDK, account or business network. */
public final class AndroidCloudAuthorizationSmoke {
    static Path current, signal;
    static AlertDialog active;
    static void check(boolean value, String name) {
        if (!value) throw new AssertionError(name);
        System.out.println("AUTHORIZATION_CASE " + name);
    }
    static String state() throws Exception { return Files.exists(signal) ? Files.readString(signal) : ""; }
    static void awaitState(String expected) throws Exception { DesktopAndroidThemeSmoke.await(() -> state().equals(expected)); }
    static void cancel() throws Exception {
        DesktopAndroidThemeSmoke.desktop(() -> {
            for (Component c : DesktopAndroidThemeSmoke.components(DesktopAndroidThemeSmoke.dialog()))
                if (c instanceof JButton b && b.getText().equals("取消")) { b.doClick(); break; }
            return null;
        });
    }
    public static void main(String[] args) {
        try {
            Path root = Path.of(System.getProperty("netvplayer.android.dataDir")).resolve("authorization-fixture");
            Files.createDirectories(root.resolve(".runtime"));
            System.setProperty("netvplayer.android.persistentDataDir", root.toString());
            current = root.resolve(".runtime/interaction-request");
            NativeExecution.initialize(); Context context = ExperimentContext.create();
            DesktopAndroidUI.begin(context);
            AndroidDialogContract.onMain(() -> {
                for (DesktopAndroidUI.ActivityRecord record : DesktopAndroidUI.activityRecords().values())
                    DesktopAndroidThemeSmoke.activity = record.activity;
            });
            String[][] services = {{"uc", "UC", "UC 浏览器 App"}, {"ali", "阿里云盘", "阿里云盘 App"},
                {"quark", "夸克", "夸克浏览器 App"}, {"baidu", "百度网盘", "百度网盘 App"}, {"unknown", "", "对应的手机 App"}};
            for (String[] service : services) {
                String request = UUID.randomUUID().toString();
                Files.writeString(current, request);
                signal = root.resolve(".runtime/interaction-" + request + ".state");
                Files.writeString(root.resolve(".runtime/authorization-drive"), service[0]);
                AtomicInteger canceled = new AtomicInteger(), dismissed = new AtomicInteger();
                AndroidDialogContract.onMain(() -> {
                    active = new AlertDialog.Builder(DesktopAndroidThemeSmoke.activity).setView(DesktopAndroidThemeSmoke.image()).create();
                    active.setOnCancelListener(d -> canceled.incrementAndGet());
                    active.setOnDismissListener(d -> dismissed.incrementAndGet());
                    active.show();
                });
                DesktopAndroidThemeSmoke.await(() -> DesktopAndroidThemeSmoke.desktop(() ->
                    DesktopAndroidThemeSmoke.dialog() != null && DesktopAndroidThemeSmoke.dialog().getTitle().equals(service[1] + "扫码授权")));
                check(DesktopAndroidThemeSmoke.desktop(() -> DesktopAndroidThemeSmoke.components(DesktopAndroidThemeSmoke.dialog()).stream()
                    .anyMatch(c -> c instanceof JTextArea t && t.getText().contains(service[2]) && t.getText().contains("自动继续播放"))), service[0] + "_scan_app_and_completion");
                awaitState("active"); check(true, service[0] + "_request_scoped_wait_active");
                check(DesktopAndroidThemeSmoke.desktop(() -> Arrays.stream(Window.getWindows()).filter(Window::isShowing).count() == 1
                    && AndroidDialogLayoutSmoke.allTextFits(DesktopAndroidThemeSmoke.dialog())), service[0] + "_one_window_and_complete_text");
                if (service[0].equals("uc")) {
                    Path output = Path.of(System.getProperty("netvplayer.android.layoutOutput"));
                    Files.createDirectories(output);
                    for (String theme : new String[] {"dark", "light"}) {
                        Files.writeString(Path.of(System.getProperty("netvplayer.android.themeFile")), theme.equals("dark")
                            ? "background=080411\nsurface=2A2241\nforeground=F7F2FF\nmuted=B8ACCF\naccent=54CFEF\nonAccent=080411\nsecondaryAccent=A77BFF\n"
                            : "background=F8FBEF\nsurface=FFFDF8\nforeground=3F342B\nmuted=6B5D52\naccent=876047\nonAccent=F8FBEF\nsecondaryAccent=8D4F66\n");
                        Thread.sleep(650);
                        DesktopAndroidThemeSmoke.desktop(() -> {
                            AndroidDialogLayoutSmoke.export(DesktopAndroidThemeSmoke.dialog().getContentPane(), output.resolve("uc-" + theme + ".png"));
                            return null;
                        });
                    }
                }
                AndroidDialogContract.onMain(() -> active.hide()); awaitState("idle");
                AndroidDialogContract.onMain(() -> active.show()); awaitState("active");
                check(canceled.get() == 0 && dismissed.get() == 0, service[0] + "_hide_show_preserves_callbacks");
                cancel(); awaitState("canceled");
                DesktopAndroidThemeSmoke.await(() -> canceled.get() == 1 && dismissed.get() == 1);
                check(state().equals("canceled"), service[0] + "_cancel_once_and_terminal_signal_survives_dismiss");
            }
            String request = UUID.randomUUID().toString(); Files.writeString(current, request);
            signal = root.resolve(".runtime/interaction-" + request + ".state");
            AndroidDialogContract.onMain(() -> { active = new AlertDialog.Builder(DesktopAndroidThemeSmoke.activity).setMessage("来源原文").setNegativeButton("取消", (d,w) -> {}).create(); active.show(); });
            Thread.sleep(350);
            check(!Files.exists(signal), "plain_waiting_text_does_not_pause_network_timeout");
            AndroidDialogContract.onMain(() -> active.dismiss());
            AndroidDialogContract.onMain(() -> { active = new AlertDialog.Builder(DesktopAndroidThemeSmoke.activity).setView(DesktopAndroidThemeSmoke.image()).create(); active.show(); });
            awaitState("active");
            String next = UUID.randomUUID().toString(); Files.writeString(current, next);
            Path newer = root.resolve(".runtime/interaction-" + next + ".state");
            AndroidDialogContract.onMain(() -> active.dismiss()); Thread.sleep(350);
            check(!Files.exists(newer), "old_dialog_does_not_signal_a_new_request");
            Files.writeString(current, request);
            AndroidDialogContract.onMain(() -> { active = new AlertDialog.Builder(DesktopAndroidThemeSmoke.activity).setView(DesktopAndroidThemeSmoke.image()).create(); active.show(); });
            awaitState("active");
            AndroidDialogContract.onMain(() -> active.dismiss()); awaitState("idle");
            check(true, "sdk_success_dismiss_resumes_network_budget_without_canceling");
            DesktopAndroidUI.end();
            System.out.println("AUTHORIZATION_CONTRACT_OK"); System.exit(0);
        } catch (Throwable error) { error.printStackTrace(); System.exit(1); }
    }
}
