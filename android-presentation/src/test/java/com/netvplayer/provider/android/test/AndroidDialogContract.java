package fixture;

import android.app.AlertDialog;
import android.content.Context;
import android.content.DialogInterface;
import android.graphics.Bitmap;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.widget.Button;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/** Java 8, Android SDK APIs only. Identical class files feed desktop and ART.
 * All data belongs to this offline fixture; no Provider or account code is loaded.
 */
public final class AndroidDialogContract {
    private static final long TIMEOUT_MS = 6000;
    private static int checks;
    private AndroidDialogContract() {}

    /** Drivers operate only the uniquely titled dialogs created by this fixture. */
    public interface Driver {
        void awaitShown(AlertDialog dialog, String title) throws Exception;
        void awaitHidden(AlertDialog dialog, String title) throws Exception;
        void clickText(AlertDialog dialog, String title, String text) throws Exception;
        void clickItem(AlertDialog dialog, String title, int position) throws Exception;
        void cancelWindow(AlertDialog dialog, String title) throws Exception;
        void awaitContent(AlertDialog dialog, String title, String text, int[] pixels, int width, int height) throws Exception;
    }

    public interface MainAction { void run() throws Exception; }

    public static void onMain(final MainAction action) throws Exception {
        if (Looper.myLooper() == Looper.getMainLooper()) { action.run(); return; }
        final CountDownLatch done = new CountDownLatch(1);
        final AtomicReference<Throwable> error = new AtomicReference<Throwable>();
        if (!new Handler(Looper.getMainLooper()).post(new Runnable() {
            public void run() {
                try { action.run(); } catch (Throwable value) { error.set(value); }
                finally { done.countDown(); }
            }
        })) throw new AssertionError("main queue rejected fixture action");
        if (!done.await(TIMEOUT_MS, TimeUnit.MILLISECONDS)) throw new AssertionError("fixture main queue timeout");
        Throwable value = error.get();
        if (value instanceof Exception) throw (Exception)value;
        if (value instanceof Error) throw (Error)value;
        if (value != null) throw new AssertionError(value);
    }

    private static final class Events {
        final AtomicInteger shown = new AtomicInteger(), canceled = new AtomicInteger(), dismissed = new AtomicInteger();
        final List<String> sequence = Collections.synchronizedList(new ArrayList<String>());
        final AtomicReference<Throwable> error = new AtomicReference<Throwable>();
        void add(String value) {
            if (Looper.myLooper() != Looper.getMainLooper()) error.compareAndSet(null, new AssertionError("callback off Android main: " + value));
            sequence.add(value);
        }
        void attach(AlertDialog dialog) {
            dialog.setOnShowListener(new DialogInterface.OnShowListener() {
                public void onShow(DialogInterface d) { add("show"); shown.incrementAndGet(); }
            });
            dialog.setOnCancelListener(new DialogInterface.OnCancelListener() {
                public void onCancel(DialogInterface d) { add("cancel"); canceled.incrementAndGet(); }
            });
            dialog.setOnDismissListener(new DialogInterface.OnDismissListener() {
                public void onDismiss(DialogInterface d) { add("dismiss"); dismissed.incrementAndGet(); }
            });
        }
        void healthy() { if (error.get() != null) throw new AssertionError(error.get()); }
    }

    private interface Condition { boolean holds() throws Exception; }
    private static void await(Condition condition, String detail) throws Exception {
        long until = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(TIMEOUT_MS);
        while (!condition.holds()) {
            if (System.nanoTime() >= until) throw new AssertionError("timeout: " + detail);
            Thread.sleep(15);
        }
    }
    private static void check(boolean value, String detail) {
        if (!value) throw new AssertionError(detail);
        checks++;
        System.out.println("DIALOG_CASE " + detail);
    }
    private static boolean showing(final AlertDialog dialog) throws Exception {
        final boolean[] result = new boolean[1];
        onMain(new MainAction() { public void run() { result[0] = dialog.isShowing(); } });
        return result[0];
    }
    private static void settled(Events events) throws Exception {
        onMain(new MainAction() { public void run() {} });
        Thread.sleep(70);
        events.healthy();
    }

    public static int run(final Context context, Driver driver) throws Exception {
        if (Looper.myLooper() == Looper.getMainLooper()) throw new AssertionError("contract must run off main");
        checks = 0;
        buttons(context, driver, DialogInterface.BUTTON_POSITIVE, "Positive");
        buttons(context, driver, DialogInterface.BUTTON_NEGATIVE, "Negative");
        buttons(context, driver, DialogInterface.BUTTON_NEUTRAL, "Neutral");
        list(context, driver);
        singleChoice(context, driver);
        multiChoice(context, driver);
        cancel(context, driver);
        hideShow(context, driver);
        customContent(context, driver);
        System.out.println("DIALOG_CONTRACT_OK checks=" + checks);
        return checks;
    }

