package com.netvplayer.provider.android;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.Application;
import android.app.Dialog;
import android.content.ComponentName;
import android.content.Context;
import android.content.DialogInterface;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.drawable.BitmapDrawable;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.view.ViewGroup;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ListAdapter;
import android.widget.TextView;
import java.awt.BorderLayout;
import java.awt.Dimension;
import java.awt.EventQueue;
import java.awt.GraphicsEnvironment;
import java.awt.Window;
import java.awt.event.WindowAdapter;
import java.awt.event.WindowEvent;
import java.awt.image.BufferedImage;
import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.Collection;
import java.util.IdentityHashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import javax.swing.BorderFactory;
import javax.swing.BoxLayout;
import javax.swing.ImageIcon;
import javax.swing.JButton;
import javax.swing.JCheckBox;
import javax.swing.JComponent;
import javax.swing.JDialog;
import javax.swing.JFrame;
import javax.swing.JLabel;
import javax.swing.JPanel;
import javax.swing.JScrollPane;
import javax.swing.JTextArea;
import javax.swing.JTextField;

/** Desktop window backend for original Android Activity / Dialog objects.
 * No Provider classes, authentication state or script results are changed.
 * Playback lifecycle reads only the app-owned source-bound loopback media lease.
 * Android callbacks always run on its main MessageQueue; Swing owns only native presentation.
 */
public final class DesktopAndroidUI {
    private static final ActivityRecords RECORDS = new ActivityRecords();
    private static final Map<Dialog, Presented> DIALOGS = new IdentityHashMap<>();
    // Desktop queue only; Android dialogs keep their original showing/callback state.
    private static final List<Presented> WINDOWS = new ArrayList<>();
    private static long presentationOrder;
    private static Presented foregroundDialog;
    private static Context applicationContext;
    private static boolean mayOpen;
    private static volatile HostActivity activity;
    private static DesktopPlayActivity playbackActivity;
    private static volatile JFrame frame;
    private static boolean refreshScheduled;
    private static boolean closing;
    private static int activeCalls;
    private static boolean focusInstalled;
    private static volatile Throwable failure;
    private DesktopAndroidUI() {}

    /** Called by the framework ActivityThread constructor. Empty until a real window opens. */
    public static Map<Object, ActivityRecord> activityRecords() { return RECORDS; }

    /** An actual user playback operation permits a UI request; catalog operations open no window. */
    public static void begin(Context context) {
        if (!enabled()) return;
        onMain(() -> {
            destroyPlaybackActivity();
            applicationContext = context.getApplicationContext();
            mayOpen = true;
            activeCalls++;
            failure = null;
        });
    }

    public static void end() {
        if (!enabled()) return;
        onMain(() -> {
            if (activeCalls > 0) activeCalls--;
            if (activeCalls == 0 && DIALOGS.isEmpty()) close();
        });
    }

    private static boolean enabled() { return Boolean.getBoolean("netvplayer.android.desktopUI"); }

    private static final class ActivityRecords extends LinkedHashMap<Object, ActivityRecord> {
        @Override public Collection<ActivityRecord> values() {
            if (!enabled()) return new ArrayList<>(super.values());
            java.util.concurrent.atomic.AtomicReference<List<ActivityRecord>> snapshot = new java.util.concurrent.atomic.AtomicReference<>();
            try {
                onMain(() -> {
                    if (mayOpen && activity == null) open();
                    if (activity == null && applicationContext instanceof Application app && DesktopPlaybackContext.active()) {
                        if (playbackActivity == null) {
                            playbackActivity = new DesktopPlayActivity();
                            playbackActivity.create(app);
                        }
                    } else { destroyPlaybackActivity(); }
                    snapshot.set(List.copyOf(super.values()));
                });
            } catch (RuntimeException | Error error) { failure = error; throw error; }
            return snapshot.get();
        }
    }

    /** The fields are read by Android applications through ActivityThread reflection. */
    public static final class ActivityRecord {
        public final Activity activity;
        public volatile boolean paused;
        ActivityRecord(Activity value) { activity = value; paused = true; }
    }

    /** Lifecycle belongs to the actual desktop host window, never a constant Activity stand-in. */
    public static class HostActivity extends Activity {
        private ActivityRecord record;
        private boolean destroyed;
        private boolean started;
        void create(Application app) {
            Intent intent = new Intent().setComponent(new ComponentName(app.getPackageName(), getClass().getName()));
            macapkAttach(app, intent);
            super.onCreate(null);
            app.dispatchActivityCreated(this, null);
            super.onStart();
            started = true;
            app.dispatchActivityStarted(this);
            record = new ActivityRecord(this);
            RECORDS.put(this, record);
            resume();
        }
        void resume() {
            if (record != null && record.paused && !destroyed) {
                if (!started) { super.onStart(); started = true; getApplication().dispatchActivityStarted(this); }
                super.onResume();
                getApplication().dispatchActivityResumed(this);
                record.paused = false;
                super.onWindowFocusChanged(true);
            }
        }
        void pause() {
            if (record != null && !record.paused && !destroyed) {
                record.paused = true;
                super.onWindowFocusChanged(false);
                super.onPause();
                getApplication().dispatchActivityPaused(this);
            }
        }
        void stop() {
            pause();
            if (started && !destroyed) {
                super.onStop(); started = false; getApplication().dispatchActivityStopped(this);
            }
        }
        void destroy() {
            if (destroyed) return;
            try { stop(); super.onDestroy(); getApplication().dispatchActivityDestroyed(this); }
            finally { destroyed = true; RECORDS.remove(this); }
        }
        @Override public boolean isDestroyed() { return destroyed; }
        @Override public void finish() { onMain(DesktopAndroidUI::close); }
    }

