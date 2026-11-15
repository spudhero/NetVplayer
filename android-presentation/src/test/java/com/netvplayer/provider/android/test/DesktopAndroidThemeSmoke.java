package com.netvplayer.provider.android.test;

import android.app.*;
import android.content.Context;
import android.os.Looper;
import android.widget.*;
import com.netvplayer.provider.android.*;
import fixture.AndroidDialogContract;
import java.awt.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.atomic.*;
import javax.swing.*;

/** Offline original-Dialog fixtures; contains no Provider, network or accounts. */
public final class DesktopAndroidThemeSmoke {
    static Activity activity;
    static AlertDialog active;
    static <T> T desktop(java.util.concurrent.Callable<T> action) throws Exception {
        AtomicReference<T> value = new AtomicReference<>(); AtomicReference<Throwable> error = new AtomicReference<>();
        EventQueue.invokeAndWait(() -> { try { value.set(action.call()); } catch(Throwable t) { error.set(t); } });
        if (error.get()!=null) throw new AssertionError(error.get()); return value.get();
    }
    static void check(boolean condition, String name) {
        if (!condition) throw new AssertionError(name); System.out.println("THEME_CASE " + name);
    }
    static void await(java.util.concurrent.Callable<Boolean> condition) throws Exception {
        long end=System.nanoTime()+java.util.concurrent.TimeUnit.SECONDS.toNanos(8);
        while (!condition.call()) { if(System.nanoTime()>end) throw new AssertionError("fixture timeout"); Thread.sleep(30); }
    }
    static java.util.List<Component> components(Container root) {
        java.util.List<Component> result=new ArrayList<>();
        for (Component c:root.getComponents()) { result.add(c); if(c instanceof Container child) result.addAll(components(child)); }
        return result;
    }
    static JDialog dialog() {
        for(Window w:Window.getWindows()) if(w instanceof JDialog d && d.isShowing()) return d; return null;
    }
    static JTextField edit() {
        JDialog d=dialog(); if(d!=null) for(Component c:components(d)) if(c instanceof JTextField t) return t; return null;
    }
    static ImageView image() {
        int size=232; int[] pixels=new int[size*size];
        for(int y=0;y<size;y++) for(int x=0;x<size;x++) pixels[y*size+x]=((x/8+y/8)%3==0)?0xff111111:0xffffffff;
        ImageView image=new ImageView(activity);
        image.setImageBitmap(android.graphics.Bitmap.createBitmap(pixels,size,size,android.graphics.Bitmap.Config.ARGB_8888));
        return image;
    }
    static void show(String kind) throws Exception {
        if(kind.equals("夸克扫码授权")) System.setProperty("netvplayer.android.authorizationDrive","quark");
        else if(kind.equals("百度网盘扫码授权")) System.setProperty("netvplayer.android.authorizationDrive","baidu");
        else System.clearProperty("netvplayer.android.authorizationDrive");
        AndroidDialogContract.onMain(() -> {
            if(active!=null) active.dismiss();
            AlertDialog.Builder b=new AlertDialog.Builder(activity).setTitle(kind.endsWith("扫码授权")?"":kind).setNegativeButton("取消",(d,w)->{});
            switch(kind) {
                case "夸克扫码授权", "百度网盘扫码授权": b.setView(image()); break;
                case "扫码登录": {
                    LinearLayout content=new LinearLayout(activity); content.setOrientation(LinearLayout.VERTICAL);
                    TextView text=new TextView(activity); text.setText("请使用对应应用扫描二维码，完成后将自动继续。\n此为离线验收示例，不会登录账号。"); content.addView(text);
                    content.addView(image());
                    b.setView(content).setPositiveButton("刷新二维码",(d,w)->{}); break;
                }
                case "选择清晰度": b.setSingleChoiceItems(new String[]{"4K · 原画","1080P · 高清","720P · 流畅"},1,(d,w)->{}).setPositiveButton("确定",(d,w)->{}); break;
                case "选择字幕": b.setMultiChoiceItems(new String[]{"简体中文","English","双语字幕"},new boolean[]{true,false,false},(d,w,c)->{}).setPositiveButton("确定",(d,w)->{}); break;
                case "输入信息": { EditText input=new EditText(activity);input.setHint("请输入内容"); b.setMessage("输入后点击继续。内容仅用于此离线示例。").setView(input).setPositiveButton("继续",(d,w)->{});break; }
                case "长列表": { String[] items=new String[80];for(int i=0;i<items.length;i++)items[i]="文件夹 "+(i+1)+" · 示例名称较长时可使用滚动浏览";b.setItems(items,(d,w)->{});break; }
                default: b.setMessage("暂时无法完成操作，请稍后重试。\n你也可以取消并返回上一页。").setPositiveButton("重试",(d,w)->{});
            }
            active=b.create(); active.show();
        });
    }
    static void authorizationDialog() throws Exception {
        System.setProperty("netvplayer.android.authorizationDrive","quark");
        AtomicInteger canceled=new AtomicInteger(), dismissed=new AtomicInteger();
        AndroidDialogContract.onMain(()-> {
            active=new AlertDialog.Builder(activity).setView(image()).create();
            active.setOnCancelListener(d->canceled.incrementAndGet());
            active.setOnDismissListener(d->dismissed.incrementAndGet());
            active.show();
        });
        await(()->desktop(()->dialog()!=null && dialog().getTitle().equals("夸克扫码授权")));
        check(desktop(()->components(dialog()).stream().anyMatch(c->c instanceof JTextArea t
            && t.getText().contains("夸克浏览器 App") && t.getText().contains("自动继续播放"))),"unlabelled_cloud_image_explains_app_action_and_completion");
        check(desktop(()->Arrays.stream(Window.getWindows()).filter(Window::isShowing).count()==1),"authorization_has_one_visible_window");
        check(Boolean.TRUE.equals(DesktopAndroidUI.status().get("visible")),"owned_dialog_preserves_real_activity_visibility");
        check(desktop(()->components(dialog()).stream().anyMatch(c->c instanceof JComponent j
            && "扫码授权二维码".equals(j.getAccessibleContext().getAccessibleName()))),"authorization_image_has_accessible_purpose");
        desktop(()-> {for(Component c:components(dialog())) if(c instanceof JButton b && b.getText().equals("取消")) {b.doClick();break;} return null;});
        await(()->canceled.get()==1 && dismissed.get()==1 && desktop(()->dialog()==null));
        check(canceled.get()==1 && dismissed.get()==1,"authorization_cancel_keeps_original_callbacks_once");
        await(()->desktop(()->Arrays.stream(Frame.getFrames()).anyMatch(Frame::isShowing)));
        check(true,"waiting_host_returns_after_dialog_closes");
        // A known account never overwrites source-provided instructions or invents an app for unknown context.
        AndroidDialogContract.onMain(()-> { active=new AlertDialog.Builder(activity).setTitle("来源说明").setMessage("请按来源提示操作").setView(image()).create();active.show(); });
        await(()->desktop(()->dialog()!=null && dialog().getTitle().equals("来源说明")));
        check(true,"source_authentication_instructions_remain_authoritative");
        AndroidDialogContract.onMain(()->active.dismiss());
        System.clearProperty("netvplayer.android.authorizationDrive");
        AndroidDialogContract.onMain(()-> {active=new AlertDialog.Builder(activity).setView(image()).create();active.show();});
        await(()->desktop(()->dialog()!=null && dialog().getTitle().equals("扫码授权")));
        check(true,"unknown_context_does_not_claim_a_specific_service");
        AndroidDialogContract.onMain(()->active.dismiss());
        System.setProperty("netvplayer.android.authorizationDrive","baidu");
        canceled.set(0); dismissed.set(0);
        AndroidDialogContract.onMain(()-> {
            active=new AlertDialog.Builder(activity).setTitle("NetVplayer").setView(image()).create();
            active.setOnCancelListener(d->canceled.incrementAndGet());
            active.setOnDismissListener(d->dismissed.incrementAndGet());
            active.show();
        });
        await(()->desktop(()->dialog()!=null && dialog().getTitle().equals("百度网盘扫码授权")));
        check(desktop(()->components(dialog()).stream().anyMatch(c->c instanceof JTextArea t
            && t.getText().contains("百度网盘 App") && t.getText().contains("手机上确认登录")
            && t.getText().contains("自动继续播放") && t.getText().contains("取消后重新播放"))),"baidu_image_explains_original_scan_app_and_completion");
        check(desktop(()->Arrays.stream(Window.getWindows()).filter(Window::isShowing).count()==1
            && components(dialog()).stream().anyMatch(c->c instanceof JComponent j
                && "扫码授权二维码".equals(j.getAccessibleContext().getAccessibleName()))),"baidu_authorization_keeps_one_window_and_accessible_qr");
        desktop(()-> {for(Component c:components(dialog())) if(c instanceof JButton b && b.getText().equals("取消")) {b.doClick();break;} return null;});
        await(()->canceled.get()==1 && dismissed.get()==1 && desktop(()->dialog()==null));
        check(canceled.get()==1 && dismissed.get()==1,"baidu_authorization_cancel_keeps_original_callbacks_once");
        AndroidDialogContract.onMain(()-> {active=new AlertDialog.Builder(activity).setMessage("请按来源提示操作").setView(image()).create();active.show();});
        await(()->desktop(()->dialog()!=null && dialog().getTitle().equals("NetVplayer")));
        check(desktop(()->components(dialog()).stream().anyMatch(c->c instanceof JTextArea t
            && t.getText().equals("请按来源提示操作"))
            && components(dialog()).stream().noneMatch(c->c instanceof JTextArea t
                && t.getText().contains("百度网盘 App"))),"baidu_source_instructions_remain_authoritative");
        AndroidDialogContract.onMain(()->active.dismiss());
        System.clearProperty("netvplayer.android.authorizationDrive");
        Path state = java.nio.file.Files.createTempDirectory("netvplayer-display-drive-");
        Path display = state.resolve(".runtime/authorization-drive");
        java.nio.file.Files.createDirectories(display.getParent());
        System.setProperty("netvplayer.android.persistentDataDir", state.toString());
        for (String drive : new String[] {"quark", "baidu", "uc", "ali"}) {
            java.nio.file.Files.writeString(display, drive);
            AndroidDialogContract.onMain(()-> {active=new AlertDialog.Builder(activity).setView(image()).create();active.show();});
            String expected = switch (drive) {
                case "quark" -> "夸克扫码授权";
                case "baidu" -> "百度网盘扫码授权";
                case "uc" -> "UC扫码授权";
                default -> "阿里云盘扫码授权";
            };
            await(()->desktop(()->dialog()!=null && dialog().getTitle().equals(expected)));
            check(true,"retained_helper_updates_display_drive_" + drive);
            AndroidDialogContract.onMain(()->active.dismiss());
        }
        System.clearProperty("netvplayer.android.persistentDataDir");
        java.nio.file.Files.delete(display);
        java.nio.file.Files.delete(display.getParent());
        java.nio.file.Files.delete(state);
    }
    static void gallery() throws Exception {
        desktop(() -> {
            JFrame control=new JFrame("NetVplayer · 离线弹窗验收");control.setDefaultCloseOperation(JFrame.EXIT_ON_CLOSE);
            JPanel p=DesktopAndroidTheme.surface(new FlowLayout());
            for(String name:new String[]{"夸克扫码授权","百度网盘扫码授权","扫码登录","选择清晰度","选择字幕","输入信息","长列表","操作失败"}) {
                JButton b=DesktopAndroidTheme.button(name,false);b.addActionListener(e->{try{show(name);}catch(Exception x){throw new RuntimeException(x);}});p.add(b);
            }
            control.setContentPane(p);DesktopAndroidTheme.apply(p);control.pack();control.setLocation(80,80);control.setVisible(true);return null;
        });
        show("扫码登录"); System.out.println("THEME_GALLERY_READY");
    }
    static void export(Path output) throws Exception {
        Files.createDirectories(output);
        Path theme=Path.of(System.getProperty("netvplayer.android.themeFile"));
        for(String mode:new String[]{"dark","light"}) {
            Files.writeString(theme,mode.equals("dark")
                ? "background=080411\nsurface=2A2241\nforeground=F7F2FF\nmuted=B8ACCF\naccent=54CFEF\nonAccent=080411\nsecondaryAccent=A77BFF\n"
                : "background=F8FBEF\nsurface=FFFDF8\nforeground=3F342B\nmuted=6B5D52\naccent=876047\nonAccent=F8FBEF\nsecondaryAccent=8D4F66\n");
            Thread.sleep(600);
            int index=0;
            for(String kind:new String[]{"夸克扫码授权","百度网盘扫码授权","扫码登录","选择清晰度","选择字幕","输入信息","长列表","操作失败"}) {
                show(kind); await(()->desktop(()->dialog()!=null && dialog().getTitle().equals(kind)));
                Path target=output.resolve(mode+"-"+(++index)+".png");
                desktop(()->{
                    Container content=dialog().getContentPane();
                    java.awt.image.BufferedImage image=new java.awt.image.BufferedImage(content.getWidth(),content.getHeight(),java.awt.image.BufferedImage.TYPE_INT_RGB);
                    Graphics2D graphics=image.createGraphics();content.printAll(graphics);graphics.dispose();
                    javax.imageio.ImageIO.write(image,"png",target.toFile());return null;
                });
            }
        }
        DesktopAndroidUI.close();System.out.println("THEME_EXPORT_OK");System.exit(0);
    }
    public static void main(String[] args) {
        try {
            NativeExecution.initialize(); Context context=ExperimentContext.create();
            DesktopAndroidUI.begin(context);
            AndroidDialogContract.onMain(()-> { for(DesktopAndroidUI.ActivityRecord r:DesktopAndroidUI.activityRecords().values()) activity=r.activity; });
            if(args.length>0 && args[0].equals("gallery")) {gallery();return;}
            if(args.length>1 && args[0].equals("export")) {export(Path.of(args[1]));return;}
            Path theme=Path.of(System.getProperty("netvplayer.android.themeFile"));
            Files.writeString(theme,"background=211A32\nsurface=30263F\nforeground=EFF2F6\nmuted=C1BACD\naccent=65D4ED\nonAccent=10202A\nsecondaryAccent=9B7CD6\n");
            show("输入信息");await(()->desktop(()->edit()!=null));
            JTextField field=desktop(()->edit());
            check(desktop(()->field.getX()>=0 && field.getX()+field.getWidth()<=field.getParent().getWidth()),"input_stays_inside_visible_content_width");
            desktop(()-> {field.requestFocusInWindow();field.setText("离线输入测试");field.setCaretPosition(3);return null;});
            await(()->desktop(()->field.hasFocus()));
            Thread.sleep(650);
            check(desktop(()->edit()==field && field.getCaretPosition()==3 && field.hasFocus()),"refresh_preserves_input_identity_caret_focus");
            Files.writeString(theme,"background=F4F7F1\nsurface=FFFFFF\nforeground=172525\nmuted=526565\naccent=376D6B\nonAccent=FFFFFF\nsecondaryAccent=C08085\n");
            await(()->desktop(()->field.getBackground().equals(new Color(0xF4F7F1))));
            check(desktop(()->edit()==field && field.hasFocus() && field.getText().equals("离线输入测试")),"live_theme_change_preserves_unsubmitted_input");
            Files.writeString(theme,"background=invalid\n");Thread.sleep(650);
            check(desktop(()->field.getBackground().equals(new Color(0xF4F7F1))),"malformed_theme_keeps_last_valid_palette");
            AndroidDialogContract.onMain(()->active.dismiss());
            AtomicInteger callbacks=new AtomicInteger();AtomicReference<String> submitted=new AtomicReference<>();AtomicReference<Throwable> error=new AtomicReference<>();
            AndroidDialogContract.onMain(()-> {
                EditText original=new EditText(activity); original.setInputType(0x81); original.setHint("密码");
                active=new AlertDialog.Builder(activity).setTitle("离线密码输入").setView(original).setPositiveButton("继续",(d,w)->{
                    if(Looper.myLooper()!=Looper.getMainLooper())error.set(new AssertionError("wrong callback queue"));
                    submitted.set(original.getText().toString());callbacks.incrementAndGet();
                }).create(); active.show();
            });
            await(()->desktop(()->edit() instanceof JPasswordField));
            check(true,"password_variation_uses_masked_control");
            desktop(()->{edit().setText("synthetic-only");dialog().getRootPane().getDefaultButton().doClick();return null;});
            await(()->callbacks.get()==1);
            check("synthetic-only".equals(submitted.get()) && error.get()==null,"input_commits_before_original_action_once_on_android_main");
            check(DesktopAndroidUI.class.getProtectionDomain().getCodeSource().getLocation().toString().contains("android-presentation.jar"),"app_owned_renderer_precedes_component");
            authorizationDialog();
            DesktopAndroidUI.close(); System.out.println("THEME_CONTRACT_OK");System.exit(0);
        } catch(Throwable error) {error.printStackTrace();System.exit(1);}
    }
}
