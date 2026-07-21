#requires -version 5.1

param(
    [switch]$SelfTest,
    [switch]$Minimized,
    [string]$UiPreviewPath,
    [int]$UiPreviewWidth,
    [int]$UiPreviewHeight,
    [string]$HotkeyPreviewPath,
    [string]$TrayMenuPreviewPath,
    [switch]$TrayMenuPreviewDark
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$nativeCode = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace AudioSwitchNative
{
    public enum DataFlow { Render = 0, Capture = 1, All = 2 }
    public enum Role { Console = 0, Multimedia = 1, Communications = 2 }

    [StructLayout(LayoutKind.Sequential)]
    public struct PropertyKey
    {
        public Guid FormatId;
        public int PropertyId;
        public PropertyKey(Guid formatId, int propertyId) { FormatId = formatId; PropertyId = propertyId; }
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct PropVariant
    {
        [FieldOffset(0)] public ushort VarType;
        [FieldOffset(8)] public IntPtr PointerValue;
        public string GetString() { return VarType == 31 && PointerValue != IntPtr.Zero ? Marshal.PtrToStringUni(PointerValue) : null; }
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore
    {
        [PreserveSig]
        int GetCount(out int count);
        [PreserveSig]
        int GetAt(int index, out PropertyKey key);
        [PreserveSig]
        int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig]
        int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig]
        int Commit();
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        [PreserveSig]
        int Activate(ref Guid iid, int context, IntPtr activationParams, out IntPtr instance);
        [PreserveSig]
        int OpenPropertyStore(int access, out IPropertyStore properties);
        [PreserveSig]
        int GetId(out IntPtr id);
        [PreserveSig]
        int GetState(out int state);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection
    {
        [PreserveSig]
        int GetCount(out int count);
        [PreserveSig]
        int Item(int index, out IMMDevice device);
    }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        [PreserveSig]
        int EnumAudioEndpoints(DataFlow flow, int stateMask, out IMMDeviceCollection devices);
        [PreserveSig]
        int GetDefaultAudioEndpoint(DataFlow flow, Role role, out IMMDevice endpoint);
        [PreserveSig]
        int GetDevice(string id, out IMMDevice device);
        [PreserveSig]
        int RegisterEndpointNotificationCallback(IntPtr client);
        [PreserveSig]
        int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorComObject { }

    [ComImport, Guid("F8679F50-850A-41CF-9C72-430F290290C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPolicyConfig
    {
        [PreserveSig]
        int GetMixFormat(string deviceId, IntPtr format);
        [PreserveSig]
        int GetDeviceFormat(string deviceId, int defaultFormat, IntPtr format);
        [PreserveSig]
        int ResetDeviceFormat(string deviceId);
        [PreserveSig]
        int SetDeviceFormat(string deviceId, IntPtr endpointFormat, IntPtr mixFormat);
        [PreserveSig]
        int GetProcessingPeriod(string deviceId, int defaultPeriod, IntPtr period, IntPtr minimumPeriod);
        [PreserveSig]
        int SetProcessingPeriod(string deviceId, IntPtr period);
        [PreserveSig]
        int GetShareMode(string deviceId, IntPtr mode);
        [PreserveSig]
        int SetShareMode(string deviceId, IntPtr mode);
        [PreserveSig]
        int GetPropertyValue(string deviceId, ref PropertyKey key, out PropVariant value);
        [PreserveSig]
        int SetPropertyValue(string deviceId, ref PropertyKey key, ref PropVariant value);
        [PreserveSig]
        int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string deviceId, Role role);
        [PreserveSig]
        int SetEndpointVisibility(string deviceId, int visible);
    }

    [ComImport, Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9")]
    class PolicyConfigComObject { }

    public sealed class AudioEndpoint
    {
        public string Id { get; set; }
        public string Name { get; set; }
        public bool IsDefault { get; set; }
        public override string ToString() { return Name + (IsDefault ? "  ✓ 当前默认" : ""); }
    }

    public static class AudioManager
    {
        const int DeviceStateActive = 1;
        static readonly PropertyKey FriendlyName = new PropertyKey(new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0"), 14);

        static string ReadId(IMMDevice device)
        {
            IntPtr pointer;
            Marshal.ThrowExceptionForHR(device.GetId(out pointer));
            try { return Marshal.PtrToStringUni(pointer); }
            finally { if (pointer != IntPtr.Zero) Marshal.FreeCoTaskMem(pointer); }
        }

        public static string GetDefaultId(DataFlow flow)
        {
            IMMDeviceEnumerator enumerator = null;
            IMMDevice device = null;
            try
            {
                enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
                Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(flow, Role.Console, out device));
                return ReadId(device);
            }
            finally
            {
                if (device != null) Marshal.ReleaseComObject(device);
                if (enumerator != null) Marshal.ReleaseComObject(enumerator);
            }
        }

        public static List<AudioEndpoint> GetEndpoints(DataFlow flow)
        {
            var result = new List<AudioEndpoint>();
            IMMDeviceEnumerator enumerator = null;
            IMMDeviceCollection collection = null;
            IMMDevice defaultDevice = null;
            string defaultId = null;
            try
            {
                enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
                if (enumerator.GetDefaultAudioEndpoint(flow, Role.Console, out defaultDevice) == 0 && defaultDevice != null)
                    defaultId = ReadId(defaultDevice);

                Marshal.ThrowExceptionForHR(enumerator.EnumAudioEndpoints(flow, DeviceStateActive, out collection));
                int count;
                Marshal.ThrowExceptionForHR(collection.GetCount(out count));
                for (int i = 0; i < count; i++)
                {
                    IMMDevice device = null;
                    IPropertyStore store = null;
                    try
                    {
                        Marshal.ThrowExceptionForHR(collection.Item(i, out device));
                        string id = ReadId(device);
                        Marshal.ThrowExceptionForHR(device.OpenPropertyStore(0, out store));
                        PropVariant value;
                        var key = FriendlyName;
                        Marshal.ThrowExceptionForHR(store.GetValue(ref key, out value));
                        result.Add(new AudioEndpoint { Id = id, Name = value.GetString() ?? id, IsDefault = String.Equals(id, defaultId, StringComparison.OrdinalIgnoreCase) });
                    }
                    finally
                    {
                        if (store != null) Marshal.ReleaseComObject(store);
                        if (device != null) Marshal.ReleaseComObject(device);
                    }
                }
            }
            finally
            {
                if (defaultDevice != null) Marshal.ReleaseComObject(defaultDevice);
                if (collection != null) Marshal.ReleaseComObject(collection);
                if (enumerator != null) Marshal.ReleaseComObject(enumerator);
            }
            result.Sort((a, b) => String.Compare(a.Name, b.Name, StringComparison.CurrentCultureIgnoreCase));
            return result;
        }

        public static void SetDefault(string deviceId)
        {
            IPolicyConfig policy = null;
            try
            {
                policy = (IPolicyConfig)new PolicyConfigComObject();
                Marshal.ThrowExceptionForHR(policy.SetDefaultEndpoint(deviceId, Role.Console));
                Marshal.ThrowExceptionForHR(policy.SetDefaultEndpoint(deviceId, Role.Multimedia));
                Marshal.ThrowExceptionForHR(policy.SetDefaultEndpoint(deviceId, Role.Communications));
            }
            finally
            {
                if (policy != null) Marshal.ReleaseComObject(policy);
            }
        }
    }

    public sealed class ModernMenuColorTable : ProfessionalColorTable
    {
        readonly bool light;
        public ModernMenuColorTable(bool lightMode) { light = lightMode; UseSystemColors = false; }
        Color Background { get { return light ? Color.FromArgb(248, 250, 252) : Color.FromArgb(25, 32, 41); } }
        Color Selected { get { return light ? Color.FromArgb(232, 237, 242) : Color.FromArgb(46, 57, 69); } }
        Color Border { get { return light ? Color.FromArgb(203, 211, 221) : Color.FromArgb(76, 91, 106); } }
        public override Color ToolStripDropDownBackground { get { return Background; } }
        public override Color ImageMarginGradientBegin { get { return Background; } }
        public override Color ImageMarginGradientMiddle { get { return Background; } }
        public override Color ImageMarginGradientEnd { get { return Background; } }
        public override Color MenuBorder { get { return Border; } }
        public override Color MenuItemBorder { get { return Selected; } }
        public override Color MenuItemSelected { get { return Selected; } }
        public override Color MenuItemSelectedGradientBegin { get { return Selected; } }
        public override Color MenuItemSelectedGradientEnd { get { return Selected; } }
        public override Color MenuItemPressedGradientBegin { get { return Selected; } }
        public override Color MenuItemPressedGradientMiddle { get { return Selected; } }
        public override Color MenuItemPressedGradientEnd { get { return Selected; } }
        public override Color SeparatorDark { get { return Border; } }
        public override Color SeparatorLight { get { return Background; } }
    }

    public sealed class ModernMenuRenderer : ToolStripProfessionalRenderer
    {
        readonly bool light;
        readonly Color accent = Color.FromArgb(104, 231, 179);
        public ModernMenuRenderer(bool lightMode) : base(new ModernMenuColorTable(lightMode))
        {
            light = lightMode;
            RoundedEdges = false;
        }

        protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e)
        {
            var top = light ? Color.FromArgb(253, 254, 255) : Color.FromArgb(39, 48, 58);
            var bottom = light ? Color.FromArgb(242, 246, 249) : Color.FromArgb(21, 28, 37);
            using (var gradient = new LinearGradientBrush(e.AffectedBounds, top, bottom, LinearGradientMode.Vertical))
                e.Graphics.FillRectangle(gradient, e.AffectedBounds);
        }

        protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
        {
            if (!e.Item.Selected || !e.Item.Enabled) return;
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var rect = new Rectangle(5, 2, Math.Max(1, e.Item.Width - 10), Math.Max(1, e.Item.Height - 4));
            using (var path = ModernTextBox.RoundedRect(rect, 8))
            using (var fill = new SolidBrush(light ? Color.FromArgb(229, 235, 241) : Color.FromArgb(50, 62, 74)))
            using (var border = new Pen(light ? Color.FromArgb(207, 217, 227) : Color.FromArgb(91, 108, 124)))
            {
                e.Graphics.FillPath(fill, path);
                e.Graphics.DrawPath(border, path);
            }
        }

        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
        {
            // WinForms positions menu glyphs by the font baseline, which makes
            // Chinese text look slightly top-heavy. Draw against the full item
            // height so both the label and shortcut are optically centered.
            var rect = e.TextRectangle;
            rect.Y = 1;
            rect.Height = Math.Max(1, e.Item.Height - 2);
            var flags = (e.TextFormat & ~TextFormatFlags.Bottom) |
                        TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine |
                        TextFormatFlags.NoPadding;
            TextRenderer.DrawText(e.Graphics, e.Text, e.TextFont, rect, e.TextColor, flags);
        }

        protected override void OnRenderImageMargin(ToolStripRenderEventArgs e)
        {
            // Keep the check area on the same acrylic gradient as the menu body.
        }

        protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var rect = new Rectangle(1, 1, Math.Max(1, e.ToolStrip.Width - 3), Math.Max(1, e.ToolStrip.Height - 3));
            using (var path = ModernTextBox.RoundedRect(rect, 13))
            using (var pen = new Pen(light ? Color.FromArgb(197, 207, 218) : Color.FromArgb(82, 98, 114)))
                e.Graphics.DrawPath(pen, path);
        }

        protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e)
        {
            var y = e.Item.Height / 2;
            using (var pen = new Pen(light ? Color.FromArgb(210, 218, 227) : Color.FromArgb(65, 79, 94)))
                e.Graphics.DrawLine(pen, 18, y, e.Item.Width - 18, y);
        }

        protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e)
        {
            const int size = 7;
            var x = e.ImageRectangle.Left + (e.ImageRectangle.Width - size) / 2;
            var y = e.ImageRectangle.Top + (e.ImageRectangle.Height - size) / 2;
            using (var brush = new SolidBrush(accent))
                e.Graphics.FillEllipse(brush, x, y, size, size);
        }
    }

    public sealed class AcrylicPanel : Panel
    {
        public int CornerRadius { get; set; }
        public Color FillColor { get; set; }
        public Color BorderColor { get; set; }

        public AcrylicPanel()
        {
            CornerRadius = 14;
            FillColor = Color.FromArgb(165, 43, 54, 65);
            BorderColor = Color.FromArgb(90, 89, 105, 121);
            BackColor = Color.Transparent;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor |
                     ControlStyles.ResizeRedraw, true);
        }

        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            Invalidate(true);
            if (Parent != null) Parent.Invalidate(Bounds, true);
        }

        static GraphicsPath RoundedPath(Rectangle bounds, int radius)
        {
            var path = new GraphicsPath();
            var diameter = Math.Max(2, radius * 2);
            var arc = new Rectangle(bounds.X, bounds.Y, diameter, diameter);
            path.AddArc(arc, 180, 90);
            arc.X = bounds.Right - diameter;
            path.AddArc(arc, 270, 90);
            arc.Y = bounds.Bottom - diameter;
            path.AddArc(arc, 0, 90);
            arc.X = bounds.Left;
            path.AddArc(arc, 90, 90);
            path.CloseFigure();
            return path;
        }

        protected override void OnPaintBackground(PaintEventArgs e)
        {
            base.OnPaintBackground(e);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var bounds = new Rectangle(1, 1, Math.Max(1, Width - 3), Math.Max(1, Height - 3));
            using (var path = RoundedPath(bounds, CornerRadius))
            using (var brush = new SolidBrush(FillColor))
            using (var pen = new Pen(BorderColor))
            {
                e.Graphics.FillPath(brush, path);
                e.Graphics.DrawPath(pen, path);
            }
        }
    }

    public sealed class ModernTextBox : UserControl
    {
        readonly TextBox editor = new TextBox();
        public Color FieldColor { get; set; }
        public Color BorderColor { get; set; }
        public Color ActiveBorderColor { get; set; }

        public override string Text
        {
            get { return editor.Text; }
            set { editor.Text = value ?? String.Empty; }
        }

        public ModernTextBox()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
            FieldColor = Color.FromArgb(27, 35, 44);
            BorderColor = Color.FromArgb(70, 85, 101);
            ActiveBorderColor = Color.FromArgb(104, 231, 179);
            editor.BorderStyle = BorderStyle.None;
            editor.BackColor = FieldColor;
            editor.ForeColor = Color.FromArgb(244, 247, 251);
            editor.Location = new Point(10, 7);
            editor.TextChanged += delegate { base.Text = editor.Text; };
            editor.GotFocus += delegate { Invalidate(); };
            editor.LostFocus += delegate { Invalidate(); };
            Controls.Add(editor);
            Height = 31;
            Cursor = Cursors.IBeam;
        }

        public void Clear() { editor.Clear(); }

        protected override void OnFontChanged(EventArgs e)
        {
            base.OnFontChanged(e);
            editor.Font = Font;
            LayoutEditor();
        }

        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            LayoutEditor();
            Invalidate();
        }

        void LayoutEditor()
        {
            editor.Location = new Point(10, Math.Max(5, (Height - editor.PreferredHeight) / 2));
            editor.Width = Math.Max(1, Width - 20);
            editor.BackColor = FieldColor;
            editor.ForeColor = ForeColor;
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            editor.Focus();
        }

        protected override void OnPaintBackground(PaintEventArgs e)
        {
            base.OnPaintBackground(e);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var rect = new Rectangle(1, 1, Width - 3, Height - 3);
            using (var path = RoundedRect(rect, 7))
            using (var fill = new SolidBrush(FieldColor))
            using (var border = new Pen(editor.Focused ? ActiveBorderColor : BorderColor))
            {
                e.Graphics.FillPath(fill, path);
                e.Graphics.DrawPath(border, path);
            }
        }

        internal static GraphicsPath RoundedRect(Rectangle bounds, int radius)
        {
            var path = new GraphicsPath();
            int diameter = Math.Max(2, radius * 2);
            var arc = new Rectangle(bounds.X, bounds.Y, diameter, diameter);
            path.AddArc(arc, 180, 90);
            arc.X = bounds.Right - diameter; path.AddArc(arc, 270, 90);
            arc.Y = bounds.Bottom - diameter; path.AddArc(arc, 0, 90);
            arc.X = bounds.Left; path.AddArc(arc, 90, 90);
            path.CloseFigure();
            return path;
        }
    }

    public sealed class ModernComboBox : Control
    {
        readonly ArrayList items = new ArrayList();
        int selectedIndex = -1;
        ContextMenuStrip menu;
        public IList Items { get { return items; } }
        public Color FieldColor { get; set; }
        public Color BorderColor { get; set; }
        public Color ActiveBorderColor { get; set; }
        public event EventHandler SelectedIndexChanged;

        public int SelectedIndex
        {
            get { return selectedIndex; }
            set
            {
                int next = value < -1 ? -1 : (value >= items.Count ? items.Count - 1 : value);
                if (selectedIndex == next) return;
                selectedIndex = next;
                Invalidate();
                if (SelectedIndexChanged != null) SelectedIndexChanged(this, EventArgs.Empty);
            }
        }

        public object SelectedItem
        {
            get { return selectedIndex >= 0 && selectedIndex < items.Count ? items[selectedIndex] : null; }
        }

        public ModernComboBox()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor |
                     ControlStyles.Selectable, true);
            BackColor = Color.Transparent;
            FieldColor = Color.FromArgb(27, 35, 44);
            BorderColor = Color.FromArgb(70, 85, 101);
            ActiveBorderColor = Color.FromArgb(104, 231, 179);
            ForeColor = Color.FromArgb(244, 247, 251);
            Height = 31;
            Cursor = Cursors.Hand;
            TabStop = true;
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            Focus();
            ShowMenu();
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Enter || e.KeyCode == Keys.Space) { ShowMenu(); e.Handled = true; }
            else if (e.KeyCode == Keys.Down && selectedIndex < items.Count - 1) { SelectedIndex++; e.Handled = true; }
            else if (e.KeyCode == Keys.Up && selectedIndex > 0) { SelectedIndex--; e.Handled = true; }
            base.OnKeyDown(e);
        }

        void ShowMenu()
        {
            if (items.Count == 0) return;
            if (menu != null) { menu.Dispose(); menu = null; }
            menu = new ContextMenuStrip();
            menu.Renderer = new ModernMenuRenderer(false);
            menu.ShowImageMargin = false;
            menu.ShowCheckMargin = false;
            menu.BackColor = Color.FromArgb(25, 32, 41);
            menu.ForeColor = Color.FromArgb(239, 241, 245);
            menu.Font = Font;
            menu.Padding = new Padding(5);
            menu.MinimumSize = new Size(Width, 0);
            menu.Opacity = 0.985;
            for (int i = 0; i < items.Count; i++)
            {
                int index = i;
                var item = new ToolStripMenuItem(items[i] == null ? String.Empty : items[i].ToString());
                item.ForeColor = Color.FromArgb(239, 241, 245);
                item.Padding = new Padding(10, 6, 10, 6);
                if (i == selectedIndex) item.Font = new Font(Font, FontStyle.Bold);
                item.Click += delegate { SelectedIndex = index; };
                menu.Items.Add(item);
            }
            menu.Show(this, new Point(0, Height + 3));
        }

        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
        protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var rect = new Rectangle(1, 1, Width - 3, Height - 3);
            using (var path = ModernTextBox.RoundedRect(rect, 7))
            using (var fill = new SolidBrush(FieldColor))
            using (var border = new Pen(Focused ? ActiveBorderColor : BorderColor))
            {
                e.Graphics.FillPath(fill, path);
                e.Graphics.DrawPath(border, path);
            }

            string text = SelectedItem == null ? String.Empty : SelectedItem.ToString();
            var textRect = new Rectangle(10, 1, Math.Max(1, Width - 38), Height - 2);
            TextRenderer.DrawText(e.Graphics, text, Font, textRect, ForeColor,
                TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine);

            int cx = Width - 17, cy = Height / 2;
            using (var pen = new Pen(Color.FromArgb(174, 187, 204), 1.6f))
            {
                pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round;
                e.Graphics.DrawLine(pen, cx - 4, cy - 2, cx, cy + 2);
                e.Graphics.DrawLine(pen, cx, cy + 2, cx + 4, cy - 2);
            }
        }
    }

    public sealed class ModernCheckBox : CheckBox
    {
        public ModernCheckBox()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
            ForeColor = Color.FromArgb(190, 201, 216);
            Cursor = Cursors.Hand;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaintBackground(e);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var box = new Rectangle(1, Math.Max(1, (Height - 15) / 2), 15, 15);
            using (var path = ModernTextBox.RoundedRect(box, 4))
            using (var fill = new SolidBrush(Checked ? Color.FromArgb(104, 231, 179) : Color.FromArgb(27, 35, 44)))
            using (var border = new Pen(Checked ? Color.FromArgb(104, 231, 179) : Color.FromArgb(82, 98, 114)))
            {
                e.Graphics.FillPath(fill, path);
                e.Graphics.DrawPath(border, path);
            }
            if (Checked)
            {
                using (var pen = new Pen(Color.FromArgb(7, 31, 19), 2.2f))
                {
                    pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round;
                    e.Graphics.DrawLines(pen, new[] { new Point(4, box.Top + 8), new Point(7, box.Top + 11), new Point(13, box.Top + 4) });
                }
            }
            var textRect = new Rectangle(23, 0, Math.Max(1, Width - 23), Height);
            TextRenderer.DrawText(e.Graphics, Text, Font, textRect, ForeColor,
                TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
        }
    }

    public sealed class ModernButton : Button
    {
        bool hovered;
        bool pressed;
        public Color FillColor { get; set; }
        public Color HoverFillColor { get; set; }
        public Color PressedFillColor { get; set; }
        public Color BorderColor { get; set; }
        public int BorderWidth { get; set; }
        public int CornerRadius { get; set; }
        public bool DrawCloseGlyph { get; set; }
        public Color GlyphColor { get; set; }

        public ModernButton()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor |
                     ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
            BackColor = Color.Transparent;
            FillColor = Color.FromArgb(37, 47, 57);
            HoverFillColor = Color.FromArgb(48, 59, 70);
            PressedFillColor = Color.FromArgb(27, 35, 44);
            BorderColor = Color.FromArgb(70, 85, 101);
            BorderWidth = 1;
            CornerRadius = 9;
            DrawCloseGlyph = false;
            GlyphColor = Color.White;
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            UseVisualStyleBackColor = false;
            Cursor = Cursors.Hand;
        }

        protected override void OnMouseEnter(EventArgs e) { hovered = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hovered = false; pressed = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) pressed = true; Invalidate(); base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { pressed = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaintBackground(e);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var rect = new Rectangle(1, 1, Math.Max(1, Width - 3), Math.Max(1, Height - 3));
            var fillColor = pressed ? PressedFillColor : (hovered ? HoverFillColor : FillColor);
            if (!Enabled) fillColor = Color.FromArgb(120, fillColor);
            using (var path = ModernTextBox.RoundedRect(rect, CornerRadius))
            using (var fill = new SolidBrush(fillColor))
            {
                e.Graphics.FillPath(fill, path);
                if (BorderWidth > 0 && BorderColor.A > 0)
                {
                    using (var border = new Pen(BorderColor, BorderWidth))
                        e.Graphics.DrawPath(border, path);
                }
            }
            if (DrawCloseGlyph)
            {
                var glyphColor = Enabled ? GlyphColor : Color.FromArgb(120, GlyphColor);
                float centerX = ClientRectangle.Left + ClientRectangle.Width / 2f;
                float centerY = ClientRectangle.Top + ClientRectangle.Height / 2f;
                using (var pen = new Pen(glyphColor, 1.8f))
                {
                    pen.StartCap = LineCap.Round;
                    pen.EndCap = LineCap.Round;
                    e.Graphics.DrawLine(pen, centerX - 3.2f, centerY - 3.2f, centerX + 3.2f, centerY + 3.2f);
                    e.Graphics.DrawLine(pen, centerX + 3.2f, centerY - 3.2f, centerX - 3.2f, centerY + 3.2f);
                }
            }
            else
            {
                var textColor = Enabled ? ForeColor : Color.FromArgb(120, ForeColor);
                TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, textColor,
                    TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter |
                    TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding);
            }
        }
    }

    public sealed class ModernVScrollBar : Control
    {
        int maximum;
        int currentValue;
        bool dragging;
        int dragOffset;
        public int LargeChange { get; set; }
        public event EventHandler ValueChanged;

        public int Maximum
        {
            get { return maximum; }
            set { maximum = Math.Max(0, value); Value = currentValue; Invalidate(); }
        }
        public int Value
        {
            get { return currentValue; }
            set
            {
                int next = Math.Max(0, Math.Min(maximum, value));
                if (next == currentValue) return;
                currentValue = next;
                Invalidate();
                if (ValueChanged != null) ValueChanged(this, EventArgs.Empty);
            }
        }

        public ModernVScrollBar()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
            LargeChange = 180;
            Width = 12;
            Cursor = Cursors.Hand;
        }

        Rectangle Thumb()
        {
            int usable = Math.Max(1, Height - 8);
            int thumbHeight = maximum == 0 ? usable : Math.Max(30, (int)(usable * (LargeChange / (double)(maximum + LargeChange))));
            int travel = Math.Max(0, usable - thumbHeight);
            int y = 4 + (maximum == 0 ? 0 : (int)(travel * (currentValue / (double)maximum)));
            return new Rectangle(2, y, Math.Max(6, Width - 4), thumbHeight);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaintBackground(e);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (var track = new SolidBrush(Color.FromArgb(55, 72, 91, 116)))
                e.Graphics.FillRectangle(track, Width / 2 - 1, 4, 2, Height - 8);
            var thumb = Thumb();
            using (var path = ModernTextBox.RoundedRect(thumb, Math.Max(3, thumb.Width / 2)))
            using (var brush = new SolidBrush(Color.FromArgb(120, 144, 166)))
                e.Graphics.FillPath(brush, path);
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            var thumb = Thumb();
            if (thumb.Contains(e.Location)) { dragging = true; dragOffset = e.Y - thumb.Y; }
            else Value += e.Y < thumb.Y ? -LargeChange : LargeChange;
            Capture = true;
            base.OnMouseDown(e);
        }
        protected override void OnMouseMove(MouseEventArgs e)
        {
            if (dragging && maximum > 0)
            {
                var thumb = Thumb();
                int travel = Math.Max(1, Height - 8 - thumb.Height);
                Value = (int)Math.Round(Math.Max(0, Math.Min(travel, e.Y - 4 - dragOffset)) * maximum / (double)travel);
            }
            base.OnMouseMove(e);
        }
        protected override void OnMouseUp(MouseEventArgs e) { dragging = false; Capture = false; base.OnMouseUp(e); }
        protected override void OnMouseWheel(MouseEventArgs e) { Value -= Math.Sign(e.Delta) * 48; base.OnMouseWheel(e); }
    }

    public sealed class HotkeyPressedEventArgs : EventArgs
    {
        public string ProfileName { get; private set; }
        public HotkeyPressedEventArgs(string profileName) { ProfileName = profileName; }
    }

    public sealed class GlobalHotkeyManager : NativeWindow, IDisposable
    {
        const int WM_HOTKEY = 0x0312;
        const uint MOD_NOREPEAT = 0x4000;
        readonly Dictionary<int, string> registrations = new Dictionary<int, string>();
        int nextId = 7300;

        [DllImport("user32.dll", SetLastError = true)]
        static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint virtualKey);

        [DllImport("user32.dll", SetLastError = true)]
        static extern bool UnregisterHotKey(IntPtr hwnd, int id);

        public event EventHandler<HotkeyPressedEventArgs> HotkeyPressed;

        public GlobalHotkeyManager()
        {
            var parameters = new CreateParams();
            parameters.Caption = "AudioRouterHotkeys";
            parameters.Parent = new IntPtr(-3);
            CreateHandle(parameters);
        }

        public bool Register(string profileName, uint modifiers, Keys key)
        {
            int id = nextId++;
            if (!RegisterHotKey(Handle, id, modifiers | MOD_NOREPEAT, (uint)key)) return false;
            registrations[id] = profileName;
            return true;
        }

        public void UnregisterAll()
        {
            foreach (var id in new List<int>(registrations.Keys)) UnregisterHotKey(Handle, id);
            registrations.Clear();
        }

        protected override void WndProc(ref Message message)
        {
            if (message.Msg == WM_HOTKEY)
            {
                string profileName;
                if (registrations.TryGetValue(message.WParam.ToInt32(), out profileName) && HotkeyPressed != null)
                    HotkeyPressed(this, new HotkeyPressedEventArgs(profileName));
            }
            base.WndProc(ref message);
        }

        public void Dispose()
        {
            UnregisterAll();
            if (Handle != IntPtr.Zero) DestroyHandle();
        }
    }

    public sealed class BufferedForm : Form
    {
        public BufferedForm()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            DoubleBuffered = true;
        }

        protected override void OnPaintBackground(PaintEventArgs e)
        {
            e.Graphics.Clear(BackColor);
        }
    }

    public static class WindowEffects
    {
        [StructLayout(LayoutKind.Sequential)]
        struct AccentPolicy
        {
            public int AccentState;
            public int AccentFlags;
            public int GradientColor;
            public int AnimationId;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct WindowCompositionAttributeData
        {
            public int Attribute;
            public IntPtr Data;
            public int SizeOfData;
        }

        [DllImport("user32.dll")]
        static extern int SetWindowCompositionAttribute(IntPtr hwnd, ref WindowCompositionAttributeData data);

        [DllImport("dwmapi.dll")]
        static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        static extern IntPtr SendMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

        public static void ApplyIdentityAndIcon(Form form, Icon icon)
        {
            try { SetCurrentProcessExplicitAppUserModelID("AudioRouter.Desktop"); } catch { }
            if (form == null || icon == null) return;
            try
            {
                form.Icon = icon;
                var handle = form.Handle;
                SendMessage(handle, 0x0080, new IntPtr(1), icon.Handle);
                SendMessage(handle, 0x0080, IntPtr.Zero, icon.Handle);
            }
            catch { }
        }

        public static void EnableSolidDark(IntPtr hwnd)
        {
            try
            {
                int darkValue = 1;
                DwmSetWindowAttribute(hwnd, 20, ref darkValue, sizeof(int));
                int corners = 2;
                DwmSetWindowAttribute(hwnd, 33, ref corners, sizeof(int));
                if (Environment.OSVersion.Version.Build >= 22000)
                {
                    int backdrop = 1;
                    DwmSetWindowAttribute(hwnd, 38, ref backdrop, sizeof(int));
                }

                var accent = new AccentPolicy();
                accent.AccentState = 0;
                var size = Marshal.SizeOf(accent);
                var pointer = Marshal.AllocHGlobal(size);
                try
                {
                    Marshal.StructureToPtr(accent, pointer, false);
                    var data = new WindowCompositionAttributeData { Attribute = 19, Data = pointer, SizeOfData = size };
                    SetWindowCompositionAttribute(hwnd, ref data);
                }
                finally { Marshal.FreeHGlobal(pointer); }
            }
            catch { }
        }

        public static void EnableAcrylic(IntPtr hwnd, bool dark)
        {
            try
            {
                int darkValue = dark ? 1 : 0;
                DwmSetWindowAttribute(hwnd, 20, ref darkValue, sizeof(int));
                int corners = 2;
                DwmSetWindowAttribute(hwnd, 33, ref corners, sizeof(int));
                if (Environment.OSVersion.Version.Build >= 22000)
                {
                    int backdrop = 3;
                    DwmSetWindowAttribute(hwnd, 38, ref backdrop, sizeof(int));
                }

                var accent = new AccentPolicy();
                accent.AccentState = 4;
                accent.AccentFlags = 2;
                accent.GradientColor = dark ? unchecked((int)0xD020120B) : unchecked((int)0xD8F5F5F5);
                var size = Marshal.SizeOf(accent);
                var pointer = Marshal.AllocHGlobal(size);
                try
                {
                    Marshal.StructureToPtr(accent, pointer, false);
                    var data = new WindowCompositionAttributeData { Attribute = 19, Data = pointer, SizeOfData = size };
                    SetWindowCompositionAttribute(hwnd, ref data);
                }
                finally { Marshal.FreeHGlobal(pointer); }
            }
            catch { }
        }

        public static void RoundControl(Control control, int radius)
        {
            if (control.Width <= 1 || control.Height <= 1) return;
            var bounds = new Rectangle(0, 0, control.Width, control.Height);
            using (var path = new GraphicsPath())
            {
                int diameter = Math.Max(2, radius * 2);
                var arc = new Rectangle(bounds.X, bounds.Y, diameter, diameter);
                path.AddArc(arc, 180, 90);
                arc.X = bounds.Right - diameter;
                path.AddArc(arc, 270, 90);
                arc.Y = bounds.Bottom - diameter;
                path.AddArc(arc, 0, 90);
                arc.X = bounds.Left;
                path.AddArc(arc, 90, 90);
                path.CloseFigure();
                var old = control.Region;
                control.Region = new Region(path);
                if (old != null) old.Dispose();
            }
        }
    }
}
'@

