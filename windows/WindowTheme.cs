using System.Runtime.InteropServices;
using System.Text.Json;

namespace SapiensDesktop;

internal sealed class WindowTheme
{
    (bool Dark, int Background, int Foreground)? applied;

    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);

    internal void Sync(IntPtr window, JsonElement message)
    {
        // File-picker messages have no theme. Only the trusted shell supplies this palette.
        if (!message.TryGetProperty("dark", out var mode) || mode.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) return;
        bool dark = mode.GetBoolean();
        int Palette(string name, Color fallback)
        {
            if (message.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String &&
                System.Text.RegularExpressions.Regex.IsMatch(value.GetString()!, "^#[0-9a-fA-F]{3}([0-9a-fA-F]{3})?$"))
                return ColorTranslator.ToWin32(ColorTranslator.FromHtml(value.GetString()!));
            return ColorTranslator.ToWin32(fallback);
        }
        int background = Palette("captionBackground", dark ? Color.FromArgb(23, 23, 23) : Color.FromArgb(246, 246, 246));
        int foreground = Palette("foreground", dark ? Color.FromArgb(236, 236, 236) : Color.FromArgb(32, 32, 32));
        if (applied == (dark, background, foreground)) return;
        int enabled = dark ? 1 : 0;
        // Windows 10 used attribute 19 before adopting DWMWA_USE_IMMERSIVE_DARK_MODE (20).
        if (DwmSetWindowAttribute(window, 20, ref enabled, sizeof(int)) < 0)
            DwmSetWindowAttribute(window, 19, ref enabled, sizeof(int));
        if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
        {
            // Windows 11 can match the app header exactly, independent of the OS theme.
            DwmSetWindowAttribute(window, 35, ref background, sizeof(int)); // DWMWA_CAPTION_COLOR
            DwmSetWindowAttribute(window, 36, ref foreground, sizeof(int)); // DWMWA_TEXT_COLOR
        }
        applied = (dark, background, foreground);
    }
}
