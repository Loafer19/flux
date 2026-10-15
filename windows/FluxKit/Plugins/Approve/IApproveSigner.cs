namespace FluxKit;

// A new approval key: the name of the key in the platform, and the public
// key. The private key stays in the platform.
public sealed record ApproveNewKey(string Name, byte[] PublicKey);

// Whether the user check of the platform works now.
public enum ApproveUserCheck
{
    Ready,

    // The user did not set up Windows Hello.
    NotSetUp,

    // Windows Hello is locked after too many failed tries.
    LockedOut,

    // Windows Hello is not available now, for example by a policy.
    Unavailable,
}

// Why a call of the platform signer failed.
public enum ApproveKeyError
{
    // The user or the system closed the user check, or FluxKit cancelled the
    // call. The prompt asks again.
    Cancelled,

    // Windows Hello did not recognize the user.
    NotRecognized,

    // Windows Hello is locked after too many failed tries.
    LockedOut,

    // The user did not set up Windows Hello.
    NotSetUp,

    // Windows Hello is not available now.
    Unavailable,

    // The key is not valid any more, for example after a change of Windows
    // Hello. Flux deletes the key, and the user enrolls again.
    KeyInvalid,

    // The computer is locked, so the key does not work.
    DeviceLocked,

    // Any other failure of the key or of the secure hardware.
    Failed,
}

// A failure of the platform signer. Any other exception from the signer
// counts as ApproveKeyError.Failed.
public sealed class ApproveKeyException(ApproveKeyError error, string? detail = null, Exception? inner = null)
    : Exception(detail ?? error.ToString(), inner)
{
    public ApproveKeyError Error { get; } = error;
}

// The approval keys of the platform and the user check before each
// signature. The Windows app implements it. Each key is an EC P-256 key of
// the Microsoft Platform Crypto Provider, so the TPM holds the private key.
// Each signature needs Windows Hello first. The tests use a software key.
//
// The rules of docs/approve.md apply to each implementation:
// - Make each key in the secure hardware. Never make a key outside it. A
//   computer without a TPM reports false for HasSecureHardware.
// - Keep the private key in the platform. FluxKit gets only the name of the
//   key and its public key.
// - Each call of SignAsync asks the user check of the platform for that 1
//   signature. A check never signs 2 messages, and nothing signs without it.
//   No other member signs.
// - A signature is ECDSA with SHA-256 over the message, in ASN.1 DER.
//
// FluxKit calls CheckUserAsync, CreateKeyAsync, and SignAsync from a thread
// of the pool, 1 call at a time. An implementation that needs the UI thread
// for the prompt of the user check moves the call there itself. FluxKit reads
// HasSecureHardware on the UI thread, so it must be fast. FluxKit calls
// DeleteKey on the UI thread or on a thread of the pool, so it must be fast
// and safe on each thread.
public interface IApproveSigner
{
    // True when this computer has the secure hardware for approval keys,
    // such as a TPM 2.0. The value does not change while the app runs.
    // FluxKit reads it for each request, so it must be fast.
    bool HasSecureHardware { get; }

    // Whether the user check works now. It does not ask the user.
    Task<ApproveUserCheck> CheckUserAsync(CancellationToken cancel);

    // Makes a new EC P-256 signing key in the secure hardware and stores it
    // in the platform under a new name. It returns the name and the public
    // key as SubjectPublicKeyInfo DER. computerId names the computer that
    // the key is for. The current key of that computer stays. FluxKit calls
    // DeleteKey for each key that it does not keep.
    Task<ApproveNewKey> CreateKeyAsync(string computerId, CancellationToken cancel);

    // Asks the user check of the platform, then signs the message with the
    // key. reason tells the user what the signature approves. It returns the
    // ASN.1 DER signature over the SHA-256 of message. When cancel ends, the
    // implementation closes the prompt and throws an OperationCanceledException
    // or an ApproveKeyException with ApproveKeyError.Cancelled. It throws an
    // ApproveKeyException for the other failures that it knows.
    Task<byte[]> SignAsync(string keyName, byte[] message, string reason, CancellationToken cancel);

    // Deletes the key from the platform. A key that does not exist is not an
    // error. It throws an ApproveKeyException when the platform cannot
    // delete the key.
    void DeleteKey(string keyName);
}