try {
    Add-Type -TypeDefinition $nativeCode -Language CSharp -ReferencedAssemblies @('System.dll', 'System.Core.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll') -ErrorAction Stop
} catch {
    [System.Windows.Forms.MessageBox]::Show("无法加载 Windows 音频组件。`r`n`r`n$($_.Exception.Message)", "音频一键切换", 'OK', 'Error') | Out-Null
    exit 1
}

if ($SelfTest) {
    try {
        $testIconPath = Join-Path $PSScriptRoot 'assets\audio-switch-icon-driver.ico'
        if (-not (Test-Path -LiteralPath $testIconPath)) { throw "Icon file not found: $testIconPath" }
        $testIcon = [System.Drawing.Icon]::new($testIconPath)
        $testIcon.Dispose()
        $testMenu = New-Object System.Windows.Forms.ContextMenuStrip
        $testMenu.Renderer = [AudioSwitchNative.ModernMenuRenderer]::new($false)
        $testMenu.Dispose()
        $testHotkeyManager = New-Object AudioSwitchNative.GlobalHotkeyManager
        if (-not $testHotkeyManager.Register('__selftest__', [uint32]7, [System.Windows.Forms.Keys]::F24)) {
            throw 'Global hotkey registration is unavailable or the test combination is occupied.'
        }
        $testHotkeyManager.UnregisterAll()
        $testHotkeyManager.Dispose()
        $testHotkeyButton = New-Object AudioSwitchNative.ModernCheckBox
        $testHotkeyButton.Dispose()
        $testOutputs = @([AudioSwitchNative.AudioManager]::GetEndpoints([AudioSwitchNative.DataFlow]::Render))
        $testInputs = @([AudioSwitchNative.AudioManager]::GetEndpoints([AudioSwitchNative.DataFlow]::Capture))
        Write-Output "SELFTEST OK"
        $defaultOutputId = [AudioSwitchNative.AudioManager]::GetDefaultId([AudioSwitchNative.DataFlow]::Render)
        $defaultInputId = [AudioSwitchNative.AudioManager]::GetDefaultId([AudioSwitchNative.DataFlow]::Capture)
        Write-Output "Default output ID found: $(-not [string]::IsNullOrWhiteSpace($defaultOutputId))"
        Write-Output "Default input ID found: $(-not [string]::IsNullOrWhiteSpace($defaultInputId))"
        Write-Output "Outputs: $($testOutputs.Count)"
        foreach ($device in $testOutputs) { Write-Output "  $($device.Name)$(if ($device.Id -eq $defaultOutputId) { ' [default]' })" }
        Write-Output "Inputs: $($testInputs.Count)"
        foreach ($device in $testInputs) { Write-Output "  $($device.Name)$(if ($device.Id -eq $defaultInputId) { ' [default]' })" }
        exit 0
    } catch {
        Write-Error "SELFTEST FAILED: $($_.Exception.Message)"
        exit 1
    }
}