    /** Real Android lifecycle representation of the desktop player's active media request. */
    public static final class DesktopPlayActivity extends HostActivity {}

    private static void destroyPlaybackActivity() {
        if (playbackActivity != null) {
            playbackActivity.destroy();
            playbackActivity = null;
        }
    }

    private static void open() {
        if (activity != null || !mayOpen) return;
        if (!(applicationContext instanceof Application app)) throw new IllegalStateException("Android UI requires its attached Application");
        if (GraphicsEnvironment.isHeadless()) throw new IllegalStateException("Android UI requires an available desktop display");
        JFrame[] created = new JFrame[1];
        onDesktop(() -> {
            if (!focusInstalled) {
                java.awt.KeyboardFocusManager.getCurrentKeyboardFocusManager().addPropertyChangeListener("activeWindow", event -> {
                    Window window = (Window) event.getNewValue();
                    JFrame current = frame;
                    while (window != null && window != current) window = window.getOwner();
                    boolean active = current != null && window == current && hasVisibleWindow(current);
                    post(() -> { if (activity != null) { if (active) activity.resume(); else activity.pause(); } });
                });
                focusInstalled = true;
            }
            JFrame window = new JFrame("NetVplayer");
            window.setDefaultCloseOperation(JFrame.DO_NOTHING_ON_CLOSE);
            DesktopAndroidTheme.start();
            JPanel panel = DesktopAndroidTheme.surface(new BorderLayout(12, 18));
            panel.setBorder(BorderFactory.createEmptyBorder(28, 32, 28, 32));
            JPanel status = DesktopAndroidTheme.column();
            status.add(DesktopAndroidTheme.heading("正在准备播放"));
            status.add(javax.swing.Box.createVerticalStrut(10));
            status.add(label("正在等待当前线路响应。若需要网盘授权，将显示扫码说明。"));
            JScrollPane waiting = new JScrollPane(status);
            waiting.setBorder(BorderFactory.createEmptyBorder());
            waiting.setHorizontalScrollBarPolicy(JScrollPane.HORIZONTAL_SCROLLBAR_NEVER);
            panel.add(waiting, BorderLayout.CENTER);
            JButton close = DesktopAndroidTheme.button("取消操作", false);
            close.addActionListener(event -> cancelHostFromDesktop());
            panel.add(close, BorderLayout.SOUTH);
            window.setContentPane(panel);
            DesktopAndroidTheme.apply(panel);
            window.setMinimumSize(new Dimension(360, 240));
            window.pack();
            window.setLocationRelativeTo(null);
            window.addWindowListener(new WindowAdapter() {
                @Override public void windowClosing(WindowEvent event) { cancelHostFromDesktop(); }
                @Override public void windowIconified(WindowEvent event) { post(() -> { if (activity != null) activity.stop(); }); }
                @Override public void windowDeiconified(WindowEvent event) { post(() -> { if (activity != null) activity.resume(); }); }
                @Override public void windowActivated(WindowEvent event) { post(() -> { if (activity != null) activity.resume(); }); }
                @Override public void windowDeactivated(WindowEvent event) {
                    Window opposite = event.getOppositeWindow();
                    while (opposite != null && opposite != window) opposite = opposite.getOwner();
                    if (opposite == null) post(() -> { if (activity != null) activity.pause(); });
                }
            });
            window.setVisible(true);
            window.toFront();
            if (!window.isShowing()) { window.dispose(); throw new IllegalStateException("Android host window did not become visible"); }
            created[0] = window;
        });
        frame = created[0];
        try {
            HostActivity next = new HostActivity();
            next.create(app);
            activity = next;
            System.err.println("[ANDROID_PLATFORM_UI] activity_created");
        } catch (RuntimeException | Error error) {
            onDesktop(frame::dispose);
            frame = null;
            RECORDS.clear();
            throw error;
        }
    }

    public static void close() {
        if (Looper.myLooper() != Looper.getMainLooper()) { onMain(DesktopAndroidUI::close); return; }
        if (closing) return;
        destroyPlaybackActivity();
        mayOpen = false;
        activeCalls = 0;
        if (activity == null && DIALOGS.isEmpty()) return;
        closing = true;
        try {
            for (Dialog dialog : new ArrayList<>(DIALOGS.keySet())) {
                try { dialog.cancel(); }
                finally { dismissed(dialog); }
            }
        } finally {
            try { if (activity != null) activity.destroy(); }
            finally {
                activity = null;
                JFrame old = frame;
                frame = null;
                if (old != null) EventQueue.invokeLater(() -> {
                    old.dispose(); WINDOWS.clear(); foregroundDialog = null;
                });
                closing = false;
            }
        }
        System.err.println("[ANDROID_PLATFORM_UI] activity_destroyed");
    }

