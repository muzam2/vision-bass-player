import Foundation
import AVFoundation

/// Turns the film's full-rate audio into a tiny low-frequency stream for the subwoofer.
///
/// Pipeline (runs on the audio render thread, so no allocation in `process`):
///   mono (or the LFE channel if there is one) → 4th-order Butterworth low-pass at `cutoffHz`
///   → decimate to `outputRate` Hz → Int16 → 20 ms packets handed to `onPacket`.
///
/// At 1 kHz / 16-bit mono that is 2 kB/s; a 20 ms packet is 47 bytes including header.
final class BassExtractor {
    // Public configuration (set before playback; not changed mid-stream).
    let outputRate: Double = 1000
    let samplesPerPacket = 20                  // 20 ms at 1 kHz
    var cutoffHz: Double = 120
    var gain: Float = 1.0

    /// Called with a complete wire packet. Invoked on the audio thread; keep it cheap.
    var onPacket: ((Data) -> Void)?

    // Stream format, set in configure().
    private(set) var sampleRate: Double = 48_000
    private(set) var channels: Int = 2
    private(set) var interleaved = false

    // DSP state.
    private var lpf1 = Biquad()
    private var lpf2 = Biquad()
    private var decimPhase: Double = 0
    private var decimStep: Double = 1000.0 / 48_000.0

    // Diagnostics, written on the audio thread, read (inexactly, that is fine) from the UI.
    private(set) var buffersProcessed = 0
    private(set) var framesProcessed = 0
    private(set) var packetsEmitted = 0
    private var inputPeak: Float = 0
    private var bassPeak: Float = 0

    struct Stats {
        var buffers = 0, frames = 0, packets = 0
        var inputPeakDb: Float = -120, bassPeakDb: Float = -120
    }

    /// Counters so far plus the peak levels since the previous call (which are then reset).
    func stats() -> Stats {
        func db(_ v: Float) -> Float { v > 1e-6 ? 20 * log10(v) : -120 }
        let s = Stats(buffers: buffersProcessed, frames: framesProcessed, packets: packetsEmitted,
                      inputPeakDb: db(inputPeak), bassPeakDb: db(bassPeak))
        inputPeak = 0; bassPeak = 0
        return s
    }

    // Packetiser state.
    private var pending = [Int16](repeating: 0, count: 20)
    private var pendingCount = 0
    private var sequence: UInt16 = 0
    private var samplesEmitted: UInt64 = 0
    private var packetBuffer = Data(count: 47)

    static let packetMagic: UInt8 = 0xB5
    static let headerSize = 7                  // magic(1) + seq(2) + timestampMs(4)

    func configure(sampleRate: Double, channels: Int, interleaved: Bool) {
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        self.interleaved = interleaved
        decimStep = outputRate / sampleRate
        decimPhase = 0
        // 4th-order Butterworth = two biquads with Q = 0.5412 and 1.3066.
        lpf1.setLowPass(sampleRate: sampleRate, cutoff: cutoffHz, q: 0.54119610)
        lpf2.setLowPass(sampleRate: sampleRate, cutoff: cutoffHz, q: 1.30656296)
        pendingCount = 0
        sequence = 0
        samplesEmitted = 0
        packetBuffer = Data(count: Self.headerSize + samplesPerPacket * 2)
    }

    /// Feed one render callback's worth of Float32 audio.
    func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        guard abl.count > 0, frames > 0 else { return }
        buffersProcessed &+= 1
        framesProcessed &+= frames

        // Resolve channel pointers once per callback.
        if interleaved {
            guard let base = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let stride = channels
            // Channel 3 is LFE in L R C LFE Ls Rs ordering.
            let lfeIndex = channels >= 6 ? 3 : -1
            for i in 0..<frames {
                var x: Float = 0
                if lfeIndex >= 0 {
                    x = base[i * stride + lfeIndex]
                } else {
                    for c in 0..<stride { x += base[i * stride + c] }
                    x /= Float(stride)
                }
                push(x)
            }
        } else {
            let chCount = abl.count
            let lfeIndex = chCount >= 6 ? 3 : -1
            if lfeIndex >= 0, let p = abl[lfeIndex].mData?.assumingMemoryBound(to: Float.self) {
                for i in 0..<frames { push(p[i]) }
            } else {
                let inv = 1 / Float(chCount)
                for i in 0..<frames {
                    var x: Float = 0
                    for c in 0..<chCount {
                        if let p = abl[c].mData?.assumingMemoryBound(to: Float.self) { x += p[i] }
                    }
                    push(x * inv)
                }
            }
        }
    }

    @inline(__always)
    private func push(_ sample: Float) {
        let a = abs(sample)
        if a > inputPeak { inputPeak = a }
        let y = lpf2.process(lpf1.process(sample))
        let b = abs(y)
        if b > bassPeak { bassPeak = b }
        decimPhase += decimStep
        if decimPhase >= 1 {
            decimPhase -= 1
            let scaled = max(-1, min(1, y * gain))
            emit(Int16(scaled * 32767))
        }
    }

    private func emit(_ s: Int16) {
        pending[pendingCount] = s
        pendingCount += 1
        if pendingCount == samplesPerPacket {
            flushPacket()
        }
    }

    private func flushPacket() {
        let timestampMs = UInt32((samplesEmitted * 1000) / UInt64(outputRate))
        packetBuffer.withUnsafeMutableBytes { raw in
            raw[0] = Self.packetMagic
            raw.storeBytes(of: sequence.littleEndian, toByteOffset: 1, as: UInt16.self)
            raw.storeBytes(of: timestampMs.littleEndian, toByteOffset: 3, as: UInt32.self)
            for i in 0..<samplesPerPacket {
                raw.storeBytes(of: pending[i].littleEndian, toByteOffset: Self.headerSize + i * 2, as: Int16.self)
            }
        }
        sequence &+= 1
        samplesEmitted += UInt64(samplesPerPacket)
        packetsEmitted &+= 1
        pendingCount = 0
        onPacket?(packetBuffer)   // Data is copy-on-write; receiver gets a snapshot.
    }
}

/// Direct-form-II transposed biquad (RBJ cookbook coefficients).
struct Biquad {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var z1: Float = 0, z2: Float = 0

    mutating func setLowPass(sampleRate: Double, cutoff: Double, q: Double) {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw0 = cos(w0)
        let a0 = 1 + alpha
        b0 = Float(((1 - cosw0) / 2) / a0)
        b1 = Float((1 - cosw0) / a0)
        b2 = Float(((1 - cosw0) / 2) / a0)
        a1 = Float((-2 * cosw0) / a0)
        a2 = Float((1 - alpha) / a0)
        z1 = 0; z2 = 0
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}