    private static void buttons(final Context context, Driver driver, final int expected, String label) throws Exception {
        final String title = "Fixture buttons " + expected;
        final AlertDialog[] box = new AlertDialog[1];
        final Events events = new Events();
        final AtomicInteger clicked = new AtomicInteger(), which = new AtomicInteger(123);
        onMain(new MainAction() { public void run() {
            DialogInterface.OnClickListener listener = new DialogInterface.OnClickListener() {
                public void onClick(DialogInterface dialog, int value) { events.add("click:" + value); which.set(value); clicked.incrementAndGet(); }
            };
            box[0] = new AlertDialog.Builder(context).setTitle(title).setMessage("Offline callback contract")
                .setPositiveButton("Positive", listener).setNegativeButton("Negative", listener).setNeutralButton("Neutral", listener).create();
            events.attach(box[0]); box[0].show();
        } });
        final AlertDialog dialog = box[0];
        driver.awaitShown(dialog, title);
        await(new Condition() { public boolean holds() { return events.shown.get() == 1; } }, "show listener");
        driver.clickText(dialog, title, label);
        await(new Condition() { public boolean holds() { return events.dismissed.get() == 1; } }, "button dismiss listener");
        driver.awaitHidden(dialog, title);
        settled(events);
        check(clicked.get() == 1 && which.get() == expected && events.canceled.get() == 0 && !showing(dialog), "button_index_" + expected);
        check(events.sequence.equals(Arrays.asList("show", "click:" + expected, "dismiss")), "button_callback_order_main_" + expected);
        onMain(new MainAction() { public void run() { dialog.dismiss(); dialog.dismiss(); } });
        settled(events);
        check(events.dismissed.get() == 1, "dismiss_idempotent_" + expected);
    }

    private static void list(final Context context, Driver driver) throws Exception {
        final String title = "Fixture ordinary list";
        final AlertDialog[] box = new AlertDialog[1];
        final Events events = new Events();
        final AtomicInteger index = new AtomicInteger(-1), clicks = new AtomicInteger();
        onMain(new MainAction() { public void run() {
            box[0] = new AlertDialog.Builder(context).setTitle(title).setItems(new String[] {"List A", "List B", "List C"}, new DialogInterface.OnClickListener() {
                public void onClick(DialogInterface d, int position) { events.add("item:" + position); index.set(position); clicks.incrementAndGet(); }
            }).create();
            events.attach(box[0]); box[0].show();
        } });
        final AlertDialog dialog = box[0];
        driver.awaitShown(dialog, title); driver.clickItem(dialog, title, 1);
        await(new Condition() { public boolean holds() { return events.dismissed.get() == 1; } }, "ordinary list dismiss");
        driver.awaitHidden(dialog, title); settled(events);
        check(index.get() == 1 && clicks.get() == 1 && !showing(dialog), "ordinary_list_actual_control_index_and_auto_dismiss");
        check(events.sequence.equals(Arrays.asList("show", "item:1", "dismiss")), "ordinary_list_callback_order_main");
    }

    private static void singleChoice(final Context context, Driver driver) throws Exception {
        final String title = "Fixture single choice";
        final AlertDialog[] box = new AlertDialog[1]; final Events events = new Events();
        final AtomicInteger index = new AtomicInteger(-1), clicks = new AtomicInteger();
        onMain(new MainAction() { public void run() {
            box[0] = new AlertDialog.Builder(context).setTitle(title)
                .setSingleChoiceItems(new String[] {"Single A", "Single B", "Single C"}, 0, new DialogInterface.OnClickListener() {
                    public void onClick(DialogInterface d, int position) { events.add("single:" + position); index.set(position); clicks.incrementAndGet(); }
                }).create();
            events.attach(box[0]); box[0].show();
            check(box[0].getListView().getCheckedItemPosition() == 0, "single_choice_initial_index");
        } });
        final AlertDialog dialog = box[0];
        driver.awaitShown(dialog, title); driver.clickItem(dialog, title, 2);
        await(new Condition() { public boolean holds() { return clicks.get() == 1; } }, "single choice callback");
        settled(events);
        onMain(new MainAction() { public void run() {
            check(index.get() == 2 && dialog.getListView().getCheckedItemPosition() == 2
                && dialog.getListView().isItemChecked(2) && !dialog.getListView().isItemChecked(0), "single_choice_actual_control_updates_original_state");
            check(dialog.isShowing() && events.dismissed.get() == 0, "single_choice_stays_open");
            dialog.dismiss();
        } });
        await(new Condition() { public boolean holds() { return events.dismissed.get() == 1; } }, "single choice dismiss");
        driver.awaitHidden(dialog, title); settled(events);
        check(events.sequence.equals(Arrays.asList("show", "single:2", "dismiss")), "single_choice_callback_order_main");
    }

