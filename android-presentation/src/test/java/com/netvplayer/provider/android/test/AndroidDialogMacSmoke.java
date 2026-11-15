package com.netvplayer.provider.android.test;

import android.app.Activity;
import android.app.Application;
import android.app.AlertDialog;
import android.content.Context;
import android.content.DialogInterface;
import android.os.Bundle;
import android.os.Looper;
import android.widget.Button;
import com.netvplayer.provider.android.DesktopAndroidUI;
import com.netvplayer.provider.android.ExperimentContext;
import com.netvplayer.provider.android.NativeExecution;
import fixture.AndroidDialogContract;
import java.awt.Component;
import java.awt.Container;
import java.awt.EventQueue;
import java.awt.Frame;
import java.awt.Image;
import java.awt.Window;
import java.awt.event.WindowEvent;
import java.awt.image.BufferedImage;
import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Callable;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.atomic.AtomicInteger;
import javax.swing.AbstractButton;
import javax.swing.ImageIcon;
import javax.swing.JDialog;
import javax.swing.JFrame;
import javax.swing.JLabel;
import javax.swing.text.JTextComponent;

/** Offline desktop driver: only controlled fixture Swing controls, never OS input. */
public final class AndroidDialogMacSmoke {
    private static final long TIMEOUT_MS = 6000;
    private static void check(boolean value, String name) {
        if (!value) throw new AssertionError(name);
        System.out.println("DIALOG_HOST_CASE " + name);
    }
    private interface Condition { boolean holds() throws Exception; }
    private static void await(Condition value, String name) throws Exception {
        long until = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(TIMEOUT_MS);
        while (!value.holds()) {
            if (System.nanoTime() >= until) throw new AssertionError("timeout: " + name);
            Thread.sleep(20);
        }
    }
    private static <T> T desktop(Callable<T> action) throws Exception {
        if (EventQueue.isDispatchThread()) return action.call();
        AtomicReference<T> result = new AtomicReference<>();
        AtomicReference<Throwable> failure = new AtomicReference<>();
        EventQueue.invokeAndWait(() -> { try { result.set(action.call()); } catch (Throwable e) { failure.set(e); } });
        Throwable value = failure.get();
        if (value instanceof Exception e) throw e;
        if (value instanceof Error e) throw e;
        if (value != null) throw new AssertionError(value);
        return result.get();
    }
    private static JFrame frame() {
        JFrame result = null;
        for (Frame window : Frame.getFrames()) if (window instanceof JFrame candidate
                && candidate.getTitle().equals("NetVplayer") && candidate.isDisplayable()) {
            if (result != null) throw new AssertionError("duplicate host frame");
            result = candidate;
        }
        return result;
    }
    @SuppressWarnings("unchecked")
    private static Map<Object, DesktopAndroidUI.ActivityRecord> reflectedRecords() throws Exception {
        Class<?> type = Class.forName("android.app.ActivityThread");
        Object thread = type.getMethod("currentActivityThread").invoke(null);
        Field field = type.getDeclaredField("mActivities"); field.setAccessible(true);
        return (Map<Object, DesktopAndroidUI.ActivityRecord>)field.get(thread);
    }
    private static final class Lifecycle implements Application.ActivityLifecycleCallbacks {
        final List<String> events = Collections.synchronizedList(new ArrayList<>());
        final AtomicReference<Throwable> error = new AtomicReference<>();
        void add(String event) {
            if (android.os.Looper.myLooper() != android.os.Looper.getMainLooper()) error.compareAndSet(null, new AssertionError("lifecycle off main: " + event));
            events.add(event);
        }
        public void onActivityCreated(Activity a, Bundle state) { add("create"); }
        public void onActivityStarted(Activity a) { add("start"); }
        public void onActivityResumed(Activity a) { add("resume"); }
        public void onActivityPaused(Activity a) { add("pause"); }
        public void onActivityStopped(Activity a) { add("stop"); }
        public void onActivitySaveInstanceState(Activity a, Bundle state) {}
        public void onActivityDestroyed(Activity a) { add("destroy"); }
    }