    /** Hook after the original framework show: its original Views/listeners are the data source. */
    public static void present(Dialog dialog) {
        if (!enabled()) return;
        try { presentOnMain(dialog); }
        catch (RuntimeException | Error error) { failure = error; throw error; }
    }

    private static void presentOnMain(Dialog dialog) {
        requireMain();
        if (closing || activity == null || frame == null) throw new IllegalStateException("Android Dialog has no visible desktop Activity");
        if (!dialog.isShowing()) return;
        Presented old = DIALOGS.get(dialog);
        if (old != null) {
            old.hidden = false;
            old.order = ++presentationOrder;
            refresh(old);
            publishInteraction(old.request);
            EventQueue.invokeLater(DesktopAndroidUI::restoreHostIfNeeded);
            return;
        }
        Presented next = new Presented(dialog);
        next.order = ++presentationOrder;
        DIALOGS.put(dialog, next);
        refresh(next);
        scheduleRefresh();
        System.err.println("[ANDROID_PLATFORM_UI] dialog_shown");
    }

    /** The original dismiss owns isShowing, onStop, listeners and Message callbacks. */
    public static void dismissed(Dialog dialog) {
        if (!enabled()) return;
        requireMain();
        Presented old = DIALOGS.remove(dialog);
        if (old != null) {
            old.disposed = true;
            publishInteraction(old.request);
            EventQueue.invokeLater(() -> {
                if (old.window != null) old.window.dispose();
                restoreHostIfNeeded();
            });
            if (!closing && activeCalls == 0 && DIALOGS.isEmpty()) close();
        }
    }

    /** Dialog.dismiss may be called by the original SDK worker; callbacks belong to Android main. */
    public static boolean dispatchDismiss(Dialog dialog) {
        if (Looper.myLooper() == Looper.getMainLooper()) return false;
        post(dialog::dismiss);
        return true;
    }

    /** Preserve original cancel objects while dispatching cancel once for each shown lifetime. */
    public static void cancel(Dialog dialog) {
        if (Looper.myLooper() != Looper.getMainLooper()) { post(() -> cancel(dialog)); return; }
        try {
            if (!Boolean.TRUE.equals(field(dialog, "mCanceled"))) {
                setField(dialog, "mCanceled", true);
                Object listener = field(dialog, "mCancelListener");
                if (listener instanceof DialogInterface.OnCancelListener callback) {
                    try { callback.onCancel(dialog); }
                    catch (Throwable error) { System.err.println("[ANDROID_PLATFORM_UI] cancel_callback_failed class=" + error.getClass().getName()); }
                }
                Object message = field(dialog, "mCancelMessage");
                if (message instanceof android.os.Message original) android.os.Message.obtain(original).sendToTarget();
            }
        } finally {
            dialog.dismiss();
        }
    }

    public static void hidden(Dialog dialog) {
        if (!enabled()) return;
        requireMain();
        Presented old = DIALOGS.get(dialog);
        if (old != null) {
            old.hidden = true;
            publishInteraction(old.request);
            EventQueue.invokeLater(() -> {
                if (old.window != null) old.window.setVisible(false);
                restoreHostIfNeeded();
            });
        }
    }

    private static final class Presented {
        final Dialog dialog;
        final String request = DesktopPlaybackContext.interactionRequest();
        boolean interactive;
        JDialog window;
        volatile boolean disposed;
        volatile boolean hidden;
        volatile long order;
        boolean positioned;
        final Map<View, JTextField> edits = new IdentityHashMap<>();
        String fingerprint;
        Presented(Dialog value) { dialog = value; }
    }

    private static void publishInteraction(String request) {
        boolean active = DIALOGS.values().stream().anyMatch(value -> value.request.equals(request)
            && !value.disposed && !value.hidden && value.interactive);
        DesktopPlaybackContext.interactionState(request, active ? "active" : "idle");
    }

    private static void cancelFromDesktop(Dialog dialog) {
        post(() -> {
            Presented shown = DIALOGS.get(dialog);
            if (shown == null || shown.disposed || !dialog.isShowing()) return;
            DesktopPlaybackContext.interactionState(shown.request, "canceled");
            dialog.cancel();
        });
    }

    private static void cancelHostFromDesktop() {
        post(() -> {
            DesktopPlaybackContext.interactionState(DesktopPlaybackContext.interactionRequest(), "canceled");
            close();
        });
    }

    private static void scheduleRefresh() {
        if (refreshScheduled || DIALOGS.isEmpty()) return;
        refreshScheduled = true;
        new Handler(Looper.getMainLooper()).postDelayed(() -> {
            refreshScheduled = false;
            for (Presented shown : new ArrayList<>(DIALOGS.values())) {
                if (!shown.dialog.isShowing()) dismissed(shown.dialog);
                else refresh(shown);
            }
            scheduleRefresh();
        }, 250);
    }