$script:AppDir = Join-Path $env:LOCALAPPDATA 'AudioSwitch'
$script:ProfileFile = Join-Path $script:AppDir 'profiles.json'
$script:SettingsFile = Join-Path $script:AppDir 'settings.json'
$script:Profiles = @()
$script:Outputs = @()
$script:Inputs = @()
$script:ClosingForReal = $false
$script:InitializingSettings = $true
$script:Settings = [PSCustomObject]@{ StartMinimized = $false }
$script:StartHidden = [bool]$Minimized
$script:TrayMenuRenderer = $null
$script:HotkeyManager = $null
$script:TrayHeaderPanel = $null
$script:TrayHeaderBrand = $null
$script:TrayCurrentLabel = $null

if (-not (Test-Path $script:AppDir)) { New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null }

function Load-Profiles {
    $script:Profiles = @()
    if (Test-Path $script:ProfileFile) {
        try {
            $loaded = Get-Content -LiteralPath $script:ProfileFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $loaded) { $script:Profiles = @($loaded) }
        } catch {
            [System.Windows.Forms.MessageBox]::Show("方案文件损坏，已忽略。`r`n$($_.Exception.Message)", '音频一键切换', 'OK', 'Warning') | Out-Null
        }
    }
}

function Save-Profiles {
    ConvertTo-Json -InputObject @($script:Profiles) -Depth 5 | Set-Content -LiteralPath $script:ProfileFile -Encoding UTF8
}

function Load-Settings {
    $script:Settings = [PSCustomObject]@{ StartMinimized = $false }
    if (Test-Path $script:SettingsFile) {
        try {
            $loaded = Get-Content -LiteralPath $script:SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $loaded -and $null -ne $loaded.StartMinimized) {
                $script:Settings.StartMinimized = [bool]$loaded.StartMinimized
            }
        } catch {
            $script:Settings = [PSCustomObject]@{ StartMinimized = $false }
        }
    }
}

function Save-Settings {
    $script:Settings | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsFile -Encoding UTF8
}

function Test-StartupRegistration {
    try {
        $value = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'AudioSwitch' -ErrorAction Stop).AudioSwitch
        $launcher = Join-Path $PSScriptRoot '启动音频切换器.vbs'
        return (-not [string]::IsNullOrWhiteSpace([string]$value)) -and ([string]$value).Contains($launcher)
    } catch {
        return $false
    }
}

function Set-StartupRegistration([bool]$Enabled) {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if ($Enabled) {
        $launcher = Join-Path $PSScriptRoot '启动音频切换器.vbs'
        $command = 'wscript.exe "{0}" /minimized' -f $launcher
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        New-ItemProperty -LiteralPath $key -Name 'AudioSwitch' -Value $command -PropertyType String -Force | Out-Null
    } else {
        Remove-ItemProperty -LiteralPath $key -Name 'AudioSwitch' -ErrorAction SilentlyContinue
    }
}

function New-Label([string]$Text, [float]$Size, [System.Drawing.FontStyle]$Style = 'Regular') {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.AutoSize = $true
    $label.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', $Size, $Style)
    $label.ForeColor = [System.Drawing.Color]::FromArgb(229, 231, 235)
    return $label
}

