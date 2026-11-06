using NAudio.Wave;

namespace MeetingNotes.Core;

/// One track ("me" or "others"), written as 16-bit mono WAV at the device's sample rate. Opened with the first
/// buffer, so a track that never gets audio has no file.
///
/// WASAPI loopback sends nothing while nothing is playing, so silence is missing from the stream. The writer
/// pads those gaps with zeros from the buffer timestamps, which keeps the track in step with the clock (and the
/// transcript timestamps right).
public sealed class TrackWriter : IDisposable
{
    readonly string path;
    WaveFileWriter? file;
    int rate;
    long written;   // frames
    readonly object gate = new();

    /// Clock time (seconds) of the first sample.
    public double? StartTime { get; private set; }
    public string Path => path;
    /// Gaps shorter than this are timing jitter, not missing audio.
    public double Tolerance { get; init; } = 0.2;

    public TrackWriter(string path)
    {
        this.path = path;
    }

    /// Frames of silence to insert before a buffer of `incoming` frames that arrived at `elapsed` seconds after
    /// the track started, when `written` frames are already in the file.
    public static long FramesToPad(long written, int incoming, double elapsed, int rate, double tolerance)
    {
        var expected = (long)Math.Round(elapsed * rate);
        var missing = expected - (written + incoming);
        return missing > tolerance * rate ? missing : 0;
    }

    /// `now` is the clock time (seconds) when the buffer arrived; its last sample was captured then.
    public void Write(byte[] buffer, int bytes, WaveFormat format, double now)
    {
        if (bytes <= 0) return;
        var mono = ToMono16(buffer, bytes, format);
        var frames = mono.Length / 2;
        if (frames == 0) return;
        lock (gate)
        {
            if (file == null)
            {
                rate = format.SampleRate;
                file = new WaveFileWriter(path, new WaveFormat(rate, 16, 1));
                StartTime = now - (double)frames / rate;
            }
            var pad = FramesToPad(written, frames, now - StartTime!.Value, rate, Tolerance);
            if (pad > 0)
            {
                var zeros = new byte[Math.Min(pad, rate * 10L) * 2];
                for (var left = pad; left > 0; left -= zeros.Length / 2)
                {
                    var n = (int)Math.Min(left, zeros.Length / 2);
                    file.Write(zeros, 0, n * 2);
                }
                written += pad;
            }
            file.Write(mono, 0, mono.Length);
            written += frames;
        }
    }

    public long FramesWritten { get { lock (gate) return written; } }

    public void Close()
    {
        lock (gate)
        {
            file?.Dispose();
            file = null;
        }
    }

    public void Dispose() => Close();

    static readonly Guid IeeeFloatSubtype = new("00000003-0000-0010-8000-00aa00389b71");

    /// Float, 16/24/32-bit PCM and their WAVE_FORMAT_EXTENSIBLE forms, any channel count, to 16-bit mono.
    public static byte[] ToMono16(byte[] buffer, int bytes, WaveFormat format)
    {
        var channels = Math.Max(1, format.Channels);
        var bits = format.BitsPerSample;
        var isFloat = format.Encoding == WaveFormatEncoding.IeeeFloat
            || (format is WaveFormatExtensible ext && ext.SubFormat == IeeeFloatSubtype);
        var bytesPerSample = bits / 8;
        if (bytesPerSample == 0) return Array.Empty<byte>();
        var frames = bytes / (bytesPerSample * channels);
        var output = new byte[frames * 2];
        for (var i = 0; i < frames; i++)
        {
            double sum = 0;
            for (var c = 0; c < channels; c++)
            {
                var at = (i * channels + c) * bytesPerSample;
                sum += isFloat && bits == 32 ? BitConverter.ToSingle(buffer, at)
                    : isFloat && bits == 64 ? BitConverter.ToDouble(buffer, at)
                    : bits switch
                    {
                        16 => BitConverter.ToInt16(buffer, at) / 32768.0,
                        24 => ((buffer[at] | (buffer[at + 1] << 8) | (buffer[at + 2] << 16)) << 8 >> 8) / 8388608.0,
                        32 => BitConverter.ToInt32(buffer, at) / 2147483648.0,
                        8 => (buffer[at] - 128) / 128.0,
                        _ => 0,
                    };
            }
            var v = Math.Clamp(sum / channels, -1.0, 1.0);
            var s = (short)Math.Round(v * 32767);
            output[i * 2] = (byte)(s & 0xff);
            output[i * 2 + 1] = (byte)((s >> 8) & 0xff);
        }
        return output;
    }
}