    private static void refresh(Presented shown) {
        try {
            Snapshot snapshot = snapshot(shown.dialog);
            shown.interactive = !snapshot.choices.isEmpty() || snapshot.buttons.stream().anyMatch(Action::primary)
                || interactive(snapshot.content);
            publishInteraction(shown.request);
            if (snapshot.fingerprint.equals(shown.fingerprint)) return;
            shown.fingerprint = snapshot.fingerprint;
            EventQueue.invokeLater(() -> {
                try { render(shown, snapshot); }
                catch (Throwable error) {
                    failure = error;
                    post(shown.dialog::cancel);
                    System.err.println("[ANDROID_PLATFORM_UI] desktop_render_failed class=" + error.getClass().getName());
                }
            });
        } catch (Throwable error) {
            failure = error;
            System.err.println("[ANDROID_PLATFORM_UI] render_failed class=" + error.getClass().getName());
            shown.dialog.cancel();
        }
    }

    private record Choice(String title, int index, boolean checked, boolean enabled) {}
    private record Action(String title, boolean enabled, boolean primary, Runnable callback) {}
    private record Node(String kind, String text, BufferedImage image, View view, boolean enabled, boolean clickable, List<Node> children) {}
    private record Snapshot(String title, String message, List<Choice> choices, boolean single, boolean multi,
                            List<Action> buttons, Node content, boolean cancelable, String fingerprint) {}

    private record AuthorizationCopy(String title, String instruction) {}

    private static boolean interactive(Node node) {
        return node != null && (node.image != null || node.kind.equals("edit") || node.kind.equals("button")
            || node.children.stream().anyMatch(DesktopAndroidUI::interactive));
    }

    /** App names follow the original SDK's QR instructions; source-provided copy wins. */
    private static AuthorizationCopy authorizationCopy(Snapshot snapshot) {
        if (!(snapshot.title.isBlank() || snapshot.title.equals("NetVplayer")) || !snapshot.message.isBlank()
            || !snapshot.choices.isEmpty() || !imageOnly(snapshot.content)) return null;
        String drive = DesktopPlaybackContext.authorizationDrive();
        String service = switch (drive) {
            case "quark" -> "夸克";
            case "baidu" -> "百度网盘";
            case "uc" -> "UC";
            case "ali" -> "阿里云盘";
            default -> "";
        };
        String app = switch (drive) {
            case "quark" -> "手机上的夸克浏览器 App";
            case "baidu" -> "手机上的百度网盘 App";
            case "uc" -> "手机上的 UC 浏览器 App";
            case "ali" -> "手机上的阿里云盘 App";
            default -> "该网盘对应的手机 App";
        };
        return new AuthorizationCopy(service + "扫码授权", "用" + app + "扫描下方二维码，\n在手机上确认登录后，将自动继续播放。\n二维码失效时，请取消后重新播放。");
    }

    private static boolean imageOnly(Node node) {
        if (node == null || node.kind.equals("hidden")) return false;
        if (node.kind.equals("image")) return node.image != null;
        return (node.kind.equals("vertical") || node.kind.equals("horizontal"))
            && node.children.stream().anyMatch(DesktopAndroidUI::imageOnly)
            && node.children.stream().allMatch(child -> child.kind.equals("hidden") || imageOnly(child));
    }

    /** A visible owned Dialog is the Activity's real surface while its waiting frame is hidden. */
    private static boolean hasVisibleWindow(Window owner) {
        if (owner.isShowing()) return true;
        for (Window child : owner.getOwnedWindows()) if (hasVisibleWindow(child)) return true;
        return false;
    }

    private static void restoreHostIfNeeded() {
        JFrame owner = frame;
        if (owner == null || !owner.isDisplayable()) return;
        WINDOWS.removeIf(shown -> shown.disposed);
        Presented top = null;
        for (Presented shown : WINDOWS)
            if (!shown.hidden && (top == null || shown.order > top.order)) top = shown;
        for (Presented shown : WINDOWS)
            if (shown != top && shown.window.isVisible()) shown.window.setVisible(false);
        if (top == null) {
            if (!owner.isVisible()) owner.setVisible(true);
        } else {
            if (owner.isVisible()) owner.setVisible(false);
            if (!top.window.isVisible()) top.window.setVisible(true);
            if (foregroundDialog != top) top.window.toFront();
        }
        foregroundDialog = top;
    }