function Initialize-ThemedComboBox($Combo, $Background, $SelectedBackground, $Foreground) {
    $Combo.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
    $Combo.ItemHeight = 24
    $drawBackground = $Background
    $drawSelected = $SelectedBackground
    $drawForeground = $Foreground
    $Combo.Add_DrawItem({
        param($sender, $eventArgs)
        if ($eventArgs.Index -lt 0) { return }
        $isSelected = (($eventArgs.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0)
        $fill = if ($isSelected) { $drawSelected } else { $drawBackground }
        $brush = New-Object System.Drawing.SolidBrush($fill)
        $eventArgs.Graphics.FillRectangle($brush, $eventArgs.Bounds)
        $brush.Dispose()
        $textBounds = New-Object System.Drawing.Rectangle(($eventArgs.Bounds.X + 7), $eventArgs.Bounds.Y, ($eventArgs.Bounds.Width - 9), $eventArgs.Bounds.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($eventArgs.Graphics, $sender.Items[$eventArgs.Index].ToString(), $sender.Font, $textBounds, $drawForeground, [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis)
    }.GetNewClosure())
}

function Find-Endpoint($items, [string]$id, [string]$name) {
    $match = @($items | Where-Object { $_.Id -eq $id } | Select-Object -First 1)
    if ($match.Count -gt 0) { return $match[0] }
    $match = @($items | Where-Object { $_.Name -eq $name } | Select-Object -First 1)
    if ($match.Count -gt 0) { return $match[0] }
    return $null
}

function Set-Status([string]$Text, [bool]$IsError = $false) {
    $statusLabel.Text = $Text
    $statusLabel.ForeColor = if ($IsError) { [System.Drawing.Color]::FromArgb(248, 113, 113) } else { [System.Drawing.Color]::FromArgb(52, 211, 153) }
}

function Show-MainWindow {
    $form.ShowInTaskbar = $true
    $form.Show()
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Activate()
    $form.BringToFront()
}

function Hide-ToTray([bool]$ShowNotice = $true) {
    $form.ShowInTaskbar = $false
    $form.Hide()
    $trayIcon.Visible = $true
    if ($ShowNotice) {
        try {
            $trayIcon.ShowBalloonTip(1600, '音频一键切换', '程序仍在托盘运行。双击图标可打开，右键可切换方案或退出。', [System.Windows.Forms.ToolTipIcon]::Info)
        } catch { }
    }
}

function Refresh-Devices {
    try {
        $selectedOutputId = if ($outputCombo.SelectedItem) { $outputCombo.SelectedItem.Id } else { $null }
        $selectedInputId = if ($inputCombo.SelectedItem) { $inputCombo.SelectedItem.Id } else { $null }
        $script:Outputs = @([AudioSwitchNative.AudioManager]::GetEndpoints([AudioSwitchNative.DataFlow]::Render))
        $script:Inputs = @([AudioSwitchNative.AudioManager]::GetEndpoints([AudioSwitchNative.DataFlow]::Capture))
        $outputCombo.Items.Clear()
        $inputCombo.Items.Clear()
        foreach ($item in $script:Outputs) { [void]$outputCombo.Items.Add($item) }
        foreach ($item in $script:Inputs) { [void]$inputCombo.Items.Add($item) }

        $outputIndex = 0
        for ($i = 0; $i -lt $script:Outputs.Count; $i++) {
            if (($selectedOutputId -and $script:Outputs[$i].Id -eq $selectedOutputId) -or (-not $selectedOutputId -and $script:Outputs[$i].IsDefault)) { $outputIndex = $i; break }
        }
        $inputIndex = 0
        for ($i = 0; $i -lt $script:Inputs.Count; $i++) {
            if (($selectedInputId -and $script:Inputs[$i].Id -eq $selectedInputId) -or (-not $selectedInputId -and $script:Inputs[$i].IsDefault)) { $inputIndex = $i; break }
        }
        if ($outputCombo.Items.Count -gt 0) { $outputCombo.SelectedIndex = $outputIndex }
        if ($inputCombo.Items.Count -gt 0) { $inputCombo.SelectedIndex = $inputIndex }

        $currentOutput = @($script:Outputs | Where-Object IsDefault | Select-Object -First 1)
        $currentInput = @($script:Inputs | Where-Object IsDefault | Select-Object -First 1)
        $currentOutputLabel.Text = if ($currentOutput.Count) { $currentOutput[0].Name } else { '未检测到活动设备' }
        $currentInputLabel.Text = if ($currentInput.Count) { $currentInput[0].Name } else { '未检测到活动设备' }
        Set-Status "已刷新 · 输出 $($script:Outputs.Count) 个，输入 $($script:Inputs.Count) 个"
    } catch {
        Set-Status "刷新失败：$($_.Exception.Message)" $true
    }
}

function Switch-Profile($profile) {
    try {
        Refresh-Devices
        $output = Find-Endpoint $script:Outputs $profile.OutputId $profile.OutputName
        $input = Find-Endpoint $script:Inputs $profile.InputId $profile.InputName
        $missing = @()
        if (-not $output) { $missing += "输出：$($profile.OutputName)" }
        if (-not $input) { $missing += "输入：$($profile.InputName)" }
        if ($missing.Count) { throw "找不到设备（可能未连接）：$($missing -join '；')" }
        [AudioSwitchNative.AudioManager]::SetDefault($output.Id)
        [AudioSwitchNative.AudioManager]::SetDefault($input.Id)
        Start-Sleep -Milliseconds 150
        Refresh-Devices
        Update-TrayMenuState
        Set-Status "✓ 已切换到「$($profile.Name)」；Windows / Discord / Steam 将使用这组默认设备"
        $trayIcon.ShowBalloonTip(1800, '音频设备已切换', "$($profile.Name)`n输出：$($output.Name)`n输入：$($input.Name)", 'Info')
    } catch {
        Set-Status "切换失败：$($_.Exception.Message)" $true
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '切换失败', 'OK', 'Error') | Out-Null
    }
}

function Get-HotkeyDisplay([int]$Modifiers, [int]$KeyCode) {
    if ($KeyCode -le 0) { return '未设置快捷键' }
    $parts = New-Object System.Collections.Generic.List[string]
    if (($Modifiers -band 2) -ne 0) { $parts.Add('Ctrl') }
    if (($Modifiers -band 1) -ne 0) { $parts.Add('Alt') }
    if (($Modifiers -band 4) -ne 0) { $parts.Add('Shift') }
    if (($Modifiers -band 8) -ne 0) { $parts.Add('Win') }
    $keyName = ([System.Windows.Forms.Keys]$KeyCode).ToString()
    if ($keyName -match '^D([0-9])$') { $keyName = $Matches[1] }
    $keyNames = @{
        'OemMinus' = '-'; 'Oemplus' = '='; 'Oemcomma' = ','; 'OemPeriod' = '.'
        'OemQuestion' = '/'; 'OemSemicolon' = ';'; 'OemQuotes' = "'"
        'OemOpenBrackets' = '['; 'OemCloseBrackets' = ']'; 'OemPipe' = '\'
    }
    if ($keyNames.ContainsKey($keyName)) { $keyName = $keyNames[$keyName] }
    $parts.Add($keyName)
    return ($parts -join ' + ')
}

function Register-ProfileHotkeys {
    if ($null -eq $script:HotkeyManager) { return @() }
    $script:HotkeyManager.UnregisterAll()
    $failed = New-Object System.Collections.Generic.List[string]
    foreach ($profile in @($script:Profiles)) {
        $keyCode = [int]$profile.HotkeyKey
        if ($keyCode -le 0) { continue }
        $ok = $script:HotkeyManager.Register([string]$profile.Name, [uint32]([int]$profile.HotkeyModifiers), [System.Windows.Forms.Keys]$keyCode)
        if (-not $ok) { $failed.Add([string]$profile.Name) }
    }
    return @($failed)
}

function Show-HotkeyEditor($profile, [string]$PreviewPath) {
    $dialog = New-Object AudioSwitchNative.BufferedForm
    $dialog.Text = "编辑快捷键 · $($profile.Name)"
    $dialog.ClientSize = New-Object System.Drawing.Size(470, 252)
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.StartPosition = 'CenterParent'
    $dialog.BackColor = $colorBackground
    $dialog.Opacity = 0.985
    $dialog.ForeColor = $colorTextPrimary
    $dialog.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $dialog.Icon = $appIcon
    $dialog.KeyPreview = $true

    $title = New-Label '按下新的快捷键' 15 'Bold'
    $title.Location = New-Object System.Drawing.Point(24, 22)
    $dialog.Controls.Add($title)
    $hint = New-Label '建议使用 Ctrl / Alt / Shift 与字母或数字组合，也可以直接使用 F1–F12。' 8.5
    $hint.Location = New-Object System.Drawing.Point(25, 54)
    $hint.ForeColor = $colorTextSecondary
    $dialog.Controls.Add($hint)

    $capturePanel = New-Object AudioSwitchNative.AcrylicPanel
    $capturePanel.Location = New-Object System.Drawing.Point(24, 84)
    $capturePanel.Size = New-Object System.Drawing.Size(422, 68)
    $capturePanel.CornerRadius = 12
    $capturePanel.FillColor = [System.Drawing.Color]::FromArgb(162, 32, 42, 52)
    $capturePanel.BorderColor = [System.Drawing.Color]::FromArgb(92, 86, 104, 121)
    $dialog.Controls.Add($capturePanel)
    $captureCaption = New-Label '当前组合' 7.5 'Bold'
    $captureCaption.Location = New-Object System.Drawing.Point(16, 10)
    $captureCaption.ForeColor = [System.Drawing.Color]::FromArgb(166, 184, 205)
    $capturePanel.Controls.Add($captureCaption)
    $hotkeyValue = New-Label '' 13 'Bold'
    $hotkeyValue.Location = New-Object System.Drawing.Point(16, 31)
    $hotkeyValue.ForeColor = $colorAccent
    $capturePanel.Controls.Add($hotkeyValue)

    $state = [PSCustomObject]@{
        Modifiers = [int]$profile.HotkeyModifiers
        KeyCode = [int]$profile.HotkeyKey
        Accepted = $false
    }
    $hotkeyValue.Text = Get-HotkeyDisplay $state.Modifiers $state.KeyCode

    $validation = New-Label '等待按键…' 8.4 'Bold'
    $validation.Location = New-Object System.Drawing.Point(25, 160)
    $validation.ForeColor = [System.Drawing.Color]::FromArgb(147, 197, 253)
    $dialog.Controls.Add($validation)

    $saveHotkeyButton = New-Object AudioSwitchNative.ModernButton
    $saveHotkeyButton.Text = '保存快捷键'
    $saveHotkeyButton.Size = New-Object System.Drawing.Size(118, 34)
    $saveHotkeyButton.Location = New-Object System.Drawing.Point(328, 198)
    $saveHotkeyButton.FillColor = $colorAccent
    $saveHotkeyButton.HoverFillColor = [System.Drawing.Color]::FromArgb(119, 239, 193)
    $saveHotkeyButton.PressedFillColor = [System.Drawing.Color]::FromArgb(81, 205, 151)
    $saveHotkeyButton.BorderWidth = 0
    $saveHotkeyButton.CornerRadius = 9
    $saveHotkeyButton.ForeColor = [System.Drawing.Color]::FromArgb(8, 27, 18)
    $saveHotkeyButton.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', [single]8.5, [System.Drawing.FontStyle]::Bold)
    $dialog.Controls.Add($saveHotkeyButton)

    $clearHotkeyButton = New-Object AudioSwitchNative.ModernButton
    $clearHotkeyButton.Text = '清除快捷键'
    $clearHotkeyButton.Size = New-Object System.Drawing.Size(112, 34)
    $clearHotkeyButton.Location = New-Object System.Drawing.Point(122, 198)
    $clearHotkeyButton.FillColor = $colorSurface
    $clearHotkeyButton.HoverFillColor = $colorElevated
    $clearHotkeyButton.PressedFillColor = $colorInput
    $clearHotkeyButton.BorderColor = $colorBorder
    $clearHotkeyButton.CornerRadius = 9
    $clearHotkeyButton.ForeColor = $colorTextSecondary
    $dialog.Controls.Add($clearHotkeyButton)

    $cancelHotkeyButton = New-Object AudioSwitchNative.ModernButton
    $cancelHotkeyButton.Text = '取消'
    $cancelHotkeyButton.Size = New-Object System.Drawing.Size(82, 34)
    $cancelHotkeyButton.Location = New-Object System.Drawing.Point(240, 198)
    $cancelHotkeyButton.FillColor = $colorSurface
    $cancelHotkeyButton.HoverFillColor = $colorElevated
    $cancelHotkeyButton.PressedFillColor = $colorInput
    $cancelHotkeyButton.BorderColor = $colorBorder
    $cancelHotkeyButton.CornerRadius = 9
    $cancelHotkeyButton.ForeColor = $colorTextSecondary
    $dialog.Controls.Add($cancelHotkeyButton)

    $dialog.Add_KeyDown({
        param($sender, $eventArgs)
        $eventArgs.SuppressKeyPress = $true
        $eventArgs.Handled = $true
        if ($eventArgs.KeyCode -in @('ControlKey', 'ShiftKey', 'Menu', 'LControlKey', 'RControlKey', 'LShiftKey', 'RShiftKey', 'LMenu', 'RMenu')) {
            $validation.Text = '继续按下字母、数字或功能键'
            $validation.ForeColor = [System.Drawing.Color]::FromArgb(147, 197, 253)
            return
        }
        $modifiers = 0
        if ($eventArgs.Control) { $modifiers = $modifiers -bor 2 }
        if ($eventArgs.Alt) { $modifiers = $modifiers -bor 1 }
        if ($eventArgs.Shift) { $modifiers = $modifiers -bor 4 }
        $keyCode = [int]$eventArgs.KeyCode
        $isFunctionKey = ($keyCode -ge [int][System.Windows.Forms.Keys]::F1 -and $keyCode -le [int][System.Windows.Forms.Keys]::F24)
        if ($modifiers -eq 0 -and -not $isFunctionKey) {
            $validation.Text = '普通按键需要至少搭配 Ctrl、Alt 或 Shift'
            $validation.ForeColor = [System.Drawing.Color]::FromArgb(248, 113, 113)
            return
        }
        $state.Modifiers = $modifiers
        $state.KeyCode = $keyCode
        $hotkeyValue.Text = Get-HotkeyDisplay $state.Modifiers $state.KeyCode
        $validation.Text = '组合已记录，点击“保存快捷键”即可生效'
        $validation.ForeColor = $colorAccent
    }.GetNewClosure())

    $saveHotkeyButton.Add_Click({
        if ($state.KeyCode -le 0) {
            $validation.Text = '请先按下一个快捷键组合，或点击“清除快捷键”'
            $validation.ForeColor = [System.Drawing.Color]::FromArgb(248, 113, 113)
            return
        }
        $duplicate = @($script:Profiles | Where-Object {
            $_.Name -ne $profile.Name -and [int]$_.HotkeyModifiers -eq $state.Modifiers -and [int]$_.HotkeyKey -eq $state.KeyCode
        })
        if ($duplicate.Count -gt 0) {
            $validation.Text = "该快捷键已用于方案「$($duplicate[0].Name)」"
            $validation.ForeColor = [System.Drawing.Color]::FromArgb(248, 113, 113)
            return
        }
        $state.Accepted = $true
        $dialog.Close()
    }.GetNewClosure())
    $clearHotkeyButton.Add_Click({
        $state.Modifiers = 0
        $state.KeyCode = 0
        $state.Accepted = $true
        $dialog.Close()
    }.GetNewClosure())
    $cancelHotkeyButton.Add_Click({ $dialog.Close() })
    $dialog.Add_Shown({
        [AudioSwitchNative.WindowEffects]::EnableSolidDark($dialog.Handle)
        [AudioSwitchNative.WindowEffects]::ApplyIdentityAndIcon($dialog, $appIcon)
        $dialog.Invalidate($true)
        $dialog.Update()
        $dialog.Activate()
    })

    if (-not [string]::IsNullOrWhiteSpace($PreviewPath)) {
        $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
        $dialog.Location = New-Object System.Drawing.Point(-32000, -32000)
        $dialog.Show()
        [System.Windows.Forms.Application]::DoEvents()
        $dialog.Invalidate($true)
        $dialog.Update()
        $dialogPreview = New-Object System.Drawing.Bitmap($dialog.Width, $dialog.Height)
        $dialog.DrawToBitmap($dialogPreview, (New-Object System.Drawing.Rectangle(0, 0, $dialog.Width, $dialog.Height)))
        $dialogPreview.Save($PreviewPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $dialogPreview.Dispose()
        $dialog.Hide()
        $dialog.Dispose()
        return
    }

    [void]$dialog.ShowDialog($form)
    if ($state.Accepted) {
        $profile | Add-Member -NotePropertyName HotkeyModifiers -NotePropertyValue ([int]$state.Modifiers) -Force
        $profile | Add-Member -NotePropertyName HotkeyKey -NotePropertyValue ([int]$state.KeyCode) -Force
        Save-Profiles
        $failed = @(Register-ProfileHotkeys)
        Render-Profiles
        Rebuild-TrayMenu
        if ($failed -contains [string]$profile.Name) {
            Set-Status "快捷键已保存，但该组合正被其他程序占用" $true
        } elseif ($state.KeyCode -gt 0) {
            Set-Status "已为「$($profile.Name)」设置快捷键：$(Get-HotkeyDisplay $state.Modifiers $state.KeyCode)"
        } else {
            Set-Status "已清除「$($profile.Name)」的快捷键"
        }
    }
    $dialog.Dispose()
}

function Update-ResponsiveLayout {
    if ($null -ne $currentPanel -and $null -ne $outputTile -and $null -ne $inputTile) {
        $panelWidth = [Math]::Max(720, $currentPanel.ClientSize.Width)
        $tileWidth = [Math]::Floor(($panelWidth - 52) / 2)
        $outputTile.Size = New-Object System.Drawing.Size($tileWidth, 46)
        $inputTile.Location = New-Object System.Drawing.Point(($tileWidth + 36), 34)
        $inputTile.Size = New-Object System.Drawing.Size($tileWidth, 46)
        $currentOutputLabel.Width = [Math]::Max(180, $tileWidth - 68)
        $currentInputLabel.Width = [Math]::Max(180, $tileWidth - 68)
        $routeBadge.Location = New-Object System.Drawing.Point(($panelWidth - $routeBadge.Width - 16), 10)
    }

    if ($null -ne $createPanel -and $null -ne $profileNameBox -and $null -ne $saveButton) {
        $panelWidth = [Math]::Max(720, $createPanel.ClientSize.Width)
        $padding = 16
        $gap = 12
        $nameWidth = 160
        $saveWidth = 104
        $comboWidth = [Math]::Floor(($panelWidth - ($padding * 2) - $nameWidth - $saveWidth - ($gap * 3)) / 2)
        $outputX = $padding + $nameWidth + $gap
        $inputX = $outputX + $comboWidth + $gap
        $saveX = $panelWidth - $padding - $saveWidth
        $outHint.Location = New-Object System.Drawing.Point($outputX, 11)
        $outputCombo.Location = New-Object System.Drawing.Point($outputX, 34)
        $outputCombo.Width = $comboWidth
        $inHint.Location = New-Object System.Drawing.Point($inputX, 11)
        $inputCombo.Location = New-Object System.Drawing.Point($inputX, 34)
        $inputCombo.Width = $comboWidth
        $saveButton.Location = New-Object System.Drawing.Point($saveX, 33)
    }
}

function Update-ProfileScroll {
    if ($null -eq $profilesViewport -or $null -eq $profileScroll) { return }
    $cardHeight = Get-ProfileCardHeight
    $contentHeight = if ($script:Profiles.Count -gt 0) { ($script:Profiles.Count * ($cardHeight + 9)) - 9 } else { 64 }
    $profilePanel.Size = New-Object System.Drawing.Size(($profilesViewport.ClientSize.Width - 20), ([Math]::Max($profilesViewport.ClientSize.Height, $contentHeight)))
    $profileScroll.LargeChange = [Math]::Max(1, $profilesViewport.ClientSize.Height)
    $profileScroll.Maximum = [Math]::Max(0, $contentHeight - $profilesViewport.ClientSize.Height)
    $profileScroll.Visible = ($profileScroll.Maximum -gt 0)
    if ($profileScroll.Value -gt $profileScroll.Maximum) { $profileScroll.Value = $profileScroll.Maximum }
    $profilePanel.Top = -$profileScroll.Value
}

function Get-ProfileCardHeight {
    # Keep each profile visually compact instead of stretching it with the window.
    return 104
}

function Render-Profiles {
    $profilePanel.SuspendLayout()
    $profilePanel.Controls.Clear()
    if ($null -ne $profilesCountLabel) { $profilesCountLabel.Text = "$($script:Profiles.Count) 个方案" }
    if ($script:Profiles.Count -eq 0) {
        $empty = New-Label '还没有方案  ·  在上方选择设备并保存' 9
        $empty.ForeColor = $colorMuted
        $empty.Margin = New-Object System.Windows.Forms.Padding(16, 22, 8, 8)
        [void]$profilePanel.Controls.Add($empty)
    }
    $cardHeight = Get-ProfileCardHeight
    foreach ($profile in @($script:Profiles)) {
        $card = New-Object AudioSwitchNative.AcrylicPanel
        $cardWidth = [Math]::Max(730, $profilePanel.ClientSize.Width - 8)
        $actionLeft = $cardWidth - 236
        $inputStart = 20 + [Math]::Floor(($actionLeft - 32) / 2)
        $card.Size = New-Object System.Drawing.Size($cardWidth, $cardHeight)
        $card.CornerRadius = 12
        $card.FillColor = [System.Drawing.Color]::FromArgb(164, 43, 54, 65)
        $card.BorderColor = [System.Drawing.Color]::FromArgb(82, 79, 95, 111)
        $card.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 9)

        $statusDot = New-Label '●' 7
        $statusDot.Location = New-Object System.Drawing.Point(18, 17)
        $statusDot.ForeColor = $colorAccent
        $card.Controls.Add($statusDot)

        $name = New-Label $profile.Name 10.5 'Bold'
        $name.Location = New-Object System.Drawing.Point(35, 14)
        $name.MaximumSize = New-Object System.Drawing.Size(([Math]::Max(240, $actionLeft - 70)), 24)
        $card.Controls.Add($name)

        $actionDivider = New-Object System.Windows.Forms.Panel
        $actionDivider.Location = New-Object System.Drawing.Point(($cardWidth - 236), 11)
        $actionDivider.Size = New-Object System.Drawing.Size(1, ($cardHeight - 22))
        $actionDivider.BackColor = $colorDivider
        $card.Controls.Add($actionDivider)

        $detailDivider = New-Object System.Windows.Forms.Panel
        $detailDivider.Location = New-Object System.Drawing.Point(20, 42)
        $detailDivider.Size = New-Object System.Drawing.Size(([Math]::Max(120, $actionLeft - 40)), 1)
        $detailDivider.BackColor = $colorDivider
        $card.Controls.Add($detailDivider)

        $hotkeyButton = New-Object AudioSwitchNative.ModernButton
        $hotkeyButton.Text = if ([int]$profile.HotkeyKey -gt 0) {
            "快捷键  ·  $(Get-HotkeyDisplay ([int]$profile.HotkeyModifiers) ([int]$profile.HotkeyKey))"
        } else {
            '快捷键  ·  点击设置'
        }
        $hotkeyButton.Size = New-Object System.Drawing.Size(200, 30)
        $hotkeyButton.Location = New-Object System.Drawing.Point(($cardWidth - 218), 10)
        $hotkeyButton.FillColor = $colorInput
        $hotkeyButton.HoverFillColor = $colorElevated
        $hotkeyButton.PressedFillColor = $colorSurface
        $hotkeyButton.BorderColor = $colorBorder
        $hotkeyButton.CornerRadius = 8
        $hotkeyButton.ForeColor = if ([int]$profile.HotkeyKey -gt 0) { $colorAccent } else { $colorMuted }
        $hotkeyButton.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', [single]8, [System.Drawing.FontStyle]::Regular)
        $capturedHotkeyProfile = $profile
        $hotkeyButton.Add_Click({ Show-HotkeyEditor $capturedHotkeyProfile }.GetNewClosure())
        $card.Controls.Add($hotkeyButton)

        $outputCaption = New-Label 'OUT' 8 'Bold'
        $outputCaption.ForeColor = $colorAccent
        $outputCaption.Location = New-Object System.Drawing.Point(20, 51)
        $card.Controls.Add($outputCaption)
        $outputValue = New-Label $profile.OutputName 8.4
        $outputValue.ForeColor = $colorTextSecondary
        $outputValue.Location = New-Object System.Drawing.Point(20, 70)
        $outputValue.AutoSize = $false
        $outputValue.Size = New-Object System.Drawing.Size(([Math]::Max(120, $inputStart - 40)), 20)
        $outputValue.AutoEllipsis = $true
        $card.Controls.Add($outputValue)

        $inputCaption = New-Label 'IN' 8 'Bold'
        $inputCaption.ForeColor = [System.Drawing.Color]::FromArgb(151, 211, 235)
        $inputCaption.Location = New-Object System.Drawing.Point($inputStart, 51)
        $card.Controls.Add($inputCaption)
        $inputValue = New-Label $profile.InputName 8.4
        $inputValue.ForeColor = $colorTextSecondary
        $inputValue.Location = New-Object System.Drawing.Point($inputStart, 70)
        $inputValue.AutoSize = $false
        $inputValue.Size = New-Object System.Drawing.Size(([Math]::Max(120, $actionLeft - $inputStart - 20)), 20)
        $inputValue.AutoEllipsis = $true
        $card.Controls.Add($inputValue)

        $switchButton = New-Object AudioSwitchNative.ModernButton
        $switchButton.Text = '切换方案'
        $switchButton.Size = New-Object System.Drawing.Size(158, 36)
        $switchButton.Location = New-Object System.Drawing.Point(($cardWidth - 218), 56)
        $switchButton.FillColor = $colorAccent
        $switchButton.HoverFillColor = [System.Drawing.Color]::FromArgb(119, 239, 193)
        $switchButton.PressedFillColor = [System.Drawing.Color]::FromArgb(81, 205, 151)
        $switchButton.BorderWidth = 0
        $switchButton.CornerRadius = 9
        $switchButton.ForeColor = [System.Drawing.Color]::FromArgb(8, 27, 18)
        $switchButton.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', [single]9, [System.Drawing.FontStyle]::Bold)
        $capturedProfile = $profile
        $switchButton.Add_Click({ Switch-Profile $capturedProfile }.GetNewClosure())
        $card.Controls.Add($switchButton)

        $deleteButton = New-Object AudioSwitchNative.ModernButton
        $deleteButton.Text = ''
        $deleteButton.AccessibleName = '删除方案'
        $deleteButton.Size = New-Object System.Drawing.Size(34, 36)
        $deleteButton.Location = New-Object System.Drawing.Point(($cardWidth - 52), 56)
        $deleteButton.FillColor = [System.Drawing.Color]::FromArgb(220, 55, 66)
        $deleteButton.HoverFillColor = [System.Drawing.Color]::FromArgb(236, 72, 82)
        $deleteButton.PressedFillColor = [System.Drawing.Color]::FromArgb(187, 43, 54)
        $deleteButton.BorderWidth = 0
        $deleteButton.CornerRadius = 9
        $deleteButton.DrawCloseGlyph = $true
        $deleteButton.GlyphColor = [System.Drawing.Color]::FromArgb(255, 245, 246)
        $deleteButton.ForeColor = [System.Drawing.Color]::FromArgb(255, 245, 246)
        $deleteButton.Font = [System.Drawing.Font]::new('Segoe UI', [single]12, [System.Drawing.FontStyle]::Bold)
        $capturedName = [string]$profile.Name
        $deleteButton.Add_Click({
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "确定要删除音频方案「$capturedName」吗？`r`n`r`n这不会删除音频设备，但该方案和它的快捷键将一并移除。",
                '删除音频方案',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning,
                [System.Windows.Forms.MessageBoxDefaultButton]::Button2
            )
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            $script:Profiles = @($script:Profiles | Where-Object { $_.Name -ne $capturedName })
            Save-Profiles
            [void](Register-ProfileHotkeys)
            Render-Profiles
            Rebuild-TrayMenu
            Set-Status "已删除方案「$capturedName」"
        }.GetNewClosure())
        $card.Controls.Add($deleteButton)
        [void]$profilePanel.Controls.Add($card)
    }
    $profilePanel.ResumeLayout()
    Update-ProfileScroll
}

function Get-SystemUsesLightTheme {
    try {
        $value = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop).AppsUseLightTheme
        return ([int]$value -ne 0)
    } catch {
        return $false
    }
}

