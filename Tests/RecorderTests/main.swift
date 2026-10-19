// Compiled in the same file as the production recorder by CI; no camera or display is used.
private final class StabilizationTraceRecorder {
    static let shared = StabilizationTraceRecorder()
    func recordControl(_ name: String, values: [String: Any] = [:]) {}
}

func pcm(at seconds: Double) -> CMSampleBuffer {
    let frames = 1600
    var block: CMBlockBuffer?
    precondition(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
        blockLength: frames * 2, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
        offsetToData: 0, dataLength: frames * 2, flags: 0, blockBufferOut: &block) == noErr)
    precondition(CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: frames * 2) == noErr)
    var description = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
        mBitsPerChannel: 16, mReserved: 0)
    var format: CMAudioFormatDescription?
    precondition(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &format) == noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
        presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 60000), decodeTimeStamp: .invalid)
    var sampleSize = 2
    var sample: CMSampleBuffer?
    precondition(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
        formatDescription: format, sampleCount: frames, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
        sampleBufferOut: &sample) == noErr)
    return sample!
}

private func verifyClip(_ recorder: StabilizedPreviewRecorder, size: CGSize, audio: Bool) throws {
    let url = URL(fileURLWithPath: "build/recorder-\(Int(size.width))-\(audio).mp4")
    let done = DispatchSemaphore(value: 0)
    var result: Result<URL, Error>?
    recorder.setTargetFrameRate(30)
    recorder.startRecording(to: url, includeAudio: audio) { result = $0; done.signal() }
    let context = CIContext(options: [.cacheIntermediates: false])
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    for i in 0..<18 {
        let timestamp = 100.0 + Double(i) / 30
        let image = CIImage(color: CIColor(red: CGFloat(i) / 18, green: 0.4, blue: 0.2))
            .cropped(to: CGRect(origin: .zero, size: size))
        recorder.append(stabilizedImage: image, sourceTimestamp: timestamp, outputSize: size,
            ciContext: context, colorSpace: colorSpace)
        if audio { recorder.appendAudio(pcm(at: timestamp)) }
        Thread.sleep(forTimeInterval: 0.05)
    }
    recorder.stopRecording()
    precondition(done.wait(timeout: .now() + 30) == .success, "Recording completion timeout")
    _ = try result!.get()
    let asset = AVURLAsset(url: url)
    let video = asset.tracks(withMediaType: .video)
    let sound = asset.tracks(withMediaType: .audio)
    precondition(video.count == 1 && video[0].naturalSize == size, "Exact encoded dimensions")
    precondition(sound.count == (audio ? 1 : 0), "Audio permission controls track creation")
    precondition(asset.duration.seconds > 0.3 && asset.duration.seconds < 1.5, "PTS must be relative to session start, not uptime")
    for track in video + sound {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        precondition(reader.startReading())
        var count = 0
        var last = CMTime.negativeInfinity
        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            precondition(CMTimeCompare(time, last) > 0, "Track timestamps must increase")
            last = time
            count += 1
        }
        precondition(reader.status == .completed && count >= 8, "Readable media samples")
    }
    print("PASS: encoded \(Int(size.width))x\(Int(size.height)), audio=\(audio), no display callbacks")
}

private let recorder = StabilizedPreviewRecorder()
let emptyDone = DispatchSemaphore(value: 0)
recorder.startRecording(to: URL(fileURLWithPath: "build/no-frames.mp4"), includeAudio: false) {
    if case .success = $0 { preconditionFailure("An empty recording must not report success") }
    emptyDone.signal()
}
recorder.stopRecording()
precondition(emptyDone.wait(timeout: .now() + 5) == .success)
try verifyClip(recorder, size: CGSize(width: 1080, height: 1920), audio: false)
try verifyClip(recorder, size: CGSize(width: 1920, height: 1080), audio: true)
try verifyClip(recorder, size: CGSize(width: 3840, height: 2160), audio: false)
