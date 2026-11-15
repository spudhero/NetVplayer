package com.netvplayer.provider.android;

import java.awt.*;
import java.awt.event.*;
import java.io.*;
import java.nio.file.*;
import java.util.Properties;
import javax.swing.*;
import javax.swing.border.*;
import javax.swing.plaf.basic.*;
import javax.swing.text.JTextComponent;

/** Presentation tokens supplied by the signed Mac app, never by a Provider. */
public final class DesktopAndroidTheme {
    private static final Font BODY = new Font("Dialog", Font.PLAIN, 13);
    private static Properties tokens = defaults();
    private static String revision = "";
    private static boolean watching;
    private DesktopAndroidTheme() {}

    private static Properties defaults() {
        Properties p = new Properties();
        p.setProperty("background", "080411"); p.setProperty("surface", "2A2241");
        p.setProperty("foreground", "F7F2FF"); p.setProperty("muted", "B8ACCF");
        p.setProperty("accent", "54CFEF"); p.setProperty("onAccent", "080411");
        p.setProperty("secondaryAccent", "A77BFF");
        return p;
    }

    public static Color color(String name) {
        return new Color(Integer.parseInt(tokens.getProperty(name, defaults().getProperty(name)), 16));
    }

    private static boolean reload() {
        String location = System.getProperty("netvplayer.android.themeFile", "");
        if (location.isEmpty()) return false;
        try {
            Path path = Path.of(location);
            if (Files.size(path) > 4096) return false;
            String text = Files.readString(path);
            if (text.equals(revision)) return false;
            Properties next = defaults(); next.load(new StringReader(text));
            for (String key : defaults().stringPropertyNames())
                if (!next.getProperty(key).matches("[0-9a-fA-F]{6}")) return false;
            tokens = next; revision = text;
            return true;
        } catch (IOException | RuntimeException ignored) { return false; }
    }

    public static void start() {
        if (!EventQueue.isDispatchThread()) throw new IllegalStateException("Theme must run on desktop queue");
        reload();
        if (watching) return;
        watching = true;
        new Timer(500, event -> {
            if (reload()) for (Window window : Window.getWindows()) {
                apply(window); window.repaint();
            }
        }).start();
    }

    public static JPanel panel() {
        JPanel panel = new JPanel(); panel.setOpaque(false); return panel;
    }

    /** Measure wrapped text after its column width is known, without squeezing its last line. */
    public static JTextArea text(String text) { return new WrappedText(text); }

    private static final class WrappedText extends JTextArea {
        WrappedText(String text) {
            super(text);
            setEditable(false); setOpaque(false); setLineWrap(true); setWrapStyleWord(true);
            setColumns(36); setAlignmentX(Component.LEFT_ALIGNMENT);
        }
        int heightForWidth(int width) {
            Insets insets = getInsets();
            javax.swing.text.View view = getUI().getRootView(this);
            view.setSize(Math.max(1, width - insets.left - insets.right), Float.MAX_VALUE);
            return (int)Math.ceil(view.getPreferredSpan(javax.swing.text.View.Y_AXIS)) + insets.top + insets.bottom;
        }
    }

    /** A vertical column tracks viewport width and scrolls instead of clipping text horizontally. */
    public static JPanel column() { return new WrappedColumn(); }