    public static void main(String[] args) {
        try {
            String mode = args[0];
            NativeExecution.initialize();
            Context context = ExperimentContext.create();
            Application app = (Application)context;
            Lifecycle lifecycle = new Lifecycle();
            AndroidDialogContract.onMain(() -> app.registerActivityLifecycleCallbacks(lifecycle));
            Map<Object, DesktopAndroidUI.ActivityRecord> records = reflectedRecords();
            check(records == DesktopAndroidUI.activityRecords(), "reflection_uses_platform_activity_records");
            check(records.values().isEmpty() && desktop(() -> frame() == null), "no_activity_or_window_before_begin");
            DesktopAndroidUI.begin(context);
            check(records.isEmpty() && !Boolean.TRUE.equals(DesktopAndroidUI.status().get("visible")), "begin_alone_does_not_claim_activity");
            if (mode.equals("disabled")) {
                check(records.values().isEmpty() && desktop(() -> frame() == null), "disabled_backend_registers_no_activity");
                DesktopAndroidUI.close();
                System.out.println("DIALOG_MAC_CONTRACT_OK mode=disabled");
                System.exit(0);
            }
            if (mode.equals("headless")) {
                boolean rejected = false;
                try { records.values(); }
                catch (IllegalStateException expected) {
                    for (Throwable cause = expected; cause != null; cause = cause.getCause())
                        if (String.valueOf(cause.getMessage()).contains("desktop display")) rejected = true;
                }
                check(rejected && records.isEmpty() && !Boolean.TRUE.equals(DesktopAndroidUI.status().get("visible")), "headless_failure_leaves_no_activity_record");
                DesktopAndroidUI.close();
                System.out.println("DIALOG_MAC_CONTRACT_OK mode=headless");
                System.exit(0);
            }
            Collection<DesktopAndroidUI.ActivityRecord> active = records.values();
            check(active.size() == 1 && records.size() == 1, "real_window_registers_one_activity");
            DesktopAndroidUI.ActivityRecord record = active.iterator().next();
            Activity activity = record.activity;
            JFrame host = desktop(() -> frame());
            check(host != null && desktop(host::isShowing) && !activity.isDestroyed(), "real_native_host_frame_visible");
            SwingDriver driver = new SwingDriver();
            int checks = AndroidDialogContract.run(activity, driver);
            workerDialogCompletion(activity, driver, false);
            workerDialogCompletion(activity, driver, true);
            originalButtonControls(activity, driver);
            dynamicCancelableControls(activity, driver, true);
            dynamicCancelableControls(activity, driver, false);
            cancelMessageFailureControl(activity, driver);
            desktop(() -> { host.dispatchEvent(new WindowEvent(host, WindowEvent.WINDOW_DEACTIVATED, (Window)null)); return null; });
            await(() -> record.paused && lifecycle.events.contains("pause"), "window deactivation pauses activity and dispatches callbacks");
            check(lifecycle.events.contains("pause"), "native_window_deactivation_dispatches_pause");
            desktop(() -> { host.dispatchEvent(new WindowEvent(host, WindowEvent.WINDOW_ACTIVATED)); return null; });
            await(() -> !record.paused && lifecycle.events.contains("resume"), "window activation resumes activity and dispatches callbacks");
            check(lifecycle.events.containsAll(Arrays.asList("create", "start", "resume", "pause")), "lifecycle_callbacks_registered_on_real_activity");
            DesktopAndroidUI.checkFailure();
            DesktopAndroidUI.close();
            await(() -> records.isEmpty() && desktop(() -> !host.isDisplayable()), "native window disposal and unregister");
            check(activity.isDestroyed() && record.paused && lifecycle.events.containsAll(Arrays.asList("stop", "destroy")), "close_destroys_activity_and_removes_record");
            check(lifecycle.error.get() == null && lifecycle.events.indexOf("create") < lifecycle.events.indexOf("start")
                && lifecycle.events.indexOf("start") < lifecycle.events.indexOf("resume")
                && lifecycle.events.indexOf("stop") < lifecycle.events.indexOf("destroy"), "lifecycle_order_and_android_main_callbacks");
            DesktopAndroidUI.close();
            check(records.isEmpty() && desktop(() -> frame() == null), "close_idempotent_no_activity_record");
            System.out.println("DIALOG_MAC_CONTRACT_OK mode=normal checks=" + checks);
            System.exit(0);
        } catch (Throwable failure) {
            failure.printStackTrace();
            try { DesktopAndroidUI.close(); } catch (Throwable ignored) {}
            System.exit(1);
        }
    }