function Apply-TrayMenuTheme {
    $isLight = Get-SystemUsesLightTheme
    if ($isLight) {
        $background = [System.Drawing.Color]::FromArgb(248, 250, 252)
        $text = [System.Drawing.Color]::FromArgb(22, 31, 44)
        $muted = [System.Drawing.Color]::FromArgb(99, 115, 136)
        $danger = [System.Drawing.Color]::FromArgb(194, 48, 61)
    } else {
        $background = [System.Drawing.Color]::FromArgb(25, 32, 41)
        $text = [System.Drawing.Color]::FromArgb(241, 245, 248)
        $muted = [System.Drawing.Color]::FromArgb(158, 174, 189)
        $danger = [System.Drawing.Color]::FromArgb(255, 107, 120)
    }

    $newRenderer = [AudioSwitchNative.ModernMenuRenderer]::new([bool]$isLight)
    $trayMenu.Renderer = $newRenderer
    $script:TrayMenuRenderer = $newRenderer
    $trayMenu.BackColor = $background
    $trayMenu.ForeColor = $text
    if ($null -ne $script:TrayHeaderPanel) {
        $script:TrayHeaderPanel.BackColor = if ($isLight) {
            [System.Drawing.Color]::FromArgb(252, 253, 255)
        } else {
            [System.Drawing.Color]::FromArgb(39, 48, 58)
        }
    }
    if ($null -ne $script:TrayHeaderBrand) { $script:TrayHeaderBrand.ForeColor = $text }
    if ($null -ne $script:TrayCurrentLabel) { $script:TrayCurrentLabel.ForeColor = $muted }
    foreach ($menuItem in $trayMenu.Items) {
        if ($menuItem.Name -eq 'menuHeader' -or $menuItem.Name -eq 'emptyProfiles') {
            $menuItem.ForeColor = $muted
        } elseif ($menuItem.Name -eq 'exitApp') {
            $menuItem.ForeColor = $danger
        } else {
            $menuItem.ForeColor = $text
        }
    }

}