    private static final class WrappedColumn extends JPanel implements Scrollable {
        WrappedColumn() {
            setOpaque(false);
            setAlignmentX(Component.LEFT_ALIGNMENT);
            setLayout(new LayoutManager() {
                public void addLayoutComponent(String name, Component c) {}
                public void removeLayoutComponent(Component c) {}
                public Dimension preferredLayoutSize(Container parent) {
                    int width = 0;
                    for (Component child : getComponents()) width = Math.max(width, child.getPreferredSize().width);
                    Insets insets = getInsets();
                    width += insets.left + insets.right;
                    if (getParent() instanceof JViewport viewport && viewport.getExtentSize().width > 0)
                        width = viewport.getExtentSize().width;
                    else if (getWidth() > 0) width = getWidth();
                    return new Dimension(width, heightForWidth(width));
                }
                public Dimension minimumLayoutSize(Container parent) { return new Dimension(0, 0); }
                public void layoutContainer(Container parent) {
                    Insets insets = getInsets();
                    int width = Math.max(1, getWidth() - insets.left - insets.right), y = insets.top;
                    for (Component child : getComponents()) {
                        int childWidth = Math.min(width, child.getMaximumSize().width);
                        int height = childHeight(child, childWidth);
                        child.setBounds(insets.left, y, childWidth, height);
                        y += height;
                    }
                }
            });
        }
        private int childHeight(Component child, int width) {
            if (child instanceof WrappedText text) return text.heightForWidth(width);
            if (child instanceof WrappedColumn column) return column.heightForWidth(width);
            return child.getPreferredSize().height;
        }
        int heightForWidth(int width) {
            Insets insets = getInsets();
            int height = insets.top + insets.bottom;
            for (Component child : getComponents()) height += childHeight(child,
                Math.min(Math.max(1, width - insets.left - insets.right), child.getMaximumSize().width));
            return height;
        }
        public Dimension getPreferredScrollableViewportSize() { return getPreferredSize(); }
        public int getScrollableUnitIncrement(Rectangle r, int orientation, int direction) { return 20; }
        public int getScrollableBlockIncrement(Rectangle r, int orientation, int direction) { return Math.max(20, r.height - 20); }
        public boolean getScrollableTracksViewportWidth() { return true; }
        public boolean getScrollableTracksViewportHeight() { return false; }
    }

    public static JPanel surface(LayoutManager layout) {
        JPanel panel = new JPanel(layout);
        panel.putClientProperty("theme.surface", true);
        return panel;
    }

    public static JTextArea heading(String text) {
        JTextArea label = text(text); label.putClientProperty("theme.heading", true);
        label.setColumns(28);
        label.setFont(BODY.deriveFont(Font.BOLD, 14)); return label;
    }

    public static JButton button(String title, boolean primary) {
        JButton button = new JButton(title);
        button.putClientProperty("html.disable", true);
        if (title.length() > 30) button.setToolTipText(title);
        button.putClientProperty("theme.primary", primary);
        button.setUI(new BasicButtonUI() {
            @Override public void update(Graphics g, JComponent c) {
                AbstractButton b = (AbstractButton)c;
                Graphics2D g2 = (Graphics2D)g.create();
                g2.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
                boolean accent = Boolean.TRUE.equals(b.getClientProperty("theme.primary"));
                Color fill = color(accent ? "accent" : "surface");
                if (!b.isEnabled()) fill = blend(fill, color("background"), .45f);
                else if (b.getModel().isPressed()) fill = blend(fill, color("foreground"), .15f);
                else if (b.getModel().isRollover()) fill = blend(fill, color("foreground"), .08f);
                g2.setColor(fill); g2.fillRoundRect(1, 1, c.getWidth()-2, c.getHeight()-2, 16, 16);
                if (!accent || b.hasFocus()) {
                    g2.setColor(b.hasFocus() ? color("accent") : blend(color("muted"), fill, .75f));
                    g2.drawRoundRect(1, 1, c.getWidth()-3, c.getHeight()-3, 16, 16);
                }
                g2.dispose(); super.paint(g, c);
            }
            @Override protected void paintText(Graphics g, AbstractButton b, Rectangle r, String text) {
                g.setColor(color(!b.isEnabled() ? "muted" : Boolean.TRUE.equals(b.getClientProperty("theme.primary")) ? "onAccent" : "foreground"));
                g.setFont(b.getFont());
                g.drawString(text, r.x, r.y + g.getFontMetrics().getAscent());
            }
        });
        button.setContentAreaFilled(false); button.setBorderPainted(false); button.setOpaque(false);
        button.setRolloverEnabled(true); button.setFocusPainted(false);
        button.setBorder(BorderFactory.createEmptyBorder(10, 16, 10, 16));
        button.setMinimumSize(new Dimension(76, 36));
        return button;
    }

