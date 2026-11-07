// §122 无界面替身：只在 AOT 版（lobby\aot\PBZLobbyAot.csproj → pbz_lobby.dll，在游戏进程里跑）编译，build.bat 的 exe 不用它。
// NativeAOT 不支持 WinForms，但联机程序的逻辑都写在旧窗口 MainForm 里（定时器驱动、控件存着输入框的值）。
// 这里按 MainForm 用到的那一小部分 WinForms 写了同名的无界面类型：控件只存值不画；定时器和 BeginInvoke 都排进
// 一个专门的线程（Application.Run 的那个线程）按顺序执行——和 WinForms 一样单线程，所以 MainForm 的代码不用改。
// 规矩（游戏进程里抛出没接住的异常会直接结束游戏）：这里每个回调都包 try/catch，出错交给 Application.ThreadException 记日志，循环继续。
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

namespace System.Drawing
{
    public enum FontStyle { Regular = 0, Bold = 1, Italic = 2, Underline = 4, Strikeout = 8 }

    public class Font
    {
        public Font(string family, float size) { }
        public Font(string family, float size, FontStyle style) { }
        public Font(Font prototype, FontStyle style) { }
    }

    public enum ContentAlignment { TopLeft = 1, TopCenter = 2, TopRight = 4, MiddleLeft = 16, MiddleCenter = 32, MiddleRight = 64, BottomLeft = 256, BottomCenter = 512, BottomRight = 1024 }
}

namespace System.Windows.Forms
{
    public enum ComboBoxStyle { Simple, DropDown, DropDownList }
    public enum FormBorderStyle { None, FixedSingle, Fixed3D, FixedDialog, Sizable, FixedToolWindow, SizableToolWindow }
    public enum FormStartPosition { Manual, CenterScreen, WindowsDefaultLocation, WindowsDefaultBounds, CenterParent }
    public enum ScrollBars { None, Horizontal, Vertical, Both }
    public enum BorderStyle { None, FixedSingle, Fixed3D }
    public enum DialogResult { None, OK, Cancel }
    public enum CloseReason { None, WindowsShutDown, MdiFormClosing, UserClosing, TaskManagerClosing, FormOwnerClosing, ApplicationExitCall }
    public enum FormWindowState { Normal, Minimized, Maximized }

    public class FormClosingEventArgs : EventArgs { public bool Cancel; public CloseReason CloseReason = CloseReason.ApplicationExitCall; }
    public delegate void FormClosingEventHandler(object sender, FormClosingEventArgs e);
    public class FormClosedEventArgs : EventArgs { }
    public delegate void FormClosedEventHandler(object sender, FormClosedEventArgs e);

    public class Control
    {
        static long nextHandle = 1;
        string text = "";
        public event EventHandler TextChanged, Click, DoubleClick, Leave;
        public string Text { get { return text; } set { value = value ?? ""; if (value == text) return; text = value; Fire(TextChanged); } }
        public bool Visible { get; set; } = true;
        public bool Enabled { get; set; } = true;
        public bool TabStop { get; set; } = true;
        public int Left { get; set; }
        public int Top { get; set; }
        public int Width { get; set; }
        public int Height { get; set; }
        public System.Drawing.Font Font { get; set; }
        public System.Drawing.Color ForeColor { get; set; }
        public System.Drawing.Color BackColor { get; set; }
        public object Tag { get; set; }
        public ControlCollection Controls { get; }
        IntPtr handle;
        public IntPtr Handle { get { if (handle == IntPtr.Zero) handle = (IntPtr)Interlocked.Increment(ref nextHandle); return handle; } }
        public bool IsHandleCreated { get { return handle != IntPtr.Zero; } }
        public bool IsDisposed { get; protected set; }
        public Control() { Controls = new ControlCollection(); }
        public void SetBounds(int x, int y, int w, int h) { Left = x; Top = y; Width = w; Height = h; }
        public void Show() { Visible = true; }
        public void Hide() { Visible = false; }
        public bool Focus() { return true; }
        public void Invalidate() { }
        public void Refresh() { }
        public void SuspendLayout() { }
        public void ResumeLayout() { }
        public void ResumeLayout(bool performLayout) { }
        public IAsyncResult BeginInvoke(Action method) { Application.Post(method); return null; }
        public bool InvokeRequired { get { return !Application.OnLoopThread; } }
        protected void Fire(EventHandler h) { if (h != null) Application.Guard(() => h(this, EventArgs.Empty)); }
        public void PerformClick() { Fire(Click); }
    }

    public class ControlCollection : List<Control> { }

    public class Label : Control
    {
        public System.Drawing.ContentAlignment TextAlign { get; set; }
        public bool AutoEllipsis { get; set; }
        public bool AutoSize { get; set; }
        public BorderStyle BorderStyle { get; set; }
    }

