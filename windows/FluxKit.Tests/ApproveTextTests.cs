using FluxKit;

namespace FluxKit.Tests;

// ApproveTextTests.swift of the Mac app: the Mac texts with "this computer"
// for "this Mac", Windows Hello for Touch ID, and the TPM for the Secure
// Enclave.
public class ApproveTextTests
{
    [Fact]
    public void TheTextsOfThisComputer()
    {
        Assert.Equal("this computer", ApproveTexts.DeviceNoun);
        Assert.Equal("Windows Hello", ApproveTexts.UserCheck);
        Assert.Equal("The clocks of this computer and the computer differ by more than 10 minutes", ApproveTexts.ClockSkew);
        Assert.Equal("This computer has no key for the computer. Run: sudo flux-cli approve enroll", ApproveTexts.NoKey);
        Assert.Equal("Another request is open on this computer", ApproveTexts.AnotherOpen);
        Assert.Equal("Enroll this computer on omarchy-xps?", ApproveTexts.EnrollTitle("omarchy-xps"));
        Assert.Equal("Flux makes a key for roger in the TPM of this computer. Each approval then needs Windows Hello.", ApproveTexts.EnrollDetail("roger"));
        Assert.Equal("This replaces the current approval key for roger.", ApproveTexts.EnrollReplaces("roger"));
        Assert.Equal("Use this computer to approve sudo for user alice on host omarchy-xps?", ApproveTexts.EnrollQuestion("alice", "omarchy-xps"));
        Assert.Equal("enroll this computer to approve sudo for alice on omarchy-xps", ApproveTexts.EnrollReason("alice", "omarchy-xps"));
        Assert.Equal("approve sudo for alice on omarchy-xps", ApproveTexts.ApproveReason(ApproveMessageTests.Request));
        Assert.Equal("Windows Hello on this computer changed. Enroll again with: sudo flux-cli approve enroll", ApproveTexts.KeyInvalid);
        Assert.Equal("This computer could not save its approval key.", ApproveTexts.SaveFailed);
        Assert.Equal("Set up Windows Hello in Settings first.", ApproveTexts.NotSetUp);
        Assert.Equal("Windows Hello is locked. Unlock this computer with the password first.", ApproveTexts.LockedOut);
        Assert.Equal("Windows Hello is not available on this computer.", ApproveTexts.Unavailable);
        Assert.Equal("Windows Hello did not recognize you.", ApproveTexts.NotRecognized);
        Assert.Equal("This computer is locked, so it cannot use its approval key.", ApproveTexts.DeviceLocked);
        Assert.Equal("This computer could not make its approval key.", ApproveTexts.MakeFailed);
        Assert.Equal("This computer could not use its approval key.", ApproveTexts.UseFailed);
        Assert.Equal("This computer has no TPM, so it cannot keep an approval key.", ApproveTexts.NoSecureHardware);
        Assert.Equal("Confirm with Windows Hello.", ApproveTexts.Working);
        Assert.Equal("The new key did not reach roger. The old key stays.", ApproveTexts.NotReached("roger", true));
        Assert.Equal("The new key did not reach roger.", ApproveTexts.NotReached("roger", false));
    }

    [Fact]
    public void TheTitlesOfTheNotification()
    {
        Assert.Equal("Approve sudo on omarchy-xps?", ApproveTexts.Title(ApproveMessageTests.Request));
        Assert.Equal("Enroll this computer on omarchy-xps?", ApproveTexts.Title(ApproveMessageTests.Request with { Kind = ApproveKind.Enroll }));
    }

    // The terminal asks for the code, so the prompt does not tell the user to
    // type y, see docs/approvals.md.
    [Fact]
    public void ThePromptAsksForTheCode()
    {
        Assert.Equal("Type this code in the terminal, all 16 characters.", ApproveTexts.EnrolledHint);
        Assert.DoesNotContain("type y", ApproveTexts.EnrolledHint);
        Assert.Equal("Expires in 7 s", ApproveTexts.Expires(7));
        Assert.Equal("Approve only if you just typed the command.", ApproveTexts.ApproveHint);
        Assert.Equal("The computer asks for the password.", ApproveTexts.FailedHint);
    }

    [Fact]
    public void TheUnpairDialogNamesTheKey()
    {
        Assert.Equal("This computer deletes its approval key for roger. The key file on the computer stays until you run: sudo flux-cli approve remove",
            ApproveTexts.UnpairNote("roger"));
        Assert.Equal("Remove the approval key for roger?", ApproveTexts.RemoveKeyQuestion("roger"));
    }

    // Each failure of the platform has its text. An unknown failure names
    // the step.
    [Fact]
    public void FailuresHaveTexts()
    {
        Assert.Equal(ApproveTexts.NotRecognized, ApproveTexts.Failure(ApproveKeyError.NotRecognized, ApproveKind.Approve));
        Assert.Equal(ApproveTexts.LockedOut, ApproveTexts.Failure(ApproveKeyError.LockedOut, ApproveKind.Approve));
        Assert.Equal(ApproveTexts.NotSetUp, ApproveTexts.Failure(ApproveKeyError.NotSetUp, ApproveKind.Enroll));
        Assert.Equal(ApproveTexts.Unavailable, ApproveTexts.Failure(ApproveKeyError.Unavailable, ApproveKind.Approve));
        Assert.Equal(ApproveTexts.KeyInvalid, ApproveTexts.Failure(ApproveKeyError.KeyInvalid, ApproveKind.Approve));
        Assert.Equal(ApproveTexts.DeviceLocked, ApproveTexts.Failure(ApproveKeyError.DeviceLocked, ApproveKind.Approve));
        Assert.Equal(ApproveTexts.MakeFailed, ApproveTexts.Failure(ApproveKeyError.Failed, ApproveKind.Enroll));
        Assert.Equal(ApproveTexts.UseFailed, ApproveTexts.Failure(ApproveKeyError.Failed, ApproveKind.Approve));
        Assert.Null(ApproveTexts.Problem(ApproveUserCheck.Ready));
        Assert.Equal(ApproveTexts.NotSetUp, ApproveTexts.Problem(ApproveUserCheck.NotSetUp));
        Assert.Equal(ApproveTexts.LockedOut, ApproveTexts.Problem(ApproveUserCheck.LockedOut));
        Assert.Equal(ApproveTexts.Unavailable, ApproveTexts.Problem(ApproveUserCheck.Unavailable));
    }

    // Each text that goes to the computer passes the field rules of fluxd, so
    // that fluxd does not replace it with its own text.
    [Fact]
    public void ErrorTextsPassTheFieldRules()
    {
        foreach (var text in new[]
                 {
                     ApproveTexts.NotValid, ApproveTexts.ClockSkew, ApproveTexts.NoKey, ApproveTexts.AnotherOpen, ApproveTexts.NotConnected,
                     ApproveTexts.KeyInvalid, ApproveTexts.SaveFailed, ApproveTexts.NotSetUp, ApproveTexts.LockedOut, ApproveTexts.Unavailable,
                     ApproveTexts.NotRecognized, ApproveTexts.DeviceLocked, ApproveTexts.MakeFailed, ApproveTexts.UseFailed,
                     ApproveTexts.NoSecureHardware, ApproveTexts.NotReached(new string('x', 32), true),
                 })
        {
            Assert.True(ApproveMessage.ValidField(text), text);
        }
    }
}