function Update-TrayMenuState {
    try {
        $menuOutputs = @([AudioSwitchNative.AudioManager]::GetEndpoints([AudioSwitchNative.DataFlow]::Render))
        $menuInputs = @([AudioSwitchNative.AudioManager]::GetEndpoints([AudioSwitchNative.DataFlow]::Capture))
        $currentName = $null
        foreach ($menuItem in $trayMenu.Items) {
            if (-not $menuItem.Name.StartsWith('profile_') -or $null -eq $menuItem.Tag) { continue }
            $profile = $menuItem.Tag
            $output = Find-Endpoint $menuOutputs $profile.OutputId $profile.OutputName
            $input = Find-Endpoint $menuInputs $profile.InputId $profile.InputName
            $menuItem.Checked = [bool]($output -and $input -and $output.IsDefault -and $input.IsDefault)
            if ($menuItem.Checked) { $currentName = [string]$profile.Name }
        }
        if ($null -ne $script:TrayCurrentLabel) {
            $script:TrayCurrentLabel.Text = if ($currentName) { "●  当前方案  ·  $currentName" } else { '○  请选择一个音频方案' }
            $script:TrayCurrentLabel.ForeColor = if ($currentName) { [System.Drawing.Color]::FromArgb(104, 231, 179) } else { $colorMuted }
        }
    } catch { }
}