    private static void multiChoice(final Context context, Driver driver) throws Exception {
        final String title = "Fixture multiple choice";
        final boolean[] checked = {true, false, false}; final AlertDialog[] box = new AlertDialog[1];
        final Events events = new Events(); final AtomicInteger clicks = new AtomicInteger();
        onMain(new MainAction() { public void run() {
            box[0] = new AlertDialog.Builder(context).setTitle(title)
                .setMultiChoiceItems(new String[] {"Multi A", "Multi B", "Multi C"}, checked, new DialogInterface.OnMultiChoiceClickListener() {
                    public void onClick(DialogInterface d, int position, boolean selected) { events.add("multi:" + position + ":" + selected); clicks.incrementAndGet(); }
                }).setPositiveButton("Commit choices", new DialogInterface.OnClickListener() {
                    public void onClick(DialogInterface d, int value) { events.add("commit:" + value); }
                }).create();
            events.attach(box[0]); box[0].show();
        } });
        final AlertDialog dialog = box[0];
        driver.awaitShown(dialog, title);
        driver.clickItem(dialog, title, 1);
        await(new Condition() { public boolean holds() { return clicks.get() == 1; } }, "multi selected");
        driver.clickItem(dialog, title, 1);
        await(new Condition() { public boolean holds() { return clicks.get() == 2; } }, "multi unselected");
        driver.clickItem(dialog, title, 2);
        await(new Condition() { public boolean holds() { return clicks.get() == 3; } }, "multi second index");
        settled(events);
        onMain(new MainAction() { public void run() {
            check(Arrays.equals(checked, new boolean[] {true, false, true}) && dialog.getListView().isItemChecked(0)
                && !dialog.getListView().isItemChecked(1) && dialog.getListView().isItemChecked(2), "multi_choice_original_array_and_list_state");
            check(dialog.isShowing() && events.dismissed.get() == 0, "multi_choice_stays_open");
        } });
        driver.clickText(dialog, title, "Commit choices");
        await(new Condition() { public boolean holds() { return events.dismissed.get() == 1; } }, "multi commit dismiss");
        driver.awaitHidden(dialog, title); settled(events);
        check(events.sequence.equals(Arrays.asList("show", "multi:1:true", "multi:1:false", "multi:2:true", "commit:-1", "dismiss")), "multi_choice_callback_indices_order_main");
    }

    private static void cancel(final Context context, Driver driver) throws Exception {
        final String title = "Fixture window cancel";
        final Events events = new Events(); final AlertDialog[] box = new AlertDialog[1];
        onMain(new MainAction() { public void run() {
            box[0] = new AlertDialog.Builder(context).setTitle(title).setMessage("Close this fixture window").create();
            events.attach(box[0]); box[0].show();
        } });
        final AlertDialog dialog = box[0];
        driver.awaitShown(dialog, title); driver.cancelWindow(dialog, title);
        await(new Condition() { public boolean holds() { return events.dismissed.get() == 1; } }, "window cancel dismiss");
        driver.awaitHidden(dialog, title);
        onMain(new MainAction() { public void run() { dialog.cancel(); dialog.cancel(); dialog.dismiss(); } });
        settled(events);
        check(events.canceled.get() == 1 && events.dismissed.get() == 1 && !showing(dialog), "cancel_and_dismiss_idempotent");
        check(events.sequence.equals(Arrays.asList("show", "cancel", "dismiss")), "window_cancel_callback_order_main");
    }

    private static void hideShow(final Context context, Driver driver) throws Exception {
        final String title = "Fixture hide and show";
        final Events events = new Events(); final AlertDialog[] box = new AlertDialog[1];
        onMain(new MainAction() { public void run() {
            box[0] = new AlertDialog.Builder(context).setTitle(title).setMessage("Visibility contract").create();
            events.attach(box[0]); box[0].show();
        } });
        final AlertDialog dialog = box[0]; driver.awaitShown(dialog, title);
        onMain(new MainAction() { public void run() { dialog.hide(); } });
        driver.awaitHidden(dialog, title); settled(events);
        System.out.println("DIALOG_HIDE_OBSERVATION showing="+showing(dialog)+" shown="+events.shown.get()+" dismissed="+events.dismissed.get()+" canceled="+events.canceled.get());
        check(!showing(dialog) && events.shown.get() == 1 && events.dismissed.get() == 0 && events.canceled.get() == 0, "hide_reports_not_showing_without_callbacks");
        onMain(new MainAction() { public void run() { dialog.show(); } });
        driver.awaitShown(dialog, title); settled(events);
        check(events.shown.get() == 1 && events.dismissed.get() == 0, "show_hidden_window_preserves_listener_count");
        onMain(new MainAction() { public void run() { dialog.dismiss(); } });
        await(new Condition() { public boolean holds() { return events.dismissed.get() == 1; } }, "hide show final dismiss");
        driver.awaitHidden(dialog, title); settled(events);
        check(events.sequence.equals(Arrays.asList("show", "dismiss")), "hide_show_callback_order_main");
    }