    public class Button : Control { }

    public class TextBox : Control
    {
        public bool ReadOnly { get; set; }
        public bool Multiline { get; set; }
        public bool WordWrap { get; set; }
        public bool UseSystemPasswordChar { get; set; }
        public ScrollBars ScrollBars { get; set; }
        public BorderStyle BorderStyle { get; set; }
        public int MaxLength { get; set; }
        public void SelectAll() { }
    }

    public class CheckBox : Control
    {
        bool isChecked;
        public event EventHandler CheckedChanged;
        public bool Checked { get { return isChecked; } set { if (value == isChecked) return; isChecked = value; Fire(CheckedChanged); } }
        public bool AutoSize { get; set; }
    }

    public class ObjectCollection : List<object>
    {
        readonly ListControl owner;
        public ObjectCollection(ListControl owner) { this.owner = owner; }
        public new void Clear() { base.Clear(); owner.ResetSelection(); }
    }

    public class ListControl : Control
    {
        int sel = -1;
        public event EventHandler SelectedIndexChanged;
        public ObjectCollection Items { get; }
        public ListControl() { Items = new ObjectCollection(this); }
        public int SelectedIndex
        {
            get { return sel; }
            set
            {
                if (value < -1 || value >= Items.Count) throw new ArgumentOutOfRangeException("SelectedIndex");
                if (value == sel) return;
                sel = value;
                if (value >= 0) Text = Convert.ToString(Items[value]);
                Fire(SelectedIndexChanged);
            }
        }
        public object SelectedItem { get { return sel >= 0 && sel < Items.Count ? Items[sel] : null; } }
        internal void ResetSelection() { if (sel != -1) { sel = -1; Fire(SelectedIndexChanged); } }
        public void BeginUpdate() { }
        public void EndUpdate() { }
    }

    public class ComboBox : ListControl
    {
        public ComboBoxStyle DropDownStyle { get; set; }
        public bool DroppedDown { get; set; }
    }

    public class ListBox : ListControl
    {
        public bool IntegralHeight { get; set; }
    }

    public class Form : Control
    {
        public event FormClosingEventHandler FormClosing;
        public event FormClosedEventHandler FormClosed;
        public FormBorderStyle FormBorderStyle { get; set; }
        public FormStartPosition StartPosition { get; set; }
        public bool MaximizeBox { get; set; }
        public bool MinimizeBox { get; set; }
        public bool ShowInTaskbar { get; set; }
        public bool TopMost { get; set; }
        public System.Drawing.Size ClientSize { get; set; }
        public event EventHandler Shown;
        public Control ActiveControl { get; set; }
        public FormWindowState WindowState { get; set; }
        public Form() { Visible = false; }
        bool shownOnce;
        public new void Show() { Visible = true; if (!shownOnce) { shownOnce = true; Fire(Shown); } }
        public void Activate() { }
        public void BringToFront() { }
        bool closed;
        public void Close()
        {
            if (closed) return;
            var e = new FormClosingEventArgs();
            var h = FormClosing;
            if (h != null) Application.Guard(() => h(this, e));
            if (e.Cancel) return;
            closed = true;
            Visible = false;
            IsDisposed = true;
            var c = FormClosed;
            if (c != null) Application.Guard(() => c(this, new FormClosedEventArgs()));
        }
    }

    public static class MessageBox
    {
        public static DialogResult Show(string text) { Application.Report("MessageBox: " + text); return DialogResult.OK; }
        public static DialogResult Show(string text, string caption) { return Show(caption + ": " + text); }
        public static DialogResult Show(Control owner, string text, string caption) { return Show(text, caption); }
    }

    public class Timer
    {
        public event EventHandler Tick;
        int interval = 100;
        public int Interval { get { return interval; } set { interval = Math.Max(1, value); } }
        public bool Enabled { get { return Application.IsTimerOn(this); } set { if (value) Start(); else Stop(); } }
        public void Start() { Application.TimerOn(this); }
        public void Stop() { Application.TimerOff(this); }
        internal void Fire() { var h = Tick; if (h != null) h(this, EventArgs.Empty); }
    }

    public class ApplicationContext
    {
        public void ExitThread() { Application.ExitThread(); }
    }

    // 单线程的"消息循环"：Run 在调用它的线程上跑，定时器到点、Post 进来的委托按顺序执行
    public static class Application
    {
        static readonly object gate = new object();
        static readonly Queue<Action> posted = new Queue<Action>();
        static readonly Dictionary<Timer, long> due = new Dictionary<Timer, long>();   // 定时器 → 下次到点（Environment.TickCount64）
        static readonly AutoResetEvent wake = new AutoResetEvent(false);
        static volatile bool exit;
        [ThreadStatic] static bool onLoop;