    private static final class ControlEvents {
        final List<String> sequence = Collections.synchronizedList(new ArrayList<>());
        final AtomicInteger shown = new AtomicInteger(), canceled = new AtomicInteger(), dismissed = new AtomicInteger();
        final AtomicReference<Throwable> failure = new AtomicReference<>();
        void add(String value) {
            if (Looper.myLooper() != Looper.getMainLooper()) failure.compareAndSet(null, new AssertionError("control callback off Android main: " + value));
            sequence.add(value);
        }
        void attach(AlertDialog dialog) {
            dialog.setOnShowListener(d -> { add("show"); shown.incrementAndGet(); });
            dialog.setOnCancelListener(d -> { add("cancel"); canceled.incrementAndGet(); });
            dialog.setOnDismissListener(d -> { add("dismiss"); dismissed.incrementAndGet(); });
        }
        void settle() throws Exception {
            AndroidDialogContract.onMain(() -> {});
            Thread.sleep(100);
            if (failure.get() != null) throw new AssertionError(failure.get());
        }
    }

    private static void workerDialogCompletion(Activity activity, SwingDriver driver, boolean cancel) throws Exception {
        String title = cancel ? "Fixture worker cancel" : "Fixture worker dismiss";
        AtomicReference<AlertDialog> value = new AtomicReference<>();
        ControlEvents events = new ControlEvents();
        AndroidDialogContract.onMain(() -> {
            AlertDialog dialog = new AlertDialog.Builder(activity).setTitle(title).setMessage("Offline worker completion").create();
            events.attach(dialog); value.set(dialog); dialog.show();
        });
        AlertDialog dialog = value.get();
        driver.awaitShown(dialog, title);
        await(() -> events.shown.get() == 1, "worker fixture show callback");
        AtomicReference<Throwable> workerFailure = new AtomicReference<>();
        Thread worker = new Thread(() -> {
            try {
                if (Looper.myLooper() == Looper.getMainLooper()) throw new AssertionError("worker fixture unexpectedly on main");
                if (cancel) { dialog.cancel(); dialog.cancel(); }
                dialog.dismiss(); dialog.dismiss();
            } catch (Throwable failure) { workerFailure.set(failure); }
        }, cancel ? "fixture-original-cancel-worker" : "fixture-original-dismiss-worker");
        worker.start(); worker.join(4000);
        check(!worker.isAlive() && workerFailure.get() == null, cancel ? "worker_original_cancel_returns_without_failure" : "worker_original_dismiss_returns_without_failure");
        await(() -> events.dismissed.get() == 1, "worker completion on Android main");
        driver.awaitHidden(dialog, title); events.settle();
        List<String> expected = cancel ? Arrays.asList("show", "cancel", "dismiss") : Arrays.asList("show", "dismiss");
        check(events.sequence.equals(expected) && events.canceled.get() == (cancel ? 1 : 0) && events.dismissed.get() == 1,
            cancel ? "worker_cancel_once_then_dismiss_once_on_android_main" : "worker_dismiss_once_on_android_main");
        AndroidDialogContract.onMain(() -> check(!dialog.isShowing(), cancel ? "worker_cancel_preserves_original_showing_state" : "worker_dismiss_preserves_original_showing_state"));
    }

