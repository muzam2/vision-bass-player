import Foundation
import AVFoundation
import os

/// Plays the console's audio (Opus decoded to 16-bit PCM by chiaki) with as little delay as is
/// safe: a short jitter buffer feeds an `AVAudioSourceNode`, and the buffer is trimmed whenever
/// it grows (Wi-Fi bursts), so the sound never drifts behind the picture. The mixer is tapped
/// for the subwoofer exactly like the film player does (`BassExtractor` → `BassLink`).
final class RemotePlayAudio {
    private var engine: AVAudioEngine?
    private var source: AVAudioSourceNode?
    private let ring = PCMRing()
    private let extractor = BassExtractor()
    private weak var bassLink: BassLink?
    private var tapInstalled = false
    private(set) var channels = 2
    private(set) var sampleRate: Double = 48_000

    /// Jitter buffer: start playing at `startMs`, trim back to `trimToMs` above `maxMs`.
    var startMs: Double = 40
    var maxMs: Double = 160
    var trimToMs: Double = 60

    init(bassLink: BassLink?) {
        self.bassLink = bassLink
        extractor.onPacket = { [weak bassLink] packet in bassLink?.send(packet) }
    }

    /// Buffered audio in milliseconds and the number of underruns so far.
    var bufferedMs: Double { Double(ring.count) / Double(max(1, channels)) / sampleRate * 1000 }
    var underruns: Int { ring.underruns }
    var trims: Int { ring.trims }

    /// Called on chiaki's thread when the format is known (before the first frame).
    func configure(channels: Int, sampleRate: Double) {
        let ch = max(1, min(8, channels))
        let rate = sampleRate > 0 ? sampleRate : 48_000
        if engine != nil, ch == self.channels, rate == self.sampleRate { return }
        stop()
        self.channels = ch
        self.sampleRate = rate
        ring.reset(capacity: Int(rate) * ch)   // one second
        ring.channels = ch
        ring.startThreshold = Int(rate * startMs / 1000) * ch
        ring.maxFill = Int(rate * maxMs / 1000) * ch
        ring.trimTo = Int(rate * trimToMs / 1000) * ch

        let session = AVAudioSession.sharedInstance()
        try? session.setPreferredIOBufferDuration(0.005)

        let engine = AVAudioEngine()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(ch)) else { return }
        let ring = self.ring
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
            ring.read(into: UnsafeMutableAudioBufferListPointer(abl), frames: Int(frameCount))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            DiagLog.log("audio engine failed to start: \(error.localizedDescription)", "rp")
            return
        }
        self.engine = engine
        self.source = node
        installBassTap(on: engine)
        DiagLog.log("audio: \(ch) ch, \(Int(rate)) Hz, IO buffer \(Int(session.ioBufferDuration * 1000)) ms", "rp")
    }

    /// Interleaved 16-bit samples from chiaki's thread.
    func push(_ pcm: UnsafeBufferPointer<Int16>, frames: Int) {
        ring.write(pcm, count: frames * channels)
    }

    func stop() {
        if let engine {
            if tapInstalled { engine.mainMixerNode.removeTap(onBus: 0) }
            engine.stop()
        }
        tapInstalled = false
        engine = nil
        source = nil
    }

    private func installBassTap(on engine: AVAudioEngine) {
        guard bassLink != nil else { return }
        let mixer = engine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        let extractor = self.extractor
        extractor.configure(sampleRate: format.sampleRate, channels: Int(format.channelCount), interleaved: format.isInterleaved)
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            let f = buffer.format
            if f.sampleRate != extractor.sampleRate || Int(f.channelCount) != extractor.channels || f.isInterleaved != extractor.interleaved {
                extractor.configure(sampleRate: f.sampleRate, channels: Int(f.channelCount), interleaved: f.isInterleaved)
            }
            extractor.process(bufferList: buffer.mutableAudioBufferList, frames: Int(buffer.frameLength))
        }
        tapInstalled = true
    }
}

/// Interleaved float ring buffer shared by chiaki's audio thread and the render thread.
private final class PCMRing: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var buf: [Float] = []
    private var readIndex = 0
    private var writeIndex = 0
    private(set) var count = 0
    private var playing = false
    var channels = 2
    var startThreshold = 0
    var maxFill = 0
    var trimTo = 0
    private(set) var underruns = 0
    private(set) var trims = 0

    func reset(capacity: Int) {
        lock.lock()
        buf = [Float](repeating: 0, count: max(1, capacity))
        readIndex = 0; writeIndex = 0; count = 0; playing = false
        lock.unlock()
    }

    func write(_ pcm: UnsafeBufferPointer<Int16>, count n: Int) {
        lock.lock()
        defer { lock.unlock() }
        let cap = buf.count
        guard cap > 1 else { return }
        let n = min(n, pcm.count)
        for i in 0..<n {
            buf[writeIndex] = Float(pcm[i]) / 32768
            writeIndex = (writeIndex + 1) % cap
        }
        count += n
        if count > cap {
            // Overflow: keep the newest second.
            readIndex = (readIndex + (count - cap)) % cap
            count = cap
        }
        if maxFill > 0, count > maxFill {
            // Burst after a Wi-Fi hiccup: drop the oldest audio so the delay stays small.
            let drop = (count - trimTo) / max(1, channels) * max(1, channels)
            readIndex = (readIndex + drop) % cap
            count -= drop
            trims += 1
        }
        if !playing, count >= startThreshold { playing = true }
    }

    func read(into abl: UnsafeMutableAudioBufferListPointer, frames: Int) {
        lock.lock()
        defer { lock.unlock() }
        let ch = channels
        let cap = buf.count
        let available = playing ? count / max(1, ch) : 0
        let n = min(frames, available)
        for f in 0..<frames {
            for c in 0..<abl.count {
                guard let data = abl[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                if f < n, c < ch {
                    data[f] = buf[(readIndex + f * ch + c) % cap]
                } else {
                    data[f] = 0
                }
            }
        }
        if n > 0 {
            readIndex = (readIndex + n * ch) % cap
            count -= n * ch
        }
        if playing && n < frames {
            underruns += 1
            playing = count >= startThreshold   // refill before playing again
        }
    }
}