        public static event Action<Exception> ThreadException;   // 回调里没接住的异常（AotEntry 记进日志）
        public static event Action<string> Notice;
        public static bool OnLoopThread { get { return onLoop; } }

        public static void EnableVisualStyles() { }
        public static void SetCompatibleTextRenderingDefault(bool v) { }
        public static void ExitThread() { exit = true; wake.Set(); }
        public static void Exit() { ExitThread(); }

        internal static void Report(string m) { var n = Notice; if (n != null) try { n(m); } catch (Exception) { } }

        internal static void Guard(Action a)
        {
            try { a(); }
            catch (Exception ex) { var h = ThreadException; if (h != null) try { h(ex); } catch (Exception) { } }
        }

        public static void Post(Action a) { lock (gate) posted.Enqueue(a); wake.Set(); }

        internal static void TimerOn(Timer t) { lock (gate) due[t] = Environment.TickCount64 + t.Interval; wake.Set(); }
        internal static void TimerOff(Timer t) { lock (gate) due.Remove(t); }
        internal static bool IsTimerOn(Timer t) { lock (gate) return due.ContainsKey(t); }

        public static void Run(ApplicationContext ctx)
        {
            onLoop = true;
            exit = false;
            var fire = new List<Timer>();
            while (!exit)
            {
                Action a = null;
                lock (gate) if (posted.Count > 0) a = posted.Dequeue();
                if (a != null) { Guard(a); continue; }
                long now = Environment.TickCount64, next = now + 50;
                fire.Clear();
                lock (gate)
                {
                    foreach (var kv in due)
                    {
                        if (kv.Value <= now) fire.Add(kv.Key);
                        else if (kv.Value < next) next = kv.Value;
                    }
                    foreach (var t in fire) due[t] = now + t.Interval;   // 和 WinForms 一样：到点后从现在起再等一个间隔
                }
                foreach (var t in fire)
                {
                    if (exit) break;
                    if (IsTimerOn(t)) Guard(t.Fire);
                }
                if (fire.Count == 0) wake.WaitOne((int)Math.Max(1, next - now));
            }
            lock (gate) { due.Clear(); posted.Clear(); }
            onLoop = false;
        }
    }

    // 剪贴板：直接调 Windows API（WinForms 的 Clipboard 在 NativeAOT 里没有）
    public static class Clipboard
    {
        [DllImport("user32", SetLastError = true)] static extern bool OpenClipboard(IntPtr owner);
        [DllImport("user32")] static extern bool CloseClipboard();
        [DllImport("user32")] static extern bool EmptyClipboard();
        [DllImport("user32")] static extern bool IsClipboardFormatAvailable(uint format);
        [DllImport("user32")] static extern IntPtr GetClipboardData(uint format);
        [DllImport("user32")] static extern IntPtr SetClipboardData(uint format, IntPtr mem);
        [DllImport("kernel32")] static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
        [DllImport("kernel32")] static extern IntPtr GlobalLock(IntPtr mem);
        [DllImport("kernel32")] static extern bool GlobalUnlock(IntPtr mem);
        [DllImport("kernel32")] static extern IntPtr GlobalFree(IntPtr mem);
        const uint CF_UNICODETEXT = 13, GMEM_MOVEABLE = 2;

        static bool Open()
        {
            for (int i = 0; i < 10; i++)          // 别的程序正开着剪贴板时稍等再试
            {
                if (OpenClipboard(IntPtr.Zero)) return true;
                Thread.Sleep(10);
            }
            return false;
        }

        public static bool ContainsText() { return IsClipboardFormatAvailable(CF_UNICODETEXT); }

        public static string GetText()
        {
            if (!Open()) return "";
            try
            {
                var h = GetClipboardData(CF_UNICODETEXT);
                if (h == IntPtr.Zero) return "";
                var p = GlobalLock(h);
                if (p == IntPtr.Zero) return "";
                try { return Marshal.PtrToStringUni(p) ?? ""; }
                finally { GlobalUnlock(h); }
            }
            finally { CloseClipboard(); }
        }

        public static void SetText(string text)
        {
            text = text ?? "";
            if (!Open()) throw new InvalidOperationException("clipboard busy");
            try
            {
                EmptyClipboard();
                int bytes = (text.Length + 1) * 2;
                var h = GlobalAlloc(GMEM_MOVEABLE, (UIntPtr)bytes);
                if (h == IntPtr.Zero) throw new OutOfMemoryException();
                var p = GlobalLock(h);
                Marshal.Copy(text.ToCharArray(), 0, p, text.Length);
                Marshal.WriteInt16(p, text.Length * 2, 0);
                GlobalUnlock(h);
                if (SetClipboardData(CF_UNICODETEXT, h) == IntPtr.Zero) { GlobalFree(h); throw new InvalidOperationException("SetClipboardData failed"); }
            }
            finally { CloseClipboard(); }
        }
    }
}