    private static Snapshot snapshot(Dialog dialog) {
        String title = text(field(dialog, "mTitle"));
        String message = "";
        List<Choice> choices = new ArrayList<>();
        List<Action> buttons = new ArrayList<>();
        boolean single = false, multi = false;
        Node content = null;
        if (dialog instanceof AlertDialog alert) {
            message = text(alert.getMessage());
            Object adapter = field(alert, "mAdapter");
            single = Boolean.TRUE.equals(field(alert, "mIsSingleChoice"));
            multi = Boolean.TRUE.equals(field(alert, "mIsMultiChoice"));
            android.widget.ListView originalList = alert.getListView();
            if (adapter instanceof ListAdapter list) {
                if (list.getCount() > 2048) throw new IllegalStateException("Android Dialog item limit exceeded");
                if (originalList == null) throw new IllegalStateException("Android Dialog list was not created");
                for (int i = 0; i < list.getCount(); i++) choices.add(new Choice(text(list.getItem(i)), i,
                    originalList.isItemChecked(i), list.isEnabled(i)));
            }
            for (String kind : List.of("Negative", "Neutral", "Positive")) {
                int which = kind.equals("Positive") ? -1 : kind.equals("Negative") ? -2 : -3;
                android.widget.Button control = alert.getButton(which);
                String configured = text(field(alert, "mButton" + kind + "Text"));
                if (control == null) {
                    if (!configured.isEmpty()) throw new IllegalStateException("Android Dialog button was not created");
                    continue;
                }
                if (control.getVisibility() != View.VISIBLE) continue;
                String label = text(control.getText());
                if (!label.isEmpty()) buttons.add(new Action(label, control.isEnabled(), which == -1, () -> {
                    if (dialog.isShowing() && DIALOGS.containsKey(dialog) && control.isEnabled()) control.performClick();
                }));
            }
            Object custom = field(alert, "mView");
            if (custom instanceof View view) content = node(view, new int[] {0});
        } else if (dialog.getWindow() != null && dialog.getWindow().getDecorView() != null) {
            content = node(dialog.getWindow().getDecorView(), new int[] {0});
        }
        boolean cancelable = Boolean.TRUE.equals(field(dialog, "mCancelable"));
        String fingerprint = title + '\u0000' + message + choices + single + multi + buttons.stream().map(action -> action.title + ":" + action.enabled).toList()
            + fingerprint(content) + cancelable;
        return new Snapshot(title, message, List.copyOf(choices), single, multi, List.copyOf(buttons), content, cancelable, fingerprint);
    }

    private static Node node(View view, int[] count) {
        if (++count[0] > 256) throw new IllegalStateException("Android Dialog view limit exceeded");
        if (view.getVisibility() != View.VISIBLE) return new Node("hidden", "", null, view, view.isEnabled(), view.isClickable(), List.of());
        if (view instanceof android.webkit.WebView) throw new UnsupportedOperationException("Original Android WebView requires a browser backend");
        if (view instanceof ImageView image) {
            Bitmap bitmap = image.getDrawable() instanceof BitmapDrawable drawable ? drawable.getBitmap() : (Bitmap) field(image, "bitmap");
            BufferedImage output = null;
            if (bitmap != null) {
                int width = bitmap.getWidth(), height = bitmap.getHeight();
                if (width < 1 || height < 1 || width > 2048 || height > 2048) throw new IllegalStateException("Android Dialog bitmap limit exceeded");
                int[] pixels = new int[width * height];
                bitmap.getPixels(pixels, 0, width, 0, 0, width, height);
                output = new BufferedImage(width, height, BufferedImage.TYPE_INT_ARGB);
                output.setRGB(0, 0, width, height, pixels, 0, width);
            }
            return new Node("image", "", output, view, view.isEnabled(), view.isClickable(), List.of());
        }
        if (view instanceof EditText edit) return new Node("edit", text(edit.getText()), null, view, view.isEnabled(), view.isClickable(), List.of());
        if (view instanceof TextView label) return new Node(view instanceof android.widget.Button ? "button" : "text", text(label.getText()), null, view, view.isEnabled(), view.isClickable(), List.of());
        if (!(view instanceof ViewGroup) && view.getClass() != View.class && !(view instanceof android.widget.Space))
            throw new UnsupportedOperationException("Original custom-drawn Android View requires a renderer");
        if (view instanceof ViewGroup && view.isClickable())
            throw new UnsupportedOperationException("Original clickable Android container requires a renderer");
        List<Node> children = new ArrayList<>();
        if (view instanceof ViewGroup group) for (int i = 0; i < group.getChildCount(); i++) children.add(node(group.getChildAt(i), count));
        String kind = view instanceof LinearLayout linear && linear.getOrientation() == LinearLayout.HORIZONTAL ? "horizontal" : "vertical";
        return new Node(kind, "", null, view, view.isEnabled(), view.isClickable(), List.copyOf(children));
    }

    private static String fingerprint(Node node) {
        if (node == null) return "";
        int pixels = node.image == null ? 0 : java.util.Arrays.hashCode(node.image.getRGB(0, 0, node.image.getWidth(), node.image.getHeight(), null, 0, node.image.getWidth()));
        return node.kind + node.text + pixels + node.enabled + node.clickable + node.children.stream().map(DesktopAndroidUI::fingerprint).toList();
    }