function Rebuild-TrayMenu {
    if ($null -eq $trayMenu) { return }
    $trayMenu.Items.Clear()

    $script:TrayHeaderPanel = New-Object System.Windows.Forms.Panel
    $script:TrayHeaderPanel.Size = New-Object System.Drawing.Size(306, 58)
    $script:TrayHeaderPanel.Margin = New-Object System.Windows.Forms.Padding(0)
    $script:TrayHeaderBrand = New-Label 'AUDIO ROUTER' 10 'Bold'
    $script:TrayHeaderBrand.Font = [System.Drawing.Font]::new('Bahnschrift SemiBold', [single]10, [System.Drawing.FontStyle]::Bold)
    $script:TrayHeaderBrand.Location = New-Object System.Drawing.Point(14, 9)
    $script:TrayHeaderPanel.Controls.Add($script:TrayHeaderBrand)
    $script:TrayCurrentLabel = New-Label '○  请选择一个音频方案' 8
    $script:TrayCurrentLabel.Location = New-Object System.Drawing.Point(14, 33)
    $script:TrayCurrentLabel.MaximumSize = New-Object System.Drawing.Size(278, 20)
    $script:TrayHeaderPanel.Controls.Add($script:TrayCurrentLabel)
    $header = [System.Windows.Forms.ToolStripControlHost]::new($script:TrayHeaderPanel)
    $header.Name = 'menuHeader'
    $header.AutoSize = $false
    $header.Size = New-Object System.Drawing.Size(306, 58)
    $header.Margin = New-Object System.Windows.Forms.Padding(0)
    $header.Padding = New-Object System.Windows.Forms.Padding(0)
    [void]$trayMenu.Items.Add($header)
    [void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    foreach ($profile in @($script:Profiles)) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem
        $item.Name = "profile_$([Guid]::NewGuid().ToString('N'))"
        $item.Text = [string]$profile.Name
        $item.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', [single]8.8, [System.Drawing.FontStyle]::Regular)
        $item.Tag = $profile
        $item.ToolTipText = "输出：$($profile.OutputName)`n输入：$($profile.InputName)"
        if ([int]$profile.HotkeyKey -gt 0) {
            $item.ShortcutKeyDisplayString = Get-HotkeyDisplay ([int]$profile.HotkeyModifiers) ([int]$profile.HotkeyKey)
        }
        $item.Padding = New-Object System.Windows.Forms.Padding(14, 9, 14, 9)
        $captured = $profile
        $item.Add_Click({ Switch-Profile $captured }.GetNewClosure())
        [void]$trayMenu.Items.Add($item)
    }
    if (-not $script:Profiles.Count) {
        $emptyItem = New-Object System.Windows.Forms.ToolStripMenuItem
        $emptyItem.Name = 'emptyProfiles'
        $emptyItem.Text = '还没有保存音频方案'
        $emptyItem.Enabled = $false
        $emptyItem.Padding = New-Object System.Windows.Forms.Padding(14, 9, 14, 9)
        [void]$trayMenu.Items.Add($emptyItem)
    }

    [void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $showItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $showItem.Name = 'showWindow'
    $showItem.Text = '打开 Audio Router'
    $showItem.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', [single]8.8, [System.Drawing.FontStyle]::Bold)
    $showItem.Padding = New-Object System.Windows.Forms.Padding(14, 9, 14, 9)
    $showItem.Add_Click({ Show-MainWindow })
    [void]$trayMenu.Items.Add($showItem)

    $refreshItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $refreshItem.Name = 'refreshDevices'
    $refreshItem.Text = '刷新音频设备'
    $refreshItem.Padding = New-Object System.Windows.Forms.Padding(14, 9, 14, 9)
    $refreshItem.Add_Click({ Refresh-Devices; Update-TrayMenuState })
    [void]$trayMenu.Items.Add($refreshItem)

    $startupItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $startupItem.Name = 'startupToggle'
    $startupItem.Text = '随 Windows 启动'
    $startupItem.Checked = Test-StartupRegistration
    $startupItem.Padding = New-Object System.Windows.Forms.Padding(14, 9, 14, 9)
    $startupItem.Add_Click({
        try {
            Set-StartupRegistration (-not $startupItem.Checked)
            $startupItem.Checked = Test-StartupRegistration
            $script:InitializingSettings = $true
            $startupCheck.Checked = $startupItem.Checked
            $script:InitializingSettings = $false
        } catch { }
    }.GetNewClosure())
    [void]$trayMenu.Items.Add($startupItem)

    [void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $exitItem.Name = 'exitApp'
    $exitItem.Text = '退出 Audio Router'
    $exitItem.Padding = New-Object System.Windows.Forms.Padding(14, 9, 14, 9)
    $exitItem.Add_Click({ $script:ClosingForReal = $true; $trayIcon.Visible = $false; $form.Close() })
    [void]$trayMenu.Items.Add($exitItem)

    Apply-TrayMenuTheme
    Update-TrayMenuState
}

Load-Settings

$iconPath = Join-Path $PSScriptRoot 'assets\audio-switch-icon-driver.ico'
try {
    $appIcon = [System.Drawing.Icon]::new($iconPath)
    $script:OwnsAppIcon = $true
} catch {
    $appIcon = [System.Drawing.SystemIcons]::Application
    $script:OwnsAppIcon = $false
}

$colorBackground = [System.Drawing.Color]::FromArgb(19, 25, 33)
$colorSurface = [System.Drawing.Color]::FromArgb(37, 47, 57)
$colorElevated = [System.Drawing.Color]::FromArgb(48, 59, 70)
$colorInput = [System.Drawing.Color]::FromArgb(27, 35, 44)
$colorBorder = [System.Drawing.Color]::FromArgb(70, 85, 101)
$colorDivider = [System.Drawing.Color]::FromArgb(48, 59, 70)
$colorTextPrimary = [System.Drawing.Color]::FromArgb(246, 248, 250)
$colorTextSecondary = [System.Drawing.Color]::FromArgb(204, 214, 223)
$colorMuted = [System.Drawing.Color]::FromArgb(153, 170, 187)
$colorAccent = [System.Drawing.Color]::FromArgb(104, 231, 179)

$form = New-Object AudioSwitchNative.BufferedForm
$form.Text = 'AUDIO ROUTER'
$form.ClientSize = New-Object System.Drawing.Size(820, 716)
$form.MinimumSize = New-Object System.Drawing.Size(836, 700)
$form.StartPosition = 'CenterScreen'
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.BackColor = $colorBackground
$form.Opacity = 0.985
$form.ForeColor = $colorTextPrimary
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.Icon = $appIcon

$brandAudio = New-Label 'A U D I O' 8.2 'Bold'
$brandAudio.Font = [System.Drawing.Font]::new('Bahnschrift SemiBold', [single]8.2, [System.Drawing.FontStyle]::Bold)
$brandAudio.Location = New-Object System.Drawing.Point(28, 16)
$brandAudio.ForeColor = $colorAccent
$form.Controls.Add($brandAudio)
$brandRouter = New-Label 'ROUTER' 24 'Bold'
$brandRouter.Font = [System.Drawing.Font]::new('Bahnschrift SemiBold', [single]24, [System.Drawing.FontStyle]::Bold)
$brandRouter.Location = New-Object System.Drawing.Point(28, 30)
$brandRouter.ForeColor = $colorTextPrimary
$form.Controls.Add($brandRouter)

$refreshButton = New-Object AudioSwitchNative.ModernButton
$refreshButton.Text = '↻  刷新设备'
$refreshButton.Size = New-Object System.Drawing.Size(136, 40)
$refreshButton.Location = New-Object System.Drawing.Point(660, 23)
$refreshButton.Anchor = 'Top,Right'
$refreshButton.FillColor = [System.Drawing.Color]::FromArgb(34, 55, 56)
$refreshButton.HoverFillColor = [System.Drawing.Color]::FromArgb(43, 72, 68)
$refreshButton.PressedFillColor = [System.Drawing.Color]::FromArgb(29, 46, 49)
$refreshButton.BorderColor = [System.Drawing.Color]::FromArgb(74, 137, 115)
$refreshButton.CornerRadius = 10
$refreshButton.ForeColor = $colorTextPrimary
$refreshButton.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', [single]9, [System.Drawing.FontStyle]::Bold)
$refreshButton.Add_Click({ Refresh-Devices })
$form.Controls.Add($refreshButton)

$currentPanel = New-Object AudioSwitchNative.AcrylicPanel
$currentPanel.Location = New-Object System.Drawing.Point(24, 82)
$currentPanel.Size = New-Object System.Drawing.Size(772, 92)
$currentPanel.Anchor = 'Top,Left,Right'
$currentPanel.CornerRadius = 14
$currentPanel.FillColor = [System.Drawing.Color]::FromArgb(164, 43, 54, 65)
$currentPanel.BorderColor = [System.Drawing.Color]::FromArgb(88, 84, 100, 116)
$form.Controls.Add($currentPanel)
$now = New-Label 'ACTIVE AUDIO ROUTE' 7.5 'Bold'
$now.Location = New-Object System.Drawing.Point(16, 10)
$now.ForeColor = $colorAccent
$currentPanel.Controls.Add($now)

$routeBadge = New-Label '●  WINDOWS DEFAULT' 7.2 'Bold'
$routeBadge.Location = New-Object System.Drawing.Point(624, 10)
$routeBadge.ForeColor = [System.Drawing.Color]::FromArgb(151, 211, 235)
$currentPanel.Controls.Add($routeBadge)

$outputTile = New-Object AudioSwitchNative.AcrylicPanel
$outputTile.Location = New-Object System.Drawing.Point(16, 34)
$outputTile.Size = New-Object System.Drawing.Size(360, 46)
$outputTile.CornerRadius = 10
$outputTile.FillColor = [System.Drawing.Color]::FromArgb(148, 28, 37, 46)
$outputTile.BorderColor = [System.Drawing.Color]::FromArgb(76, 78, 94, 109)
$currentPanel.Controls.Add($outputTile)
$outputTag = New-Label 'OUT' 7.5 'Bold'
$outputTag.Location = New-Object System.Drawing.Point(12, 15)
$outputTag.ForeColor = $colorAccent
$outputTile.Controls.Add($outputTag)
$outCaption = New-Label '输出设备 · SYSTEM DEFAULT' 6.8 'Bold'
$outCaption.Location = New-Object System.Drawing.Point(54, 5)
$outCaption.ForeColor = $colorMuted
$outputTile.Controls.Add($outCaption)
$currentOutputLabel = New-Label '读取中…' 9.5 'Bold'
$currentOutputLabel.Location = New-Object System.Drawing.Point(54, 21)
$currentOutputLabel.ForeColor = $colorTextPrimary
$currentOutputLabel.AutoSize = $false
$currentOutputLabel.Size = New-Object System.Drawing.Size(292, 20)
$currentOutputLabel.AutoEllipsis = $true
$outputTile.Controls.Add($currentOutputLabel)

$inputTile = New-Object AudioSwitchNative.AcrylicPanel
$inputTile.Location = New-Object System.Drawing.Point(396, 34)
$inputTile.Size = New-Object System.Drawing.Size(360, 46)
$inputTile.CornerRadius = 10
$inputTile.FillColor = [System.Drawing.Color]::FromArgb(148, 28, 37, 46)
$inputTile.BorderColor = [System.Drawing.Color]::FromArgb(76, 78, 94, 109)
$currentPanel.Controls.Add($inputTile)
$inputTag = New-Label 'IN' 7.5 'Bold'
$inputTag.Location = New-Object System.Drawing.Point(12, 15)
$inputTag.ForeColor = [System.Drawing.Color]::FromArgb(151, 211, 235)
$inputTile.Controls.Add($inputTag)
$inCaption = New-Label '输入设备 · SYSTEM DEFAULT' 6.8 'Bold'
$inCaption.Location = New-Object System.Drawing.Point(54, 5)
$inCaption.ForeColor = $colorMuted
$inputTile.Controls.Add($inCaption)
$currentInputLabel = New-Label '读取中…' 9.5 'Bold'
$currentInputLabel.Location = New-Object System.Drawing.Point(54, 21)
$currentInputLabel.ForeColor = $colorTextPrimary
$currentInputLabel.AutoSize = $false
$currentInputLabel.Size = New-Object System.Drawing.Size(292, 20)
$currentInputLabel.AutoEllipsis = $true
$inputTile.Controls.Add($currentInputLabel)

$createLabel = New-Label '新建或更新方案' 10.5 'Bold'
$createLabel.Location = New-Object System.Drawing.Point(24, 192)
$createLabel.ForeColor = $colorTextPrimary
$form.Controls.Add($createLabel)
$createHelp = New-Label '同名方案会自动更新' 7.5
$createHelp.Location = New-Object System.Drawing.Point(154, 196)
$createHelp.ForeColor = $colorMuted
$form.Controls.Add($createHelp)

$createPanel = New-Object AudioSwitchNative.AcrylicPanel
$createPanel.Location = New-Object System.Drawing.Point(24, 220)
$createPanel.Size = New-Object System.Drawing.Size(772, 76)
$createPanel.Anchor = 'Top,Left,Right'
$createPanel.CornerRadius = 14
$createPanel.FillColor = [System.Drawing.Color]::FromArgb(164, 43, 54, 65)
$createPanel.BorderColor = [System.Drawing.Color]::FromArgb(88, 84, 100, 116)
$form.Controls.Add($createPanel)

$nameHint = New-Label '方案名称' 7.5 'Bold'
$nameHint.Location = New-Object System.Drawing.Point(16, 11)
$nameHint.ForeColor = $colorMuted
$createPanel.Controls.Add($nameHint)
$outHint = New-Label '输出设备  ·  耳机 / 音箱' 7.5 'Bold'
$outHint.Location = New-Object System.Drawing.Point(188, 11)
$outHint.ForeColor = $colorMuted
$createPanel.Controls.Add($outHint)
$inHint = New-Label '输入设备  ·  麦克风' 7.5 'Bold'
$inHint.Location = New-Object System.Drawing.Point(420, 11)
$inHint.ForeColor = $colorMuted
$createPanel.Controls.Add($inHint)

$profileNameBox = New-Object AudioSwitchNative.ModernTextBox
$profileNameBox.Location = New-Object System.Drawing.Point(16, 34)
$profileNameBox.Size = New-Object System.Drawing.Size(160, 31)
$profileNameBox.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$profileNameBox.ForeColor = $colorTextPrimary
$profileNameBox.FieldColor = $colorInput
$profileNameBox.BorderColor = $colorBorder
$profileNameBox.ActiveBorderColor = $colorAccent
$createPanel.Controls.Add($profileNameBox)

$outputCombo = New-Object AudioSwitchNative.ModernComboBox
$outputCombo.Location = New-Object System.Drawing.Point(188, 34)
$outputCombo.Size = New-Object System.Drawing.Size(220, 31)
$outputCombo.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$outputCombo.ForeColor = $colorTextPrimary
$outputCombo.FieldColor = $colorInput
$outputCombo.BorderColor = $colorBorder
$outputCombo.ActiveBorderColor = $colorAccent
$createPanel.Controls.Add($outputCombo)

$inputCombo = New-Object AudioSwitchNative.ModernComboBox
$inputCombo.Location = New-Object System.Drawing.Point(420, 34)
$inputCombo.Size = New-Object System.Drawing.Size(220, 31)
$inputCombo.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$inputCombo.ForeColor = $colorTextPrimary
$inputCombo.FieldColor = $colorInput
$inputCombo.BorderColor = $colorBorder
$inputCombo.ActiveBorderColor = $colorAccent
$createPanel.Controls.Add($inputCombo)

$saveButton = New-Object AudioSwitchNative.ModernButton
$saveButton.Text = '保存方案'
$saveButton.Size = New-Object System.Drawing.Size(104, 31)
$saveButton.Location = New-Object System.Drawing.Point(652, 33)
$saveButton.FillColor = $colorAccent
$saveButton.HoverFillColor = [System.Drawing.Color]::FromArgb(119, 239, 193)
$saveButton.PressedFillColor = [System.Drawing.Color]::FromArgb(81, 205, 151)
$saveButton.BorderWidth = 0
$saveButton.CornerRadius = 9
$saveButton.ForeColor = [System.Drawing.Color]::FromArgb(8, 27, 18)
$saveButton.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', [single]8.5, [System.Drawing.FontStyle]::Bold)
$saveButton.Add_Click({
    $name = $profileNameBox.Text.Trim()
    if (-not $name) { Set-Status '请给方案起个名字，例如「耳机」或「音箱」' $true; return }
    if (-not $outputCombo.SelectedItem -or -not $inputCombo.SelectedItem) { Set-Status '请同时选择输出和输入设备' $true; return }
    $existingProfile = @($script:Profiles | Where-Object { $_.Name -eq $name } | Select-Object -First 1)
    $existingModifiers = if ($existingProfile.Count) { [int]$existingProfile[0].HotkeyModifiers } else { 0 }
    $existingKey = if ($existingProfile.Count) { [int]$existingProfile[0].HotkeyKey } else { 0 }
    $script:Profiles = @($script:Profiles | Where-Object { $_.Name -ne $name })
    $script:Profiles += [PSCustomObject]@{
        Name = $name
        OutputId = $outputCombo.SelectedItem.Id
        OutputName = $outputCombo.SelectedItem.Name
        InputId = $inputCombo.SelectedItem.Id
        InputName = $inputCombo.SelectedItem.Name
        HotkeyModifiers = $existingModifiers
        HotkeyKey = $existingKey
    }
    Save-Profiles
    [void](Register-ProfileHotkeys)
    Render-Profiles
    Rebuild-TrayMenu
    $profileNameBox.Clear()
    Set-Status "已保存方案「$name」"
})
$createPanel.Controls.Add($saveButton)

$settingsPanel = New-Object AudioSwitchNative.AcrylicPanel
$settingsPanel.Location = New-Object System.Drawing.Point(24, 636)
$settingsPanel.Size = New-Object System.Drawing.Size(772, 46)
$settingsPanel.Anchor = 'Bottom,Left,Right'
$settingsPanel.CornerRadius = 12
$settingsPanel.FillColor = [System.Drawing.Color]::FromArgb(148, 39, 50, 61)
$settingsPanel.BorderColor = [System.Drawing.Color]::FromArgb(76, 78, 94, 109)
$form.Controls.Add($settingsPanel)
$settingsCaption = New-Label '运行设置' 7.5 'Bold'
$settingsCaption.Location = New-Object System.Drawing.Point(16, 15)
$settingsCaption.ForeColor = $colorMuted
$settingsPanel.Controls.Add($settingsCaption)

$startupCheck = New-Object AudioSwitchNative.ModernCheckBox
$startupCheck.Text = '随 Windows 启动'
$startupCheck.AutoSize = $false
$startupCheck.Size = New-Object System.Drawing.Size(142, 24)
$startupCheck.Location = New-Object System.Drawing.Point(94, 11)
$startupCheck.ForeColor = $colorTextSecondary
$startupCheck.Checked = Test-StartupRegistration
$startupCheck.Add_CheckedChanged({
    if ($script:InitializingSettings) { return }
    try {
        Set-StartupRegistration $startupCheck.Checked
        if ($startupCheck.Checked) { Set-Status '已开启随 Windows 启动；开机时会直接进入托盘' }
        else { Set-Status '已关闭随 Windows 启动' }
    } catch {
        $script:InitializingSettings = $true
        $startupCheck.Checked = -not $startupCheck.Checked
        $script:InitializingSettings = $false
        Set-Status "修改开机启动失败：$($_.Exception.Message)" $true
    }
})
$settingsPanel.Controls.Add($startupCheck)

$startMinimizedCheck = New-Object AudioSwitchNative.ModernCheckBox
$startMinimizedCheck.Text = '启动后直接隐藏到托盘'
$startMinimizedCheck.AutoSize = $false
$startMinimizedCheck.Size = New-Object System.Drawing.Size(190, 24)
$startMinimizedCheck.Location = New-Object System.Drawing.Point(250, 11)
$startMinimizedCheck.ForeColor = $colorTextSecondary
$startMinimizedCheck.Checked = [bool]$script:Settings.StartMinimized
$startMinimizedCheck.Add_CheckedChanged({
    if ($script:InitializingSettings) { return }
    $script:Settings.StartMinimized = [bool]$startMinimizedCheck.Checked
    Save-Settings
    if ($startMinimizedCheck.Checked) { Set-Status '已开启：以后启动后将直接进入托盘' }
    else { Set-Status '已关闭启动时隐藏' }
})
$settingsPanel.Controls.Add($startMinimizedCheck)
$script:InitializingSettings = $false

$savedLabel = New-Label '我的音频方案' 10.5 'Bold'
$savedLabel.Location = New-Object System.Drawing.Point(24, 318)
$savedLabel.ForeColor = $colorTextPrimary
$form.Controls.Add($savedLabel)
$profilesCountLabel = New-Label '0 个方案' 7.5
$profilesCountLabel.Location = New-Object System.Drawing.Point(730, 322)
$profilesCountLabel.Anchor = 'Top,Right'
$profilesCountLabel.ForeColor = $colorMuted
$form.Controls.Add($profilesCountLabel)

$profilesViewport = New-Object System.Windows.Forms.Panel
$profilesViewport.Location = New-Object System.Drawing.Point(24, 346)
$profilesViewport.Size = New-Object System.Drawing.Size(772, 210)
$profilesViewport.Anchor = 'Top,Bottom,Left,Right'
$profilesViewport.BackColor = $colorBackground
$form.Controls.Add($profilesViewport)

$profilePanel = New-Object System.Windows.Forms.FlowLayoutPanel
$profilePanel.Location = New-Object System.Drawing.Point(0, 0)
$profilePanel.Size = New-Object System.Drawing.Size(752, 210)
$profilePanel.AutoScroll = $false
$profilePanel.FlowDirection = 'TopDown'
$profilePanel.WrapContents = $false
$profilePanel.BackColor = $colorBackground
$profilesViewport.Controls.Add($profilePanel)

$profileScroll = New-Object AudioSwitchNative.ModernVScrollBar
$profileScroll.Location = New-Object System.Drawing.Point(758, 4)
$profileScroll.Size = New-Object System.Drawing.Size(10, 202)
$profileScroll.Anchor = 'Top,Bottom,Right'
$profileScroll.Visible = $false
$profileScroll.Add_ValueChanged({ $profilePanel.Top = -$profileScroll.Value })
$profilesViewport.Controls.Add($profileScroll)
$profilesViewport.Add_Resize({
    $profileScroll.Location = New-Object System.Drawing.Point(($profilesViewport.ClientSize.Width - 14), 4)
    $profileScroll.Height = [Math]::Max(30, $profilesViewport.ClientSize.Height - 8)
    Update-ProfileScroll
})
$profilePanel.Add_MouseWheel({
    param($sender, $eventArgs)
    $profileScroll.Value = $profileScroll.Value - [Math]::Sign($eventArgs.Delta) * 48
})
$profilesViewport.Add_MouseWheel({
    param($sender, $eventArgs)
    $profileScroll.Value = $profileScroll.Value - [Math]::Sign($eventArgs.Delta) * 48
})
$profilesViewport.Add_MouseEnter({ $profilesViewport.Focus() })

$noticePanel = New-Object AudioSwitchNative.AcrylicPanel
$noticePanel.Location = New-Object System.Drawing.Point(24, 568)
$noticePanel.Size = New-Object System.Drawing.Size(772, 54)
$noticePanel.Anchor = 'Bottom,Left,Right'
$noticePanel.CornerRadius = 12
$noticePanel.FillColor = [System.Drawing.Color]::FromArgb(152, 31, 55, 62)
$noticePanel.BorderColor = [System.Drawing.Color]::FromArgb(92, 67, 125, 141)
$form.Controls.Add($noticePanel)
$notice = New-Label '使用提示  ·  请在 Discord 与 Steam 中，将输入和输出设备设为 Default / 默认' 8.2 'Bold'
$notice.Location = New-Object System.Drawing.Point(16, 8)
$notice.ForeColor = [System.Drawing.Color]::FromArgb(151, 211, 235)
$noticePanel.Controls.Add($notice)
$notice2 = New-Label '通话中若没有立即更新，退出并重新进入语音频道即可。' 7.8
$notice2.Location = New-Object System.Drawing.Point(16, 30)
$notice2.ForeColor = [System.Drawing.Color]::FromArgb(173, 201, 214)
$noticePanel.Controls.Add($notice2)

$statusLabel = New-Label '准备就绪' 8
$statusLabel.Location = New-Object System.Drawing.Point(500, 15)
$statusLabel.Anchor = 'Top,Right'
$statusLabel.ForeColor = $colorAccent
$statusLabel.MaximumSize = New-Object System.Drawing.Size(250, 20)
$settingsPanel.Controls.Add($statusLabel)

$responsiveTimer = New-Object System.Windows.Forms.Timer
$responsiveTimer.Interval = 120
$responsiveTimer.Add_Tick({
    $responsiveTimer.Stop()
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal) {
        Update-ResponsiveLayout
        Render-Profiles
        $form.Invalidate($true)
        $form.Update()
    }
})
$currentPanel.Add_Resize({ Update-ResponsiveLayout })
$createPanel.Add_Resize({ Update-ResponsiveLayout })

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$trayMenu.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.8)
$trayMenu.Padding = New-Object System.Windows.Forms.Padding(8)
$trayMenu.MinimumSize = New-Object System.Drawing.Size(336, 0)
$trayMenu.ShowImageMargin = $false
$trayMenu.ShowCheckMargin = $true
$trayMenu.DropShadowEnabled = $true
$trayMenu.Opacity = 0.98
$trayMenu.Add_Opening({
    Apply-TrayMenuTheme
    Update-TrayMenuState
    $startupMenuItem = $trayMenu.Items.Find('startupToggle', $false) | Select-Object -First 1
    if ($startupMenuItem) { $startupMenuItem.Checked = Test-StartupRegistration }
})
$trayMenu.Add_Opened({
    [AudioSwitchNative.WindowEffects]::EnableSolidDark($trayMenu.Handle)
    [AudioSwitchNative.WindowEffects]::RoundControl($trayMenu, 14)
    $trayMenu.Invalidate($true)
    $trayMenu.Update()
})
$trayIcon = New-Object System.Windows.Forms.NotifyIcon
$trayIcon.Text = '音频一键切换'
$trayIcon.Icon = $appIcon
$trayIcon.ContextMenuStrip = $trayMenu
$trayIcon.Visible = $true
$trayIcon.Add_DoubleClick({ Show-MainWindow })

