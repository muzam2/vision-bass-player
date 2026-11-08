import AVFoundation
import MediaToolbox

/// Installs an MTAudioProcessingTap on an AVPlayerItem's audio track and forwards the
/// decoded PCM to a `BassExtractor`. The tap is "post-effects" so we see the final mix.
///
/// Phase 2 note: with KSPlayer/FFmpeg the same `BassExtractor` is fed from an
/// AVAudioEngine tap instead; this file is the AVPlayer-specific glue.
final class BassTapProcessor {
    let extractor: BassExtractor

    init(extractor: BassExtractor) {
        self.extractor = extractor
    }

    /// Build an audio mix whose single input carries our tap. Attach it with `item.audioMix = mix`.
    func makeAudioMix(for audioTrack: AVAssetTrack) -> AVAudioMix? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            init: { _, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { _ in },
            prepare: { tap, _, format in
                let me = Unmanaged<BassTapProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let asbd = format.pointee
                let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
                me.extractor.configure(sampleRate: asbd.mSampleRate,
                                       channels: Int(asbd.mChannelsPerFrame),
                                       interleaved: !nonInterleaved)
            },
            unprepare: { _ in },
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
                guard status == noErr else { return }
                let me = Unmanaged<BassTapProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                me.extractor.process(bufferList: bufferListInOut, frames: Int(numberFramesOut.pointee))
            }
        )

        var tapRef: Unmanaged<MTAudioProcessingTap>?
        let err = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tapRef)
        guard err == noErr, let tap = tapRef else {
            print("BassTapProcessor: MTAudioProcessingTapCreate failed (\(err))")
            return nil
        }

        let params = AVMutableAudioMixInputParameters(track: audioTrack)
        params.audioTapProcessor = tap.takeRetainedValue()
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }
}
