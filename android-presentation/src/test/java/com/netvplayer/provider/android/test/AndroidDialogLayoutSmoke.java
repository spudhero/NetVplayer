package com.netvplayer.provider.android.test;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import fixture.AndroidDialogContract;
import com.netvplayer.provider.android.DesktopAndroidUI;
import com.netvplayer.provider.android.ExperimentContext;
import com.netvplayer.provider.android.NativeExecution;
import java.awt.*;
import java.awt.geom.Rectangle2D;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;
import javax.swing.*;

/** App-owned offline windows only: no Provider, credentials or real QR content. */
public final class AndroidDialogLayoutSmoke {
    static Activity activity;
    static boolean observe;
    static int failures;
    static final String MESSAGE = "正在等待手机确认授权。请先打开对应的手机应用扫描二维码，".repeat(3)
        + "\n确认后会自动继续播放；如二维码失效，请取消后重试。最后一行应该完整显示。";

    static void check(boolean value, String name) {
        if (!value) {
            failures++;
            if (!observe) throw new AssertionError(name);
        }
        System.out.println("LAYOUT_CASE " + name + (observe ? "=" + value : ""));
    }
    static <T> T desktop(java.util.concurrent.Callable<T> action) throws Exception {
        return DesktopAndroidThemeSmoke.desktop(action);
    }
    static void settle() throws Exception {
        Thread.sleep(350); desktop(() -> null);
    }
    static java.util.List<JDialog> visibleDialogs() {
        return Arrays.stream(Window.getWindows()).filter(w -> w instanceof JDialog && w.isShowing())
            .map(w -> (JDialog) w).toList();
    }
    static boolean only(String title) {
        var dialogs = visibleDialogs();
        return dialogs.size() == 1 && dialogs.getFirst().getTitle().equals(title)
            && Arrays.stream(Frame.getFrames()).noneMatch(Frame::isShowing);
    }
    static boolean allTextFits(Container root) throws Exception {
        boolean found = false;
        for (Component component : DesktopAndroidThemeSmoke.components(root)) {
            if (component instanceof JScrollPane scroll && scroll.getHorizontalScrollBarPolicy() == JScrollPane.HORIZONTAL_SCROLLBAR_NEVER
                && scroll.getViewport().getView().getWidth() > scroll.getViewport().getExtentSize().width) return false;
            if (!(component instanceof JTextArea text) || text.getText().isBlank()) continue;
            found = true;
            int end = text.getText().stripTrailing().length() - 1;
            Rectangle2D last = text.modelToView2D(end);
            Insets insets = text.getInsets();
            if (last == null || last.getMaxY() > text.getHeight() - insets.bottom + 1) return false;
        }
        return found;
    }
    static void export(Container root, Path target) throws Exception {
        var image = new java.awt.image.BufferedImage(root.getWidth(), root.getHeight(),
            java.awt.image.BufferedImage.TYPE_INT_RGB);
        Graphics2D g = image.createGraphics(); root.printAll(g); g.dispose();
        javax.imageio.ImageIO.write(image, "png", target.toFile());
    }
    static boolean lastLineVisibleAtBottom(Container root) throws Exception {
        JScrollPane scroll = (JScrollPane) root.getComponent(0);
        scroll.getVerticalScrollBar().setValue(scroll.getVerticalScrollBar().getMaximum());
        JViewport viewport = scroll.getViewport();
        JTextArea last = null;
        for (Component component : DesktopAndroidThemeSmoke.components(root))
            if (component instanceof JTextArea text && !text.getText().isBlank()) last = text;
        if (last == null) return false;
        Rectangle2D line = last.modelToView2D(last.getText().stripTrailing().length() - 1);
        Rectangle bounds = SwingUtilities.convertRectangle(last, line.getBounds(), viewport.getView());
        return viewport.getViewRect().contains(bounds);
    }
    public static void main(String[] args) {
        try {
            observe = args.length > 0 && args[0].equals("observe");
            Path output = Path.of(System.getProperty("netvplayer.android.layoutOutput", "."));
            Files.createDirectories(output);
            NativeExecution.initialize(); Context context = ExperimentContext.create();
            DesktopAndroidUI.begin(context);
            AndroidDialogContract.onMain(() -> {
                for (DesktopAndroidUI.ActivityRecord r : DesktopAndroidUI.activityRecords().values()) activity = r.activity;
            });
            DesktopAndroidThemeSmoke.activity = activity;
            settle();
            check(desktop(() -> {
                for (Frame f : Frame.getFrames()) if (f.isShowing() && f instanceof JFrame frame) {
                    frame.setSize(360, 240); frame.validate(); return allTextFits(frame);
                }
                return false;
            }), "waiting_host_last_line_fits_at_minimum_width");
            AlertDialog[] dialogs = new AlertDialog[2];
            AtomicInteger lowerCanceled = new AtomicInteger(), lowerDismissed = new AtomicInteger();
            AtomicInteger qrCanceled = new AtomicInteger(), qrDismissed = new AtomicInteger();
            System.setProperty("netvplayer.android.authorizationDrive", "quark");
            AndroidDialogContract.onMain(() -> {
                dialogs[0] = new AlertDialog.Builder(activity).setTitle("正在等待授权").setMessage(MESSAGE).create();
                dialogs[0].setOnCancelListener(d -> lowerCanceled.incrementAndGet());
                dialogs[0].setOnDismissListener(d -> lowerDismissed.incrementAndGet());
                dialogs[0].show();
                dialogs[1] = new AlertDialog.Builder(activity).setView(DesktopAndroidThemeSmoke.image()).create();
                dialogs[1].setOnCancelListener(d -> qrCanceled.incrementAndGet());
                dialogs[1].setOnDismissListener(d -> qrDismissed.incrementAndGet());
                dialogs[1].show();
            });
            settle();
            check(desktop(() -> only("夸克扫码授权")), "nested_qr_has_one_visible_window");
            check(dialogs[0].isShowing() && lowerCanceled.get() == 0 && lowerDismissed.get() == 0,
                "covered_original_dialog_keeps_sdk_state_and_callbacks");
            AndroidDialogContract.onMain(() -> dialogs[0].setMessage(MESSAGE + "\n底层状态已更新。"));
            settle();
            check(desktop(() -> only("夸克扫码授权")), "covered_refresh_does_not_reopen_lower_window");
            AndroidDialogContract.onMain(() -> dialogs[1].hide()); settle();
            check(desktop(() -> only("正在等待授权")), "hide_qr_restores_previous_dialog");
            AndroidDialogContract.onMain(() -> dialogs[1].show()); settle();
            check(desktop(() -> only("夸克扫码授权")), "reshow_qr_covers_previous_dialog");
            AndroidDialogContract.onMain(() -> dialogs[1].cancel()); settle();
            check(desktop(() -> only("正在等待授权")), "qr_cancel_restores_previous_dialog");
            check(qrCanceled.get() == 1 && qrDismissed.get() == 1
                && lowerCanceled.get() == 0 && lowerDismissed.get() == 0, "qr_cancel_does_not_cancel_underlying_operation");
            for (String mode : new String[] {"dark", "light"}) {
                Path theme = Path.of(System.getProperty("netvplayer.android.themeFile"));
                Files.writeString(theme, mode.equals("dark") ? "background=080411\nsurface=2A2241\nforeground=F7F2FF\n"
                    : "background=F8FBEF\nsurface=FFFDF8\nforeground=3F342B\n");
                Thread.sleep(600);
                for (int width : new int[] {440, 340, 600}) {
                    check(desktop(() -> only("正在等待授权")), "only_waiting_message_before_resize_" + mode + "_" + width);
                    desktop(() -> { var d = visibleDialogs().getFirst(); d.setSize(width, 230); d.validate(); return null; });
                    settle();
                    check(desktop(() -> allTextFits(visibleDialogs().getFirst())), "wrapped_message_last_line_fits_" + mode + "_" + width);
                    check(desktop(() -> lastLineVisibleAtBottom(visibleDialogs().getFirst().getContentPane())),
                        "last_line_scrolls_fully_into_view_" + mode + "_" + width);
                    desktop(() -> { export(visibleDialogs().getFirst().getContentPane(), output.resolve(mode + "-" + width + ".png")); return null; });
                }
            }
            AndroidDialogContract.onMain(() -> dialogs[0].cancel()); settle();
            check(lowerCanceled.get() == 1 && lowerDismissed.get() == 1, "lower_dialog_cancel_still_delivers_once");
            check(desktop(() -> visibleDialogs().isEmpty() && Arrays.stream(Frame.getFrames()).anyMatch(Frame::isShowing)),
                "host_returns_only_after_last_dialog_closes");
            DesktopAndroidUI.close(); settle();
            check(desktop(() -> Arrays.stream(Window.getWindows()).noneMatch(Window::isShowing)), "close_leaves_no_window");
            System.out.println(observe ? "LAYOUT_OBSERVATION_FAILED_CASES=" + failures : "LAYOUT_CONTRACT_OK");
            System.exit(0);
        } catch (Throwable error) { error.printStackTrace(); DesktopAndroidUI.close(); System.exit(1); }
    }
}
