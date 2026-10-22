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

private func verifyClip(_ recorder: StabilizedPreviewRecorder, size: CGSize, audio: Bool, angle: CGFloat = 90) throws {
    let url = URL(fileURLWithPath: "build/recorder-\(Int(size.width))-\(audio)-\(Int(angle)).mp4")
    let expectedSize = [CGFloat(0), 180].contains(angle) ? CGSize(width: size.height, height: size.width) : size
    let done = DispatchSemaphore(value: 0)
    var result: Result<URL, Error>?
    recorder.setTargetFrameRate(30)
    recorder.startRecording(to: url, includeAudio: audio, outputRotationAngle: angle) { result = $0; done.signal() }
    let context = CIContext(options: [.cacheIntermediates: false])
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    for i in 0..<18 {
        let timestamp = 100.0 + Double(i) / 30
        let background = CIImage(color: CIColor(red: 0, green: 0, blue: 1))
            .cropped(to: CGRect(origin: .zero, size: size))
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: size.width/2, height: size.height/2))
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0))
            .cropped(to: CGRect(x: size.width/2, y: size.height/2, width: size.width/2, height: size.height/2))
        let image = red.composited(over: green.composited(over: background))
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
    precondition(video.count == 1 && video[0].naturalSize == expectedSize, "Exact encoded dimensions")
    precondition(sound.count == (audio ? 1 : 0), "Audio permission controls track creation")
    precondition(asset.duration.seconds > 0.3 && asset.duration.seconds < 1.5, "PTS must be relative to session start, not uptime")
    for track in video + sound {
        let reader = try AVAssetReader(asset: asset)
        // Decode video before checking presentation order; compressed B-frames arrive in decode order.
        let settings: [String: Any] = track.mediaType == .video
            ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            : [AVFormatIDKey: kAudioFormatLinearPCM]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        precondition(reader.startReading())
        var count = 0
        var sampleCount = 0
        var last = CMTime.negativeInfinity
        while let sample = output.copyNextSampleBuffer() {
            if count == 0, track.mediaType == .video, let pixels = CMSampleBufferGetImageBuffer(sample) {
                let decoded = CIImage(cvPixelBuffer: pixels)
                for (fraction, channel) in [(CGFloat(0.25), 0), (CGFloat(0.75), 1)] {
                    let x = size.width * fraction, y = size.height * fraction
                    let point: CGPoint
                    switch angle {
                    case 0: point = CGPoint(x: size.height - y, y: x)
                    case 180: point = CGPoint(x: y, y: size.width - x)
                    case 270: point = CGPoint(x: size.width - x, y: size.height - y)
                    default: point = CGPoint(x: x, y: y)
                    }
                    var pixel = [UInt8](repeating: 0, count: 4)
                    context.render(decoded, toBitmap: &pixel, rowBytes: 4,
                        bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
                        format: .RGBA8, colorSpace: colorSpace)
                    precondition(pixel[channel] > 200 && pixel[2] < 40,
                        "Decoded corners must rotate correctly, not turn black, mirror or stretch")
                }
            }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            precondition(CMTimeCompare(time, last) > 0, "Track timestamps must increase")
            last = time
            count += 1
            sampleCount += CMSampleBufferGetNumSamples(sample)
        }
        let diagnostic = "Readback \(track.mediaType.rawValue): buffers=\(count), samples=\(sampleCount), status=\(reader.status.rawValue), error=\(String(describing: reader.error))\n"
        FileHandle.standardError.write(Data(diagnostic.utf8))
        // Audio readers may combine many PCM samples into one buffer.
        let minimumBuffers = track.mediaType == .video ? 8 : 1
        precondition(reader.status == .completed && count >= minimumBuffers && sampleCount > 0, diagnostic)
    }
    print("PASS: encoded \(Int(expectedSize.width))x\(Int(expectedSize.height)), angle=\(angle), audio=\(audio), pixel orientation checked")
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
try verifyClip(recorder, size: CGSize(width: 1080, height: 1920), audio: true, angle: 0)
try verifyClip(recorder, size: CGSize(width: 1080, height: 1920), audio: false, angle: 180)
try verifyClip(recorder, size: CGSize(width: 1080, height: 1920), audio: false, angle: 270)
try verifyClip(recorder, size: CGSize(width: 2160, height: 3840), audio: false, angle: 0)