    private static void cancelMessageFailureControl(Activity activity, SwingDriver driver) throws Exception {
        String title = "Fixture cancel message failure";
        AtomicReference<AlertDialog> value = new AtomicReference<>();
        ControlEvents events = new ControlEvents();
        AndroidDialogContract.onMain(() -> {
            AlertDialog dialog = new AlertDialog.Builder(activity).setTitle(title).setMessage("Offline cancel message failure").create();
            events.attach(dialog);
            dialog.setCancelMessage(android.os.Message.obtain());
            value.set(dialog); dialog.show();
        });
        AlertDialog dialog = value.get();
        driver.awaitShown(dialog, title);
        await(() -> events.shown.get() == 1, "cancel message failure fixture show callback");
        AndroidDialogContract.onMain(() -> {
            boolean propagated = false;
            try { dialog.cancel(); }
            catch (RuntimeException expected) { propagated = true; }
            check(propagated, "invalid_original_cancel_message_failure_propagates");
            check(!dialog.isShowing(), "cancel_message_failure_still_runs_original_dismiss");
        });
        await(() -> events.dismissed.get() == 1, "cancel message failure original dismiss callback");
        driver.awaitHidden(dialog, title); events.settle();
        check(events.sequence.equals(Arrays.asList("show", "cancel", "dismiss"))
                && events.canceled.get() == 1 && events.dismissed.get() == 1,
            "cancel_message_failure_preserves_original_callbacks_once_on_android_main");
    }

    private static void dynamicCancelableControls(Activity activity, SwingDriver driver, boolean initiallyCancelable) throws Exception {
        String title = initiallyCancelable ? "Fixture cancelable true to false" : "Fixture cancelable false to true";
        AtomicReference<AlertDialog> value = new AtomicReference<>();
        ControlEvents events = new ControlEvents();
        AndroidDialogContract.onMain(() -> {
            AlertDialog dialog = new AlertDialog.Builder(activity).setTitle(title).setMessage("Offline dynamic cancelability").create();
            dialog.setCancelable(initiallyCancelable);
            events.attach(dialog); value.set(dialog); dialog.show();
        });
        AlertDialog dialog = value.get();
        driver.awaitShown(dialog, title);
        await(() -> events.shown.get() == 1, "dynamic cancelable fixture show callback");
        AndroidDialogContract.onMain(() -> dialog.setCancelable(!initiallyCancelable));
        driver.cancelWindow(dialog, title);
        if (initiallyCancelable) {
            events.settle();
            AndroidDialogContract.onMain(() -> check(dialog.isShowing() && events.canceled.get() == 0 && events.dismissed.get() == 0,
                "native_close_obeys_current_false_cancelable_without_original_callbacks"));
            check(desktop(() -> driver.dialog(title) != null), "noncancelable_native_close_keeps_original_window_visible");
            AndroidDialogContract.onMain(() -> dialog.setCancelable(true));
            driver.cancelWindow(dialog, title);
        }
        await(() -> events.dismissed.get() == 1, "dynamic cancelable original dismiss callback");
        driver.awaitHidden(dialog, title); events.settle();
        check(events.sequence.equals(Arrays.asList("show", "cancel", "dismiss"))
                && events.canceled.get() == 1 && events.dismissed.get() == 1,
            initiallyCancelable ? "native_close_reenabled_cancelable_callbacks_once_on_android_main"
                : "native_close_false_to_true_cancelable_callbacks_once_on_android_main");
        AndroidDialogContract.onMain(() -> check(!dialog.isShowing(), initiallyCancelable
            ? "reenabled_native_close_updates_original_showing_state" : "false_to_true_native_close_updates_original_showing_state"));
    }