    public static void choice(AbstractButton button, boolean radio) {
        button.putClientProperty("html.disable", true);
        button.setUI(radio ? new BasicRadioButtonUI() : new BasicCheckBoxUI());
        button.setIcon(new Icon() {
            public int getIconWidth() { return 20; }
            public int getIconHeight() { return 20; }
            public void paintIcon(Component c, Graphics g, int x, int y) {
                Graphics2D d = (Graphics2D)g.create();
                d.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
                d.setColor(color(button.isEnabled() && button.isSelected() ? "accent" : "muted"));
                d.setStroke(new BasicStroke(button.hasFocus() ? 2 : 1));
                if (radio) d.drawOval(x+2,y+2,15,15); else d.drawRoundRect(x+2,y+2,15,15,5,5);
                if (button.isSelected()) {
                    if (radio) d.fillOval(x+6,y+6,7,7);
                    else { d.setStroke(new BasicStroke(2)); d.drawLine(x+5,y+9,x+8,y+12); d.drawLine(x+8,y+12,x+14,y+6); }
                }
                d.dispose();
            }
        });
        button.setOpaque(false); button.setBorder(BorderFactory.createEmptyBorder(8, 2, 8, 8));
        button.setAlignmentX(Component.LEFT_ALIGNMENT);
    }

    public static void input(JTextField field) {
        field.setAlignmentX(Component.LEFT_ALIGNMENT);
        field.setUI(new BasicTextFieldUI());
        field.setCaretColor(color("accent"));
        field.setBorder(new CompoundBorder(new AbstractBorder() {
            @Override public Insets getBorderInsets(Component c) { return new Insets(1,1,1,1); }
            @Override public void paintBorder(Component c, Graphics g, int x, int y, int w, int h) {
                g.setColor(color(c.hasFocus() ? "accent" : "muted")); g.drawRoundRect(x,y,w-1,h-1,8,8);
            }
        }, BorderFactory.createEmptyBorder(9,10,9,10)));
        field.addFocusListener(new FocusAdapter() {
            @Override public void focusGained(FocusEvent e) { field.repaint(); }
            @Override public void focusLost(FocusEvent e) { field.repaint(); }
        });
        field.setMaximumSize(new Dimension(Integer.MAX_VALUE, 40));
    }

    public static void apply(Component component) {
        UIManager.put("CheckBox.disabledText", color("muted"));
        UIManager.put("RadioButton.disabledText", color("muted"));
        applyTree(component);
    }

    private static void applyTree(Component component) {
        component.setForeground(color("foreground"));
        if (!(component instanceof JComponent label && Boolean.TRUE.equals(label.getClientProperty("theme.heading"))))
            component.setFont(BODY);
        if (component instanceof JComponent c) {
            if (Boolean.TRUE.equals(c.getClientProperty("theme.muted"))) c.setForeground(color("muted"));
            if (c instanceof JRadioButton radio) radio.setUI(new BasicRadioButtonUI());
            else if (c instanceof JCheckBox check) check.setUI(new BasicCheckBoxUI());
            if (Boolean.TRUE.equals(c.getClientProperty("theme.qr"))) c.setBackground(Color.WHITE);
            else c.setBackground(color(Boolean.TRUE.equals(c.getClientProperty("theme.surface"))
                || c instanceof JScrollPane || c instanceof JViewport ? "surface" : "background"));
            if (c instanceof JTextComponent t) {
                t.setCaretColor(color("accent")); t.setSelectionColor(color("accent"));
                t.setSelectedTextColor(color("onAccent")); t.setDisabledTextColor(color("muted"));
            }
            if (c instanceof JScrollPane scroll) {
                scroll.getViewport().setBackground(color("surface"));
                scroll.getVerticalScrollBar().setUI(new BasicScrollBarUI() {
                    @Override protected void configureScrollBarColors() { thumbColor=color("muted"); trackColor=color("background"); }
                    @Override protected JButton createDecreaseButton(int o) { return invisible(); }
                    @Override protected JButton createIncreaseButton(int o) { return invisible(); }
                    private JButton invisible() { JButton b = new JButton(); b.setPreferredSize(new Dimension(0,0)); return b; }
                });
                scroll.getVerticalScrollBar().setPreferredSize(new Dimension(10,0));
            }
        }
        if (component instanceof Container container) for (Component child : container.getComponents()) applyTree(child);
    }

    private static Color blend(Color a, Color b, float amount) {
        return new Color(Math.round(a.getRed()*(1-amount)+b.getRed()*amount),
            Math.round(a.getGreen()*(1-amount)+b.getGreen()*amount),Math.round(a.getBlue()*(1-amount)+b.getBlue()*amount));
    }
}
