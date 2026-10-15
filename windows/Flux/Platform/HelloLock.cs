using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using FluxKit;
using Microsoft.Win32;
using Windows.Security.Credentials.UI;

namespace Flux;

// Asks for Windows Hello before input goes to a computer. Remote keys can
// make the computer run commands, so the person at this computer confirms
// first. A confirmation stays valid for 5 minutes, like the phone lock on
// Android. It ends before that when this computer sleeps, the session
// locks, or another user takes the session. Without Windows Hello, the
// check asks for nothing, as the Mac falls back to its password.
// ReplyLock.swift of the Mac app has the same rules.
public static class HelloLock
{
    static readonly long ValidFor = (long)TimeSpan.FromMinutes(5).TotalMilliseconds;

    // The end of the confirmation on the clock of Environment.TickCount64,
    // which also counts the time while this computer sleeps. 0 while no
    // confirmation is valid.
    static long until;
    static bool watching;

    public static bool IsUnlocked
    {
        get
        {
            var end = Interlocked.Read(ref until);
            return end > 0 && Environment.TickCount64 < end;
        }
    }

    // Ends the confirmation, so that the next check asks again.
    public static void Lock() => Interlocked.Exchange(ref until, 0);

    // Ends the confirmation when this computer sleeps, the session locks,
    // or the user session changes. Call it once at the start.
    public static void Watch()
    {
        if (watching)
        {
            return;
        }
        watching = true;
        SystemEvents.SessionSwitch += (_, e) =>
        {
            if (e.Reason is SessionSwitchReason.SessionLock or SessionSwitchReason.SessionLogoff or
                SessionSwitchReason.ConsoleDisconnect or SessionSwitchReason.RemoteDisconnect)
            {
                Lock();
            }
        };
        SystemEvents.PowerModeChanged += (_, e) =>
        {
            if (e.Mode == PowerModes.Suspend)
            {
                Lock();
            }
        };
    }

    // Runs action after the check, or at once while a confirmation is
    // valid. failed gets a message when the check fails. A cancel calls
    // neither. reason starts with a verb, for example "control the pointer
    // and the keys of omarchy".
    public static void Run(string reason, Action action, Action<string> failed) => _ = RunAsync(reason, action, failed);

    static async Task RunAsync(string reason, Action action, Action<string> failed)
    {
        if (IsUnlocked)
        {
            action();
            return;
        }
        try
        {
            var availability = await UserConsentVerifier.CheckAvailabilityAsync();
            switch (availability)
            {
                case UserConsentVerifierAvailability.DeviceNotPresent:
                case UserConsentVerifierAvailability.NotConfiguredForUser:
                    // Windows Hello is not set up. The Mac asks for its
                    // password then, and Windows has no such check, so the
                    // user goes through.
                    FluxLog.Info("app", "Windows Hello is not set up, so the check asks for nothing");
                    action();
                    return;
                case UserConsentVerifierAvailability.DisabledByPolicy:
                    failed("A policy of this computer turns Windows Hello off");
                    return;
                case UserConsentVerifierAvailability.DeviceBusy:
                    failed("Windows Hello is busy. Try again.");
                    return;
            }
            var message = $"Flux asks for Windows Hello to {reason}.";
            var result = Owner() is { } window && window != IntPtr.Zero
                ? await UserConsentVerifierInterop.RequestVerificationForWindowAsync(window, message)
                : await UserConsentVerifier.RequestVerificationAsync(message);
            switch (result)
            {
                case UserConsentVerificationResult.Verified:
                    Interlocked.Exchange(ref until, Environment.TickCount64 + ValidFor);
                    action();
                    break;
                case UserConsentVerificationResult.DeviceNotPresent:
                case UserConsentVerificationResult.NotConfiguredForUser:
                    action();
                    break;
                case UserConsentVerificationResult.Canceled:
                    break;
                case UserConsentVerificationResult.RetriesExhausted:
                    failed("Windows Hello did not confirm you. Try again later.");
                    break;
                case UserConsentVerificationResult.DeviceBusy:
                    failed("Windows Hello is busy. Try again.");
                    break;
                default:
                    failed("Windows Hello did not confirm you");
                    break;
            }
        }
        catch (Exception e) when (e is COMException or InvalidOperationException or UnauthorizedAccessException or ArgumentException)
        {
            FluxLog.Error("app", $"Windows Hello failed: {e.Message}");
            failed("Windows Hello does not answer");
        }
    }

    // The window that the dialog of Windows Hello belongs to: the active
    // window of Flux, or the main window.
    static IntPtr Owner()
    {
        var app = Application.Current;
        if (app is null)
        {
            return IntPtr.Zero;
        }
        var window = app.Windows.OfType<Window>().FirstOrDefault(w => w.IsActive) ?? app.MainWindow;
        return window is null ? IntPtr.Zero : new WindowInteropHelper(window).EnsureHandle();
    }
}
