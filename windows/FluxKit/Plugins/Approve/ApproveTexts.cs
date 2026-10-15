namespace FluxKit;

// The texts of approvals. They are the texts of ApproveTexts.swift of the Mac
// app with these changes: "this computer" for "this Mac", Windows Hello for
// Touch ID, and the TPM for the Secure Enclave. The texts that go to the
// computer as an error also show on the computer, after the words "the phone
// could not make the key".
public static class ApproveTexts
{
    // The name of the user check.
    public const string UserCheck = "Windows Hello";

    public const string DeviceNoun = "this computer";
    const string Device = "This computer";

    // The command that starts approvals on the computer.
    public const string SetupCommand = "sudo flux-cli approve setup";

    public const string NotValid = "The request is not valid";

    // The summary of a request that is not valid, in the history.
    public const string NotValidSummary = "A request that is not valid";

    public const string ClockSkew = $"The clocks of {DeviceNoun} and the computer differ by more than 10 minutes";
    public const string NoKey = $"{Device} has no key for the computer. Run: sudo flux-cli approve enroll";
    public const string AnotherOpen = $"Another request is open on {DeviceNoun}";
    public const string NotConnected = "The computer is not connected.";

    public static string EnrollTitle(string host) => $"Enroll {DeviceNoun} on {host}?";

    public static string EnrollDetail(string computer) =>
        $"Flux makes a key for {computer} in the TPM of {DeviceNoun}. Each approval then needs {UserCheck}.";

    public static string EnrollReplaces(string computer) => $"This replaces the current approval key for {computer}.";

    public static string EnrollQuestion(string user, string host) => $"Use {DeviceNoun} to approve sudo for user {user} on host {host}?";

    // The reason that the prompt of the user check shows.
    public static string EnrollReason(string user, string host) => $"enroll {DeviceNoun} to approve sudo for {user} on {host}";

    public static string ApproveReason(ApproveRequest r) => $"approve {r.Service} for {r.User} on {r.Host}";

    // The title of the notification of a request.
    public static string Title(ApproveRequest r) => r.Kind == ApproveKind.Approve
        ? $"Approve {r.Service} on {r.Host}?"
        : EnrollTitle(r.Host);

    public static string NotReached(string computer, bool oldKeyStays) =>
        $"The new key did not reach {computer}." + (oldKeyStays ? " The old key stays." : "");

    public const string KeyInvalid = $"{UserCheck} on {DeviceNoun} changed. Enroll again with: sudo flux-cli approve enroll";
    public const string SaveFailed = $"{Device} could not save its approval key.";
    public const string NotSetUp = $"Set up {UserCheck} in Settings first.";
    public const string LockedOut = $"{UserCheck} is locked. Unlock {DeviceNoun} with the password first.";
    public const string Unavailable = $"{UserCheck} is not available on {DeviceNoun}.";
    public const string NotRecognized = $"{UserCheck} did not recognize you.";
    public const string DeviceLocked = $"{Device} is locked, so it cannot use its approval key.";
    public const string MakeFailed = $"{Device} could not make its approval key.";
    public const string UseFailed = $"{Device} could not use its approval key.";

    // Why a computer without a TPM cannot approve.
    public const string NoSecureHardware = $"{Device} has no TPM, so it cannot keep an approval key.";

    // The hint while the user check runs.
    public const string Working = $"Confirm with {UserCheck}.";

    // The texts of the prompt. ApprovePrompt.swift of the Mac app has them.
    public const string ApproveHint = "Approve only if you just typed the command.";
    public const string ApproveButton = "Approve";
    public const string EnrollButton = "Enroll";
    public const string DenyButton = "Deny";

    public static string Expires(int seconds) => $"Expires in {seconds} s";

    public const string EnrolledTitle = "Compare the key code";

    // The terminal does not show the code. It asks the user to type it, see
    // docs/approvals.md.
    public const string EnrolledHint = "Type this code in the terminal, all 16 characters.";

    public const string FailedHint = "The computer asks for the password.";

    // The texts of the approval card of a computer. ApproveSection.swift of
    // the Mac app has them.
    public const string NotSetUpStatus = "Not set up";
    public const string EnrolledStatus = "Enrolled";

    public static string Setup(string computer) =>
        $"Approve sudo, polkit, and the lock screen of {computer} with {UserCheck} on {DeviceNoun}. Run this command on {computer}, then select Enroll on {DeviceNoun}:";

    public static string EnrolledFor(string user, string host) => $"Approves sudo, polkit, and the lock screen for {user} on {host}.";

    public static string EnrollAgain(string computer) => $"To enroll again, run sudo flux-cli approve enroll on {computer}.";

    public static string RemoveKeyQuestion(string computer) => $"Remove the approval key for {computer}?";

    public static string RemoveKeyDetail(string computer) =>
        $"{Device} can no longer approve requests of {computer}. Run sudo flux-cli approve remove on {computer} to delete its key file too.";

    // The sentence that the unpair dialog adds when this computer has a key
    // for the computer. AppModel.swift of the Mac app has it.
    public static string UnpairNote(string computer) =>
        $"{Device} deletes its approval key for {computer}. The key file on the computer stays until you run: sudo flux-cli approve remove";

    // The text of a problem of the user check, or null when it works.
    public static string? Problem(ApproveUserCheck check) => check switch
    {
        ApproveUserCheck.Ready => null,
        ApproveUserCheck.NotSetUp => NotSetUp,
        ApproveUserCheck.LockedOut => LockedOut,
        _ => Unavailable,
    };

    // The text of a failed signature. kind tells whether the key was new.
    public static string Failure(ApproveKeyError error, ApproveKind kind) => error switch
    {
        ApproveKeyError.NotRecognized => NotRecognized,
        ApproveKeyError.LockedOut => LockedOut,
        ApproveKeyError.NotSetUp => NotSetUp,
        ApproveKeyError.Unavailable => Unavailable,
        ApproveKeyError.KeyInvalid => KeyInvalid,
        ApproveKeyError.DeviceLocked => DeviceLocked,
        _ => kind == ApproveKind.Enroll ? MakeFailed : UseFailed,
    };
}