    private static void render(Presented shown, Snapshot snapshot) {
        if (shown.disposed || shown.hidden) return;
        if (shown.window == null) {
            JDialog window = new JDialog(frame, snapshot.title, false);
            window.setDefaultCloseOperation(JDialog.DO_NOTHING_ON_CLOSE);
            window.addWindowListener(new WindowAdapter() {
                @Override public void windowClosing(WindowEvent event) {
                    post(() -> {
                        if (!shown.disposed && shown.dialog.isShowing() && Boolean.TRUE.equals(field(shown.dialog, "mCancelable")))
                              cancelFromDesktop(shown.dialog);
                    });
                }
            });
            shown.window = window;
            WINDOWS.add(shown);
        }
        JDialog window = shown.window;
        AuthorizationCopy authorization = authorizationCopy(snapshot);
        String title = authorization != null ? authorization.title : snapshot.title.isEmpty() ? "NetVplayer" : snapshot.title;
        window.setTitle(title);
        boolean first = !shown.positioned;
        java.awt.Component focus = java.awt.KeyboardFocusManager.getCurrentKeyboardFocusManager().getFocusOwner();
        int scrollPosition = shown.window.getContentPane().getComponentCount() > 0
            && shown.window.getContentPane().getComponent(0) instanceof JScrollPane old ? old.getVerticalScrollBar().getValue() : 0;
        JPanel body = DesktopAndroidTheme.column();
        body.setBorder(BorderFactory.createEmptyBorder(24, 24, 20, 24));
        JTextArea heading = DesktopAndroidTheme.heading(title);
        heading.setAlignmentX(java.awt.Component.LEFT_ALIGNMENT);
        body.add(heading);
        body.add(javax.swing.Box.createVerticalStrut(14));
        if (authorization != null) {
            JTextArea instruction = label(authorization.instruction);
            instruction.putClientProperty("theme.muted", true);
            body.add(instruction);
            body.add(javax.swing.Box.createVerticalStrut(14));
        }
        if (!snapshot.message.isEmpty()) { body.add(label(snapshot.message)); body.add(javax.swing.Box.createVerticalStrut(14)); }
        if (snapshot.content != null) {
            JComponent content = component(snapshot.content, shown);
            if (authorization != null) {
                describeAuthorizationImages(content);
                JPanel centered = DesktopAndroidTheme.panel();
                centered.setLayout(new java.awt.FlowLayout(java.awt.FlowLayout.CENTER, 0, 0));
                centered.setAlignmentX(java.awt.Component.LEFT_ALIGNMENT);
                centered.add(content);
                centered.setMaximumSize(new Dimension(Integer.MAX_VALUE, centered.getPreferredSize().height));
                content = centered;
            }
            body.add(content);
        }
        javax.swing.ButtonGroup radioGroup = new javax.swing.ButtonGroup();
        for (Choice choice : snapshot.choices) {
            if (snapshot.multi || snapshot.single) {
                javax.swing.AbstractButton button = snapshot.single
                    ? new javax.swing.JRadioButton(choice.title, choice.checked) : new JCheckBox(choice.title, choice.checked);
                if (snapshot.single) radioGroup.add(button);
                DesktopAndroidTheme.choice(button, snapshot.single);
                button.setEnabled(choice.enabled);
                button.addActionListener(event -> post(() -> choose(shown.dialog, choice.index, button.isSelected())));
                body.add(button);
            } else {
                JButton button = DesktopAndroidTheme.button(choice.title, false);
                button.setAlignmentX(java.awt.Component.LEFT_ALIGNMENT);
                button.setMaximumSize(new Dimension(Integer.MAX_VALUE, Math.max(36, button.getPreferredSize().height)));
                button.setEnabled(choice.enabled);
                button.addActionListener(event -> post(() -> choose(shown.dialog, choice.index, true)));
                body.add(button); body.add(javax.swing.Box.createVerticalStrut(6));
            }
        }
        JPanel actions = DesktopAndroidTheme.panel();
        actions.setLayout(new java.awt.FlowLayout(java.awt.FlowLayout.RIGHT, 8, 0));
        actions.setBorder(BorderFactory.createEmptyBorder(12, 16, 16, 16));
        window.getRootPane().setDefaultButton(null);
        for (Action action : snapshot.buttons) {
            JButton button = DesktopAndroidTheme.button(action.title, action.primary);
            button.setEnabled(action.enabled);
            button.addActionListener(event -> post(action.callback));
            actions.add(button);
            if (action.primary && action.enabled) window.getRootPane().setDefaultButton(button);
        }
        if (snapshot.buttons.isEmpty() && snapshot.cancelable) {
            JButton cancel = DesktopAndroidTheme.button("取消", false);
            cancel.addActionListener(event -> cancelFromDesktop(shown.dialog)); actions.add(cancel);
        }
        int actionWidth = 0;
        for (java.awt.Component action : actions.getComponents()) actionWidth += action.getPreferredSize().width + 8;
        if (actionWidth > 540) actions.setLayout(new java.awt.GridLayout(0, 1, 0, 8));
        JPanel root = DesktopAndroidTheme.surface(new BorderLayout());
        JScrollPane scroll = new JScrollPane(body);
        scroll.setHorizontalScrollBarPolicy(JScrollPane.HORIZONTAL_SCROLLBAR_NEVER);
        scroll.setBorder(BorderFactory.createEmptyBorder());
        root.add(scroll, BorderLayout.CENTER);
        if (actions.getComponentCount() > 0) root.add(actions, BorderLayout.SOUTH);
        window.setContentPane(root);
        DesktopAndroidTheme.apply(root);
        window.getRootPane().registerKeyboardAction(event -> {
            if (snapshot.cancelable) cancelFromDesktop(shown.dialog);
        }, javax.swing.KeyStroke.getKeyStroke(java.awt.event.KeyEvent.VK_ESCAPE, 0), JComponent.WHEN_IN_FOCUSED_WINDOW);
        if (first) {
            window.pack();
            java.awt.Rectangle screen = java.awt.GraphicsEnvironment.getLocalGraphicsEnvironment().getMaximumWindowBounds();
            window.setSize(Math.min(screen.width - 48, Math.min(640, Math.max(440, window.getWidth()))),
                Math.min(screen.height - 48, Math.min(720, Math.max(200, window.getHeight()))));
            window.setLocationRelativeTo(frame);
            shown.positioned = true;
        } else {
            scroll.getVerticalScrollBar().setValue(scrollPosition);
            if (focus != null && javax.swing.SwingUtilities.isDescendingFrom(focus, window)) focus.requestFocusInWindow();
            window.validate(); window.repaint();
        }
        restoreHostIfNeeded();
    }

