import AVFoundation
import Foundation
import MediaCore
import Synchronization
@preconcurrency import WebRTC
@preconcurrency import WebRTCAudioShim

/// Common audio device state. WebRTC's native audio device module calls these from its own
/// thread; the format is fixed at 48 kHz stereo (plan section 8, capture settings).
class FixedFormatAudioDevice: NSObject, RTCAudioDevice, @unchecked Sendable {
    static let sampleRate = 48_000.0
    /// WebRTC's Objective-C module records mono only: given stereo it consumes half of each
    /// buffer (spike S4). FARSIDE_AUDIO_CHANNELS=2 restores stereo input for testing.
    static let inputChannels = ProcessInfo.processInfo.environment["FARSIDE_AUDIO_CHANNELS"].flatMap(Int.init) ?? 1
    static let channels = 2
    nonisolated(unsafe) static var preferred = ""

    private let lock = NSLock()
    private var _delegate: RTCAudioDeviceDelegate?
    private var flags = (recording: false, playing: false, recordInit: false, playoutInit: false)

    var delegate: RTCAudioDeviceDelegate? { lock.withLock { _delegate } }
    func update(_ change: (inout (recording: Bool, playing: Bool, recordInit: Bool, playoutInit: Bool)) -> Void) {
        lock.withLock { change(&flags) }
    }
    var current: (recording: Bool, playing: Bool, recordInit: Bool, playoutInit: Bool) { lock.withLock { flags } }

    var deviceInputSampleRate: Double { Self.sampleRate }
    var inputIOBufferDuration: TimeInterval { 0.01 }
    var inputNumberOfChannels: Int { Self.inputChannels }
    var inputLatency: TimeInterval { 0 }
    var deviceOutputSampleRate: Double { Self.sampleRate }
    var outputIOBufferDuration: TimeInterval { 0.01 }
    var outputNumberOfChannels: Int { Self.channels }
    var outputLatency: TimeInterval { 0 }

    var isInitialized: Bool { delegate != nil }
    func initialize(with delegate: any RTCAudioDeviceDelegate) -> Bool {
        Self.preferred = "input \(delegate.preferredInputSampleRate) Hz \(delegate.preferredInputIOBufferDuration) s, output \(delegate.preferredOutputSampleRate) Hz \(delegate.preferredOutputIOBufferDuration) s"
        lock.withLock { _delegate = delegate }
        return true
    }
    func terminateDevice() -> Bool {
        _ = stopPlayout()
        _ = stopRecording()
        lock.withLock { _delegate = nil }
        return true
    }

    var isPlayoutInitialized: Bool { current.playoutInit }
    func initializePlayout() -> Bool { update { $0.playoutInit = true }; return true }
    var isPlaying: Bool { current.playing }
    func startPlayout() -> Bool { update { $0.playing = true }; return true }
    func stopPlayout() -> Bool { update { $0.playing = false }; return true }

    var isRecordingInitialized: Bool { current.recordInit }
    func initializeRecording() -> Bool { update { $0.recordInit = true }; return true }
    var isRecording: Bool { current.recording }
    func startRecording() -> Bool { update { $0.recording = true }; return true }
    func stopRecording() -> Bool { update { $0.recording = false }; return true }
}

/// The host's audio input: PCM pushed in from screen capture, handed to WebRTC as recorded audio.
public final class InjectedAudioInput: Sendable {
    let device = InputDevice()
    public init() {}
    /// What WebRTC's audio module asked for, once initialized. Spike diagnostics.
    public var preferredFormat: String { FixedFormatAudioDevice.preferred }
    /// True once WebRTC has started recording, which happens when the audio track is connected.
    public var isLive: Bool { device.isRecording && device.delegate != nil }
    public var framesDelivered: Int { device.framesDelivered }
    public var deliverErrors: Int { device.deliverErrors }
    /// Pushes 32-bit float PCM, one plane per channel. Call from one serial queue.
    public func push(left: UnsafePointer<Float>, right: UnsafePointer<Float>?, frames: Int, hostTime: UInt64) {
        device.push(left: left, right: right, frames: frames, hostTime: hostTime)
    }
}

final class InputDevice: FixedFormatAudioDevice, @unchecked Sendable {
    /// WebRTC's module copies exactly one IO buffer per delivery (spike S4), so pushed audio is
    /// queued and delivered in chunks of this many frames.
    static let chunkFrames = 480
    private var pending: [Int16] = []
    private var pendingHostTime: UInt64 = 0
    private var chunk = [Int16](repeating: 0, count: InputDevice.chunkFrames * 2)
    private var sampleTime = 0.0
    private(set) var framesDelivered = 0
    private(set) var deliverErrors = 0