    private static void originalButtonControls(Activity activity, SwingDriver driver) throws Exception {
        String title = "Fixture original button controls";
        String action = "Original standard action", customAction = "Original custom action";
        AtomicReference<AlertDialog> value = new AtomicReference<>();
        AtomicReference<Button> custom = new AtomicReference<>(), standard = new AtomicReference<>();
        AtomicInteger builderClicks = new AtomicInteger(), overrideClicks = new AtomicInteger(), customClicks = new AtomicInteger();
        ControlEvents events = new ControlEvents();
        AndroidDialogContract.onMain(() -> {
            Button original = new Button(activity); original.setText(customAction); custom.set(original);
            original.setOnClickListener(view -> {
                events.add("custom"); customClicks.incrementAndGet();
                if (view != original) events.failure.compareAndSet(null, new AssertionError("custom button View identity changed"));
            });
            AlertDialog dialog = new AlertDialog.Builder(activity).setTitle(title).setView(original)
                .setPositiveButton(action, (d, which) -> { events.add("builder"); builderClicks.incrementAndGet(); }).create();
            events.attach(dialog); value.set(dialog); dialog.show();
        });
        AlertDialog dialog = value.get(); driver.awaitShown(dialog, title);
        await(() -> events.shown.get() == 1, "button override fixture show callback");
        AndroidDialogContract.onMain(() -> {
            Button original = dialog.getButton(DialogInterface.BUTTON_POSITIVE);
            if (original == null) throw new AssertionError("missing original standard button");
            standard.set(original);
            original.setOnClickListener(view -> {
                events.add("override"); overrideClicks.incrementAndGet();
                if (view != original) events.failure.compareAndSet(null, new AssertionError("standard button View identity changed"));
            });
        });
        driver.clickText(dialog, title, action);
        await(() -> overrideClicks.get() == 1, "replacement standard View listener");
        events.settle();
        AndroidDialogContract.onMain(() -> check(dialog.isShowing() && builderClicks.get() == 0 && events.dismissed.get() == 0,
            "standard_button_listener_override_after_show_does_not_auto_dismiss"));
        driver.clickText(dialog, title, customAction);
        await(() -> customClicks.get() == 1, "original custom button callback");
        AndroidDialogContract.onMain(() -> { standard.get().setEnabled(false); custom.get().setEnabled(false); });
        await(() -> desktop(() -> {
            AbstractButton first = driver.button(title, action, false, false), second = driver.button(title, customAction, false, false);
            return first != null && second != null && !first.isEnabled() && !second.isEnabled();
        }), "disabled original standard and custom buttons reach native controls");
        check(true, "disabled_original_standard_and_custom_buttons_disable_native_controls");
        desktop(() -> {
            AbstractButton first = driver.button(title, action, false, false), second = driver.button(title, customAction, false, false);
            if (first == null || second == null || first.isEnabled() || second.isEnabled()) throw new AssertionError("disabled native controls changed before fixture click");
            first.doClick(0); second.doClick(0); return null;
        });
        events.settle();
        AndroidDialogContract.onMain(() -> check(overrideClicks.get() == 1 && customClicks.get() == 1 && builderClicks.get() == 0
                && dialog.isShowing() && events.dismissed.get() == 0, "disabled_native_buttons_deliver_no_original_callback"));
        AndroidDialogContract.onMain(() -> { standard.get().setEnabled(true); custom.get().setEnabled(true); });
        await(() -> desktop(() -> driver.button(title, action, false) != null && driver.button(title, customAction, false) != null), "native buttons reenable after original state change");
        driver.clickText(dialog, title, action); driver.clickText(dialog, title, customAction);
        await(() -> overrideClicks.get() == 2 && customClicks.get() == 2, "reenabled native buttons deliver original callbacks");
        events.settle();
        AndroidDialogContract.onMain(() -> check(builderClicks.get() == 0 && dialog.isShowing() && events.dismissed.get() == 0,
            "reenabled_buttons_preserve_replacement_and_original_view_listeners"));
        AndroidDialogContract.onMain(dialog::dismiss);
        await(() -> events.dismissed.get() == 1, "original controls final dismiss");
        driver.awaitHidden(dialog, title); events.settle();
        check(events.sequence.equals(Arrays.asList("show", "override", "custom", "override", "custom", "dismiss")),
            "button_override_enabled_state_preserves_callback_order_main");
    }