$script:HotkeyManager = New-Object AudioSwitchNative.GlobalHotkeyManager
$script:HotkeyManager.Add_HotkeyPressed({
    param($sender, $eventArgs)
    $targetProfile = @($script:Profiles | Where-Object { $_.Name -eq $eventArgs.ProfileName } | Select-Object -First 1)
    if ($targetProfile.Count) { Switch-Profile $targetProfile[0] }
})

$form.Add_FormClosing({
    param($sender, $eventArgs)
    if (-not $script:ClosingForReal -and $eventArgs.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $eventArgs.Cancel = $true
        Hide-ToTray $true
    }
})
$form.Add_Resize({
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        Hide-ToTray $false
    } else {
        Update-ResponsiveLayout
        $responsiveTimer.Stop()
        $responsiveTimer.Start()
    }
})
$form.Add_ResizeEnd({
    $responsiveTimer.Stop()
    Update-ResponsiveLayout
    Render-Profiles
    $form.Invalidate($true)
    $form.Update()
})
$form.Add_Shown({
    [AudioSwitchNative.WindowEffects]::EnableSolidDark($form.Handle)
    [AudioSwitchNative.WindowEffects]::ApplyIdentityAndIcon($form, $appIcon)
    Update-ResponsiveLayout
    if ($script:StartHidden -or [bool]$script:Settings.StartMinimized) {
        $script:StartHidden = $false
        Hide-ToTray $false
    }
})
$form.Add_FormClosed({
    $responsiveTimer.Stop()
    $responsiveTimer.Dispose()
    if ($null -ne $script:HotkeyManager) { $script:HotkeyManager.Dispose(); $script:HotkeyManager = $null }
    $trayIcon.Visible = $false
    $trayIcon.Dispose()
    if ($script:OwnsAppIcon) { $appIcon.Dispose() }
})

Load-Profiles
[void](Register-ProfileHotkeys)
Render-Profiles
Rebuild-TrayMenu
Refresh-Devices
if (-not [string]::IsNullOrWhiteSpace($TrayMenuPreviewPath)) {
    $script:StartHidden = $false
    $script:Settings.StartMinimized = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Location = New-Object System.Drawing.Point(-32000, -32000)
    $form.ShowInTaskbar = $false
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $trayMenu.Show($form, (New-Object System.Drawing.Point(10, 10)))
    [System.Windows.Forms.Application]::DoEvents()
    if ($TrayMenuPreviewDark) {
        $trayMenu.Renderer = [AudioSwitchNative.ModernMenuRenderer]::new($false)
        $trayMenu.BackColor = [System.Drawing.Color]::FromArgb(25, 32, 41)
        $trayMenu.ForeColor = [System.Drawing.Color]::FromArgb(241, 245, 248)
        $script:TrayHeaderPanel.BackColor = [System.Drawing.Color]::FromArgb(39, 48, 58)
        $script:TrayHeaderBrand.ForeColor = [System.Drawing.Color]::FromArgb(241, 245, 248)
        foreach ($menuItem in $trayMenu.Items) {
            if ($menuItem.Name -eq 'exitApp') { $menuItem.ForeColor = [System.Drawing.Color]::FromArgb(255, 107, 120) }
            elseif ($menuItem.Name -ne 'menuHeader') { $menuItem.ForeColor = [System.Drawing.Color]::FromArgb(241, 245, 248) }
        }
    } else {
        Apply-TrayMenuTheme
    }
    Update-TrayMenuState
    [AudioSwitchNative.WindowEffects]::RoundControl($trayMenu, 14)
    $trayMenu.Invalidate($true)
    $trayMenu.Update()
    $menuPreview = New-Object System.Drawing.Bitmap($trayMenu.Width, $trayMenu.Height)
    $trayMenu.DrawToBitmap($menuPreview, (New-Object System.Drawing.Rectangle(0, 0, $trayMenu.Width, $trayMenu.Height)))
    $menuPreview.Save($TrayMenuPreviewPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $menuPreview.Dispose()
    $trayMenu.Close()
    $form.Hide()
    if ($null -ne $script:HotkeyManager) { $script:HotkeyManager.Dispose(); $script:HotkeyManager = $null }
    $trayIcon.Visible = $false
    $trayIcon.Dispose()
    if ($script:OwnsAppIcon) { $appIcon.Dispose() }
    $form.Dispose()
    exit 0
}
if (-not [string]::IsNullOrWhiteSpace($HotkeyPreviewPath)) {
    $previewProfile = @($script:Profiles | Select-Object -First 1)
    if (-not $previewProfile.Count) {
        $previewProfile = @([PSCustomObject]@{ Name = '示例方案'; HotkeyModifiers = 0; HotkeyKey = 0 })
    }
    Show-HotkeyEditor $previewProfile[0] $HotkeyPreviewPath
    if ($null -ne $script:HotkeyManager) { $script:HotkeyManager.Dispose(); $script:HotkeyManager = $null }
    $trayIcon.Visible = $false
    $trayIcon.Dispose()
    if ($script:OwnsAppIcon) { $appIcon.Dispose() }
    $form.Dispose()
    exit 0
}
if (-not [string]::IsNullOrWhiteSpace($UiPreviewPath)) {
    $script:StartHidden = $false
    $script:Settings.StartMinimized = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Location = New-Object System.Drawing.Point(-32000, -32000)
    $form.ShowInTaskbar = $false
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    if ($UiPreviewWidth -gt 0 -and $UiPreviewHeight -gt 0) {
        $form.ClientSize = New-Object System.Drawing.Size($UiPreviewWidth, $UiPreviewHeight)
        [System.Windows.Forms.Application]::DoEvents()
    }
    Update-ResponsiveLayout
    Render-Profiles
    $form.Invalidate($true)
    $form.Update()
    $form.PerformLayout()
    $preview = New-Object System.Drawing.Bitmap($form.ClientSize.Width, $form.ClientSize.Height)
    $form.DrawToBitmap($preview, (New-Object System.Drawing.Rectangle(0, 0, $form.ClientSize.Width, $form.ClientSize.Height)))
    $preview.Save($UiPreviewPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $preview.Dispose()
    $form.Hide()
    if ($null -ne $script:HotkeyManager) { $script:HotkeyManager.Dispose(); $script:HotkeyManager = $null }
    $trayIcon.Visible = $false
    $trayIcon.Dispose()
    if ($script:OwnsAppIcon) { $appIcon.Dispose() }
    $form.Dispose()
    exit 0
}
[System.Windows.Forms.Application]::Run($form)
