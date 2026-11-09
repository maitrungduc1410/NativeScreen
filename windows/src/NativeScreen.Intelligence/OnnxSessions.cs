using Microsoft.ML.OnnxRuntime;

namespace NativeScreen.Intelligence;

internal static class OnnxSessions
{
    /// <summary>NS_MODEL_CPU=1 keeps inference off the GPU, for measuring and for machines with a bad driver.</summary>
    private static bool ForcedCpu => Environment.GetEnvironmentVariable("NS_MODEL_CPU") == "1";

    /// <summary>Half the cores, like transcription: inference must not make the machine unusable.</summary>
    public static InferenceSession Cpu(string path)
    {
        using var options = new SessionOptions { IntraOpNumThreads = Math.Max(1, Environment.ProcessorCount / 2) };
        return new InferenceSession(path, options);
    }

    /// <summary>On the GPU through DirectML when that works, otherwise on the CPU.</summary>
    public static InferenceSession Preferred(string path, out bool onGpu)
    {
        onGpu = false;
        if (ForcedCpu)
        {
            return Cpu(path);
        }

        try
        {
            // DirectML needs sequential execution and no memory pattern.
            using var options = new SessionOptions { EnableMemoryPattern = false, ExecutionMode = ExecutionMode.ORT_SEQUENTIAL };
            options.AppendExecutionProvider_DML(0);
            var session = new InferenceSession(path, options);
            onGpu = true;
            return session;
        }
        catch (Exception exception) when (exception is OnnxRuntimeException or DllNotFoundException or EntryPointNotFoundException)
        {
            return Cpu(path);
        }
    }
}