    private static final class SwingDriver implements AndroidDialogContract.Driver {
        private JDialog dialog(String title) {
            JDialog result = null;
            for (Window window : Window.getWindows()) if (window instanceof JDialog candidate
                    && candidate.getTitle().equals(title) && candidate.isShowing()) {
                if (result != null) throw new AssertionError("duplicate fixture dialog: " + title);
                result = candidate;
            }
            return result;
        }
        private void components(Component node, List<Component> result) {
            result.add(node);
            if (node instanceof Container container) for (Component child : container.getComponents()) components(child, result);
        }
        private List<Component> components(JDialog window) {
            List<Component> result = new ArrayList<>(); components(window.getContentPane(), result); return result;
        }
        public void awaitShown(android.app.AlertDialog source, String title) throws Exception {
            await(() -> desktop(() -> dialog(title) != null), "native fixture shown: " + title);
        }
        public void awaitHidden(android.app.AlertDialog source, String title) throws Exception {
            await(() -> desktop(() -> dialog(title) == null), "native fixture hidden: " + title);
        }
        private AbstractButton button(String title, String text, boolean choice) {
            return button(title, text, choice, true);
        }
        private AbstractButton button(String title, String text, boolean choice, boolean enabledOnly) {
            JDialog window = dialog(title);
            if (window == null) return null;
            AbstractButton result = null;
            for (Component component : components(window)) if (component instanceof AbstractButton candidate && candidate.isShowing()
                    && (!enabledOnly || candidate.isEnabled()) && (text.equals(candidate.getText()) || choice && candidate.getText().endsWith(" " + text))) {
                if (result != null) throw new AssertionError("ambiguous fixture control: " + text);
                result = candidate;
            }
            return result;
        }
        public void clickText(android.app.AlertDialog source, String title, String text) throws Exception {
            await(() -> desktop(() -> button(title, text, false) != null), "native button: " + text);
            desktop(() -> { AbstractButton control = button(title, text, false);
                if (control == null) throw new AssertionError("fixture button disappeared");
                control.doClick(0); return null; });
        }
        public void clickItem(android.app.AlertDialog source, String title, int position) throws Exception {
            AtomicReference<String> text = new AtomicReference<>();
            AndroidDialogContract.onMain(() -> text.set(String.valueOf(source.getListView().getAdapter().getItem(position))));
            await(() -> desktop(() -> button(title, text.get(), true) != null), "native item index " + position);
            desktop(() -> { AbstractButton control = button(title, text.get(), true);
                if (control == null) throw new AssertionError("fixture choice disappeared");
                control.doClick(0); return null; });
        }
        public void cancelWindow(android.app.AlertDialog source, String title) throws Exception {
            desktop(() -> { JDialog window = dialog(title);
                if (window == null) throw new AssertionError("missing cancel fixture");
                window.dispatchEvent(new WindowEvent(window, WindowEvent.WINDOW_CLOSING)); return null; });
        }
        public void awaitContent(android.app.AlertDialog source, String title, String expectedText, int[] expectedPixels, int width, int height) throws Exception {
            await(() -> desktop(() -> {
                JDialog window = dialog(title); if (window == null) return false;
                boolean text = false, pixels = false;
                for (Component component : components(window)) {
                    if (component instanceof JTextComponent value && expectedText.equals(value.getText())) text = true;
                    if (component instanceof JLabel value && expectedText.equals(value.getText())) text = true;
                    if (component instanceof JLabel value && value.getIcon() instanceof ImageIcon icon
                            && icon.getIconWidth() == width && icon.getIconHeight() == height) {
                        Image image = icon.getImage(); BufferedImage bitmap;
                        if (image instanceof BufferedImage buffer) bitmap = buffer;
                        else { bitmap = new BufferedImage(width, height, BufferedImage.TYPE_INT_ARGB);
                            java.awt.Graphics2D graphics = bitmap.createGraphics(); try { graphics.drawImage(image, 0, 0, null); } finally { graphics.dispose(); } }
                        pixels |= Arrays.equals(expectedPixels, bitmap.getRGB(0, 0, width, height, null, 0, width));
                    }
                }
                return text && pixels;
            }), "native exact bitmap and text: " + expectedText);
        }
    }
}