    private static void choose(Dialog dialog, int index, boolean checked) {
        if (!dialog.isShowing() || !DIALOGS.containsKey(dialog)) return;
        if (!(dialog instanceof AlertDialog alert)) return;
        android.widget.ListView list = alert.getListView();
        if (list == null || list.getAdapter() == null || index < 0 || index >= list.getAdapter().getCount()
            || !list.getAdapter().isEnabled(index)) return;
        View row = list.getAdapter().getView(index, null, list);
        list.performItemClick(row, index, list.getAdapter().getItemId(index));
    }

    private static void describeAuthorizationImages(JComponent component) {
        if (Boolean.TRUE.equals(component.getClientProperty("theme.qr")))
            component.getAccessibleContext().setAccessibleName("扫码授权二维码");
        for (java.awt.Component child : component.getComponents())
            if (child instanceof JComponent nested) describeAuthorizationImages(nested);
    }

    private static JComponent component(Node node, Presented shown) {
        if (node.kind.equals("image")) {
            BufferedImage image = node.image;
            if (image != null && Math.max(image.getWidth(), image.getHeight()) > 300) {
                double scale = 300.0 / Math.max(image.getWidth(), image.getHeight());
                BufferedImage resized = new BufferedImage(Math.max(1,(int)(image.getWidth()*scale)), Math.max(1,(int)(image.getHeight()*scale)), BufferedImage.TYPE_INT_RGB);
                java.awt.Graphics2D g = resized.createGraphics(); g.setColor(java.awt.Color.WHITE); g.fillRect(0,0,resized.getWidth(),resized.getHeight());
                g.setRenderingHint(java.awt.RenderingHints.KEY_INTERPOLATION, java.awt.RenderingHints.VALUE_INTERPOLATION_NEAREST_NEIGHBOR);
                g.drawImage(image,0,0,resized.getWidth(),resized.getHeight(),null); g.dispose(); image=resized;
            }
            JComponent picture;
            if (!node.clickable) picture = image == null ? DesktopAndroidTheme.panel() : new JLabel(new ImageIcon(image));
            else { JButton b = DesktopAndroidTheme.button("", false); if (image != null) b.setIcon(new ImageIcon(image)); picture=b; }
            picture.putClientProperty("theme.qr", true); picture.setOpaque(true);
            picture.setBorder(BorderFactory.createEmptyBorder(12,12,12,12));
            picture.getAccessibleContext().setAccessibleName("图片");
            if (!(picture instanceof JButton button)) return picture;
            button.setEnabled(node.enabled);
            button.addActionListener(event -> post(() -> { if (!shown.disposed && node.view.isEnabled()) node.view.performClick(); }));
            return button;
        }
        if (node.kind.equals("text")) {
            if (node.clickable) {
                JButton button = DesktopAndroidTheme.button(node.text, false);
                button.setEnabled(node.enabled);
                button.addActionListener(event -> post(() -> { if (!shown.disposed && node.view.isEnabled()) node.view.performClick(); }));
                return button;
            }
            return label(node.text);
        }
        if (node.kind.equals("button")) {
            JButton button = DesktopAndroidTheme.button(node.text, false);
            button.setEnabled(node.enabled);
            button.addActionListener(event -> post(() -> { if (!shown.disposed && node.view.isEnabled()) node.view.performClick(); }));
            return button;
        }
        if (node.kind.equals("edit")) {
            JTextField edit = shown.edits.get(node.view);
            if (edit == null) {
                int inputType = ((EditText)node.view).getInputType();
                int variation = inputType & 0xff;
                boolean password = variation == 0x81 || variation == 0xe1 || variation == 0x12;
                edit = password ? new javax.swing.JPasswordField(node.text, 24) : new JTextField(node.text, 24);
                CharSequence hint = ((EditText)node.view).getHint();
                edit.getAccessibleContext().setAccessibleName(hint == null || hint.length() == 0 ? "输入内容" : hint.toString());
                DesktopAndroidTheme.input(edit);
                JTextField input = edit;
                input.getDocument().addDocumentListener(new javax.swing.event.DocumentListener() {
                    private void changed() { String value = input.getText(); post(() -> { if (!shown.disposed) ((EditText)node.view).setText(value); }); }
                    public void insertUpdate(javax.swing.event.DocumentEvent e) { changed(); }
                    public void removeUpdate(javax.swing.event.DocumentEvent e) { changed(); }
                    public void changedUpdate(javax.swing.event.DocumentEvent e) { changed(); }
                });
                shown.edits.put(node.view, edit);
            } else if (!edit.hasFocus() && !edit.getText().equals(node.text)) edit.setText(node.text);
            edit.setEnabled(node.enabled);
            CharSequence hint = ((EditText)node.view).getHint();
            if (hint != null && hint.length() > 0) {
                JPanel group = DesktopAndroidTheme.column();
                JTextArea caption = label(hint.toString());
                caption.putClientProperty("theme.muted", true);
                group.add(caption); group.add(edit);
                return group;
            }
            return edit;
        }
        JPanel panel = node.kind.equals("horizontal") ? DesktopAndroidTheme.panel() : DesktopAndroidTheme.column();
        panel.setAlignmentX(java.awt.Component.LEFT_ALIGNMENT);
        if (node.kind.equals("horizontal")) panel.setLayout(new BoxLayout(panel, BoxLayout.X_AXIS));
        for (Node child : node.children) panel.add(component(child, shown));
        return panel;
    }

