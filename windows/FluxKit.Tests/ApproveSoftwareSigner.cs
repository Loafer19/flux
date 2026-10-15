using System.Collections.Concurrent;
using System.Security.Cryptography;
using FluxKit;

namespace FluxKit.Tests;

// FOR TESTS ONLY. A signer with software P-256 keys in memory, in place of
// the TPM and Windows Hello of the app. It is in the test project, so the app
// never links it. The test sets what the user check answers.
public sealed class ApproveSoftwareSigner : IApproveSigner, IDisposable
{
    readonly ConcurrentDictionary<string, ECDsa> keys = new();
    readonly ConcurrentQueue<string> deleted = new();
    int checks;
    int signatures;

    public bool HasSecureHardware { get; set; } = true;

    // What CheckUserAsync answers.
    public ApproveUserCheck UserCheck { get; set; } = ApproveUserCheck.Ready;

    // The error that the next user checks give, or null for a user who
    // passes.
    public ApproveKeyError? CheckFails { get; set; }

    // While set, each user check waits until the test completes it, as a
    // user who has not touched the sensor yet.
    public TaskCompletionSource? Hold { get; set; }

    // Signs in the IEEE P1363 format, as a CNG key does without a conversion.
    public bool WrongFormat { get; set; }

    // The number of user checks that SignAsync asked.
    public int Checks => Volatile.Read(ref checks);

    // The number of signatures.
    public int Signatures => Volatile.Read(ref signatures);

    // The names of the keys that FluxKit deleted, the oldest first.
    public IReadOnlyList<string> Deleted => deleted.ToArray();

    // The names of the keys that exist.
    public IReadOnlyCollection<string> Names => keys.Keys.ToArray();

    // Set when a user check starts.
    public TaskCompletionSource CheckStarted { get; private set; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public Task<ApproveUserCheck> CheckUserAsync(CancellationToken cancel) => Task.FromResult(UserCheck);

    public Task<ApproveNewKey> CreateKeyAsync(string computerId, CancellationToken cancel)
    {
        cancel.ThrowIfCancellationRequested();
        var name = $"flux-approve-{computerId}-{Guid.NewGuid():N}";
        var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        keys[name] = key;
        return Task.FromResult(new ApproveNewKey(name, key.ExportSubjectPublicKeyInfo()));
    }

    public async Task<byte[]> SignAsync(string keyName, byte[] message, string reason, CancellationToken cancel)
    {
        Interlocked.Increment(ref checks);
        CheckStarted.TrySetResult();
        if (Hold is { } hold)
        {
            await hold.Task.WaitAsync(cancel);
        }
        cancel.ThrowIfCancellationRequested();
        if (CheckFails is { } error)
        {
            throw new ApproveKeyException(error);
        }
        if (!keys.TryGetValue(keyName, out var key))
        {
            throw new ApproveKeyException(ApproveKeyError.KeyInvalid, "the key does not exist");
        }
        Interlocked.Increment(ref signatures);
        return key.SignData(message, HashAlgorithmName.SHA256,
            WrongFormat ? DSASignatureFormat.IeeeP1363FixedFieldConcatenation : DSASignatureFormat.Rfc3279DerSequence);
    }

    public void DeleteKey(string keyName)
    {
        deleted.Enqueue(keyName);
        if (keys.TryRemove(keyName, out var key))
        {
            key.Dispose();
        }
    }

    // Forgets a key without FluxKit, as a TPM that the user cleared.
    public void Lose(string keyName)
    {
        if (keys.TryRemove(keyName, out var key))
        {
            key.Dispose();
        }
    }

    // A new task for the next user check.
    public void ResetCheckStarted() => CheckStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

    public void Dispose()
    {
        foreach (var key in keys.Values)
        {
            key.Dispose();
        }
        keys.Clear();
    }
}
