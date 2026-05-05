import Foundation
import os.log

/// One-shot smoke test for BASS on tvOS.
/// Validates: init, plugin load (bassflac/bassopus), push-stream create, playback,
/// and BASS_ChannelGetData(FFT) on a non-decoder (push) stream — the critical
/// path the visualizer will rely on.
///
/// Call `BassSmokeTest.run()` once from `ContentView.onAppear` and watch the
/// Console for `[BassSmoke]` lines.
enum BassSmokeTest {

    private static let log = OSLog(subsystem: "com.lmsstream", category: "BassSmoke")

    private static let sampleRate: DWORD = 44100
    private static let channels: DWORD = 2
    private static let toneHz: Double = 440.0
    private static let toneSeconds: Int = 5

    /// Run the smoke test. Idempotent within a single process: BASS_Init only succeeds once.
    static func run() {
        os_log(.info, log: log, "── BASS tvOS smoke test starting ──")

        let version = BASS_GetVersion()
        os_log(.info, log: log,
               "BASS version: %u.%u.%u.%u",
               (version >> 24) & 0xff, (version >> 16) & 0xff,
               (version >> 8) & 0xff, version & 0xff)

        guard BASS_Init(-1, sampleRate, 0, nil, nil) != 0 else {
            os_log(.error, log: log,
                   "BASS_Init failed — error %d", BASS_ErrorGetCode())
            return
        }
        os_log(.info, log: log, "BASS_Init OK")

        loadPlugin(named: "bassflac", label: "BASSFLAC")
        loadPlugin(named: "bassopus", label: "BASSOPUS")

        let streamHandle = BASS_StreamCreate(
            sampleRate, channels,
            DWORD(BASS_SAMPLE_FLOAT),
            getLyrPlayStreamProcPush(),
            nil
        )
        guard streamHandle != 0 else {
            os_log(.error, log: log,
                   "BASS_StreamCreate(PUSH) failed — error %d",
                   BASS_ErrorGetCode())
            return
        }
        os_log(.info, log: log, "Push stream created (handle=%u)", streamHandle)

        pushSineTone(into: streamHandle)

        guard BASS_ChannelPlay(streamHandle, 0) != 0 else {
            os_log(.error, log: log,
                   "BASS_ChannelPlay failed — error %d", BASS_ErrorGetCode())
            return
        }
        os_log(.info, log: log, "Playback started — sampling FFT in 500ms")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            sampleFFT(streamHandle)
        }
    }

    private static func loadPlugin(named name: String, label: String) {
        let plugin = BASS_PluginLoad(name, 0)
        if plugin != 0 {
            os_log(.info, log: log, "%{public}s plugin loaded (handle=%u)", label, plugin)
        } else {
            os_log(.error, log: log,
                   "%{public}s plugin load failed — error %d",
                   label, BASS_ErrorGetCode())
        }
    }

    /// Generate ~5 seconds of a 440 Hz stereo sine, 32-bit float, and push it.
    private static func pushSineTone(into stream: HSTREAM) {
        let frameCount = Int(sampleRate) * toneSeconds
        var samples = [Float](repeating: 0, count: frameCount * Int(channels))
        let twoPiFOverSr = 2.0 * Double.pi * toneHz / Double(sampleRate)
        let amp: Float = 0.25  // -12 dBFS, comfortable
        for i in 0..<frameCount {
            let s = Float(sin(Double(i) * twoPiFOverSr)) * amp
            samples[i * 2] = s
            samples[i * 2 + 1] = s
        }
        let byteCount = samples.count * MemoryLayout<Float>.size
        let pushed = samples.withUnsafeBufferPointer { ptr -> DWORD in
            ptr.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: byteCount) { raw in
                BASS_StreamPutData(stream, raw, DWORD(byteCount))
            }
        }
        if pushed == DWORD(bitPattern: -1) {
            os_log(.error, log: log,
                   "BASS_StreamPutData failed — error %d", BASS_ErrorGetCode())
        } else {
            os_log(.info, log: log,
                   "Pushed %u bytes (%d frames of %.0f Hz tone)",
                   pushed, frameCount, toneHz)
        }
    }

    /// Sample BASS_DATA_FFT2048 from the push stream and log the dominant bin.
    private static func sampleFFT(_ stream: HSTREAM) {
        let binCount = 1024  // FFT2048 returns N/2 magnitude bins
        var bins = [Float](repeating: 0, count: binCount)
        let bytesRead = bins.withUnsafeMutableBufferPointer { ptr -> DWORD in
            BASS_ChannelGetData(stream, ptr.baseAddress, DWORD(BASS_DATA_FFT2048))
        }

        if bytesRead == DWORD(bitPattern: -1) {
            os_log(.error, log: log,
                   "BASS_ChannelGetData(FFT) failed — error %d (PUSH STREAMS DO NOT SUPPORT FFT — investigate)",
                   BASS_ErrorGetCode())
            return
        }

        var peakBin = 0
        var peakMag: Float = 0
        for (i, mag) in bins.enumerated() where mag > peakMag {
            peakMag = mag
            peakBin = i
        }
        let binHz = Double(peakBin) * Double(sampleRate) / 2048.0
        os_log(.info, log: log,
               "FFT OK — peak bin %d ≈ %.1f Hz (mag=%.4f). Expected ≈%.1f Hz.",
               peakBin, binHz, peakMag, toneHz)
        os_log(.info, log: log, "── BASS tvOS smoke test complete ──")
    }
}