    private static JTextArea label(String text) {
        JTextArea label = DesktopAndroidTheme.text(text);
        label.setBorder(BorderFactory.createEmptyBorder(0,0,4,0));
        return label;
    }

    private static Object field(Object target, String name) {
        for (Class<?> type = target.getClass(); type != null; type = type.getSuperclass()) {
            try { Field field = type.getDeclaredField(name); field.setAccessible(true); return field.get(target); }
            catch (NoSuchFieldException missing) { /* inspect the next actual superclass */ }
            catch (ReflectiveOperationException error) { throw new IllegalStateException("Android UI field unavailable: " + name, error); }
        }
        throw new IllegalStateException("Android UI field unavailable: " + name);
    }
    private static void setField(Object target, String name, Object value) {
        for (Class<?> type = target.getClass(); type != null; type = type.getSuperclass()) {
            try { Field field = type.getDeclaredField(name); field.setAccessible(true); field.set(target, value); return; }
            catch (NoSuchFieldException missing) { /* inspect the next actual superclass */ }
            catch (ReflectiveOperationException error) { throw new IllegalStateException("Android UI field unavailable: " + name, error); }
        }
        throw new IllegalStateException("Android UI field unavailable: " + name);
    }

    private static String text(Object value) {
        String text = value == null ? "" : value.toString();
        if (text.length() > 65536) throw new IllegalStateException("Android Dialog text limit exceeded");
        return text;
    }
    private static void requireMain() {
        if (Looper.myLooper() != Looper.getMainLooper()) throw new IllegalStateException("Android UI callback is not on its main looper");
    }
    private static void post(Runnable action) {
        new Handler(Looper.getMainLooper()).post(() -> {
            try { action.run(); }
            catch (Throwable error) {
                failure = error;
                System.err.println("[ANDROID_PLATFORM_UI] callback_failed class=" + error.getClass().getName());
            }
        });
    }
    private static void onMain(Runnable action) {
        if (Looper.myLooper() == Looper.getMainLooper()) { action.run(); return; }
        CompletableFuture<Void> completed = new CompletableFuture<>();
        if (!new Handler(Looper.getMainLooper()).post(() -> {
            try { action.run(); completed.complete(null); }
            catch (Throwable error) { completed.completeExceptionally(error); }
        })) throw new IllegalStateException("Android UI main looper rejected lifecycle work");
        try { completed.get(10, TimeUnit.SECONDS); }
        catch (InterruptedException error) { Thread.currentThread().interrupt(); throw new IllegalStateException("Android UI lifecycle interrupted", error); }
        catch (Exception error) { throw new IllegalStateException("Android UI lifecycle failed", error); }
    }
    private static void onDesktop(Runnable action) {
        if (EventQueue.isDispatchThread()) { action.run(); return; }
        try { EventQueue.invokeAndWait(action); }
        catch (InterruptedException error) { Thread.currentThread().interrupt(); throw new IllegalStateException("Desktop UI interrupted", error); }
        catch (Exception error) { throw new IllegalStateException("Desktop UI unavailable", error); }
    }

    public static void checkFailure() {
        if (enabled() && failure != null) throw new IllegalStateException("Original Android UI backend failed", failure);
    }

    /** Structural diagnostics only; no dialog text, images, callbacks or account data. */
    public static Map<String, Object> status() {
        Map<String, Object> result = new LinkedHashMap<>();
        onMain(() -> {
            result.put("activities", RECORDS.size());
            result.put("resumed", activity != null && !activity.record.paused);
            result.put("dialogs", DIALOGS.size());
            result.put("failure", failure == null ? "" : failure.getClass().getName());
        });
        onDesktop(() -> result.put("visible", frame != null && hasVisibleWindow(frame)));
        return result;
    }
}