    func push(left: UnsafePointer<Float>, right: UnsafePointer<Float>?, frames: Int, hostTime: UInt64) {
        guard frames > 0, let delegate, isRecording else { return }
        let r = right ?? left
        if pending.isEmpty { pendingHostTime = hostTime }
        pending.reserveCapacity(pending.count + frames * 2)
        let c = Self.inputChannels
        for i in 0..<frames {
            if c == 2 {
                pending.append(Int16(max(-1, min(1, left[i])) * 32767))
                pending.append(Int16(max(-1, min(1, r[i])) * 32767))
            } else {
                pending.append(Int16(max(-1, min(1, (left[i] + r[i]) / 2)) * 32767))
            }
        }
        let n = Self.chunkFrames
        while pending.count >= n * c {
            chunk.withUnsafeMutableBufferPointer { dst in
                pending.withUnsafeBufferPointer { src in
                    _ = dst.initialize(from: src[0..<(n * c)])
                }
            }
            pending.removeFirst(n * c)
            var flags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp()
            timestamp.mHostTime = pendingHostTime
            timestamp.mSampleTime = sampleTime
            timestamp.mFlags = [.hostTimeValid, .sampleTimeValid]
            let status = chunk.withUnsafeMutableBytes { bytes -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(c), mDataByteSize: UInt32(n * 2 * c), mData: bytes.baseAddress))
                return delegate.deliverRecordedData(&flags, &timestamp, 1, UInt32(n), &list, nil, nil)
            }
            sampleTime += Double(n)
            pendingHostTime += HostClock.ticks(seconds: Double(n) / Self.sampleRate)
            if status == noErr { framesDelivered += n } else { deliverErrors += 1 }
        }
    }
}

/// The client's audio output: pulls decoded PCM from WebRTC on the audio render thread and
/// plays it with AVAudioEngine. `onRender` sees every buffer, for analysis.
public final class AudioPlayout: Sendable {
    let device: PlayoutDevice
    /// `onRender` gets interleaved stereo Int16 samples, the frame count, and the host time when
    /// the buffer was pulled. It runs on the audio thread, so it must not block.
    /// `muted` pulls and analyses audio without playing it, for in-process tests that capture
    /// their own output.
    public init(muted: Bool = false, onRender: @escaping @Sendable (UnsafeBufferPointer<Int16>, Int, UInt64) -> Void = { _, _, _ in }) {
        device = PlayoutDevice(muted: muted, onRender: onRender)
    }
    public var hardwareOutputLatency: TimeInterval { device.hardwareOutputLatency }
    public var hardwareIOBufferDuration: TimeInterval { device.hardwareIOBufferDuration }
    public var playedBuffers: Int { device.playedBuffers }
    public var stereoBuffers: Int { device.stereoBuffers }
}

final class PlayoutDevice: FixedFormatAudioDevice, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var scratch = [Int16](repeating: 0, count: 8192)
    private let onRender: @Sendable (UnsafeBufferPointer<Int16>, Int, UInt64) -> Void
    private let muted: Bool
    /// Buffers played, and how many had different left and right channels.
    private(set) var playedBuffers = 0
    private(set) var stereoBuffers = 0

    init(muted: Bool, onRender: @escaping @Sendable (UnsafeBufferPointer<Int16>, Int, UInt64) -> Void) {
        self.onRender = onRender
        self.muted = muted
        super.init()
    }

    var hardwareOutputLatency: TimeInterval {
        #if os(iOS)
        AVAudioSession.sharedInstance().outputLatency
        #else
        0
        #endif
    }

    var hardwareIOBufferDuration: TimeInterval {
        #if os(iOS)
        AVAudioSession.sharedInstance().ioBufferDuration
        #else
        0
        #endif
    }

    override var outputLatency: TimeInterval { hardwareOutputLatency }

    override func initializePlayout() -> Bool {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setPreferredSampleRate(Self.sampleRate)
        try? session.setPreferredIOBufferDuration(0.005)
        try? session.setActive(true)
        #endif
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: AVAudioChannelCount(Self.channels)) else { return false }
        let node = AVAudioSourceNode(format: format) { [unowned self] _, timestamp, frameCount, output -> OSStatus in
            self.render(frameCount: Int(frameCount), timestamp: timestamp.pointee, output: UnsafeMutableAudioBufferListPointer(output))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        if muted { engine.mainMixerNode.outputVolume = 0 }
        source = node
        return super.initializePlayout()
    }

    override func startPlayout() -> Bool {
        do { try engine.start() } catch { return false }
        return super.startPlayout()
    }

    override func stopPlayout() -> Bool {
        engine.stop()
        return super.stopPlayout()
    }

    private func render(frameCount: Int, timestamp: AudioTimeStamp, output: UnsafeMutableAudioBufferListPointer) {
        let pulledAt = HostClock.now()
        guard let delegate, isPlaying, frameCount * 2 <= scratch.count else {
            for buffer in output { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
            return
        }
        var flags = AudioUnitRenderActionFlags()
        var ts = timestamp
        let status = scratch.withUnsafeMutableBytes { bytes -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: UInt32(Self.channels), mDataByteSize: UInt32(frameCount * 4), mData: bytes.baseAddress))
            return delegate.getPlayoutData(&flags, &ts, 0, UInt32(frameCount), &list)
        }
        guard status == noErr, output.count >= 2,
              let left = output[0].mData?.assumingMemoryBound(to: Float.self),
              let right = output[1].mData?.assumingMemoryBound(to: Float.self)
        else {
            for buffer in output { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
            return
        }
        var differs = false
        for i in 0..<frameCount {
            left[i] = Float(scratch[2 * i]) / 32768
            right[i] = Float(scratch[2 * i + 1]) / 32768
            if scratch[2 * i] != scratch[2 * i + 1] { differs = true }
        }
        if differs { stereoBuffers += 1 }
        playedBuffers += 1
        scratch.withUnsafeBufferPointer { onRender(UnsafeBufferPointer(rebasing: $0[0..<(frameCount * 2)]), frameCount, pulledAt) }
    }
}