    private static void customContent(final Context context, Driver driver) throws Exception {
        final String title = "Fixture bitmap and dynamic text";
        final Events events = new Events(); final AlertDialog[] box = new AlertDialog[1];
        final TextView[] text = new TextView[1]; final ImageView[] image = new ImageView[1]; final Button[] button = new Button[1];
        final AtomicInteger clicks = new AtomicInteger();
        final int width = 87, height = 87;
        final int[] firstPixels = qrPixels(false), secondPixels = qrPixels(true);
        onMain(new MainAction() { public void run() {
            LinearLayout layout = new LinearLayout(context); layout.setOrientation(LinearLayout.VERTICAL);
            text[0] = new TextView(context); text[0].setText("QR fixture ready"); layout.addView(text[0]);
            image[0] = new ImageView(context); image[0].setImageBitmap(Bitmap.createBitmap(firstPixels, width, height, Bitmap.Config.ARGB_8888)); layout.addView(image[0]);
            button[0] = new Button(context); button[0].setText("Fixture custom callback");
            button[0].setOnClickListener(new View.OnClickListener() {
                public void onClick(View view) {
                    events.add("custom");
                    if (view != button[0]) events.error.compareAndSet(null, new AssertionError("custom View identity changed"));
                    clicks.incrementAndGet(); text[0].setText("Original callback completed");
                }
            });
            layout.addView(button[0]);
            box[0] = new AlertDialog.Builder(context).setTitle(title).setView(layout).create();
            events.attach(box[0]); box[0].show();
        } });
        final AlertDialog dialog = box[0]; driver.awaitShown(dialog, title);
        driver.awaitContent(dialog, title, "QR fixture ready", firstPixels, width, height);
        check(true, "native_custom_text_and_exact_qr_bitmap_pixels");
        onMain(new MainAction() { public void run() {
            text[0].setText("QR fixture refreshed");
            image[0].setImageBitmap(Bitmap.createBitmap(secondPixels, width, height, Bitmap.Config.ARGB_8888));
        } });
        driver.awaitContent(dialog, title, "QR fixture refreshed", secondPixels, width, height);
        check(true, "native_dynamic_text_and_bitmap_refresh");
        driver.clickText(dialog, title, "Fixture custom callback");
        await(new Condition() { public boolean holds() { return clicks.get() == 1; } }, "custom callback");
        driver.awaitContent(dialog, title, "Original callback completed", secondPixels, width, height); settled(events);
        check(showing(dialog) && events.dismissed.get() == 0 && clicks.get() == 1, "custom_control_preserves_original_view_listener_main");
        onMain(new MainAction() { public void run() { dialog.dismiss(); } });
        await(new Condition() { public boolean holds() { return events.dismissed.get() == 1; } }, "custom dismiss");
        driver.awaitHidden(dialog, title); settled(events);
        check(events.sequence.equals(Arrays.asList("show", "custom", "dismiss")), "custom_content_callback_order_main");
    }

    /** Fixed QR version 1-L, byte payload P4-02, mask 0, four-module quiet zone.
     * The second image changes foreground color so refresh needs exact pixel parity.
     */
    private static int[] qrPixels(boolean refreshed) {
        String[] rows = {
            "111111100101101111111", "100000100111001000001", "101110101101101011101",
            "101110100101001011101", "101110100010101011101", "100000100000101000001",
            "111111101010101111111", "000000001101100000000", "111011111111011000100",
            "010101000110001000001", "000110101010100010101", "100101011000001001010",
            "001111110100101010001", "000000001111010100100", "111111101001011101111",
            "100000101101110111000", "101110101101011101011", "101110100010001101010",
            "101110101100100010101", "100000101100001111010", "111111101000101011011"
        };
        int size = 87; int[] pixels = new int[size * size]; Arrays.fill(pixels, 0xffffffff);
        int dark = refreshed ? 0xff102040 : 0xff000000;
        for (int y = 0; y < 21; y++) for (int x = 0; x < 21; x++) if (rows[y].charAt(x) == '1')
            for (int dy = 0; dy < 3; dy++) for (int dx = 0; dx < 3; dx++) pixels[((y + 4) * 3 + dy) * size + (x + 4) * 3 + dx] = dark;
        return pixels;
    }
}
