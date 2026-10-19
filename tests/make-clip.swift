// make-clip: writes the test video for tests/mf-video with Apple's encoders: 2 seconds of H.264
// (High profile with B-frames, 320x240, 25 frames per second) and AAC (48 kHz, stereo) in an MP4.
// The picture has four quadrants, red, green, blue and white clockwise from top left, which move on
// by one quadrant after the first second; the left channel is a 440 Hz tone, the right one 1000 Hz,
// both at half of full scale.
// Build and run: xcrun swiftc -O -o make-clip make-clip.swift && ./make-clip clip.mp4
import AVFoundation

let width = 320, height = 240, fps = 25, seconds = 2
let rate = 48000, chunk = 1024
let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "clip.mp4"

func fail(_ message: String) -> Never {
  FileHandle.standardError.write("make-clip: \(message)\n".data(using: .utf8)!)
  exit(1)
}

// quadrant 0 top left, 1 top right, 2 bottom right, 3 bottom left; mf-video.c has the same table
let colors: [(r: UInt8, g: UInt8, b: UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255)]
func quadrantColor(_ q: Int, second: Int) -> (r: UInt8, g: UInt8, b: UInt8) { colors[(q - second + 4) % 4] }

func frame(_ n: Int, pool: CVPixelBufferPool) -> CVPixelBuffer {
  var buffer: CVPixelBuffer?
  guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let pb = buffer else {
    fail("no pixel buffer")
  }
  CVPixelBufferLockBaseAddress(pb, [])
  let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
  let pitch = CVPixelBufferGetBytesPerRow(pb)
  for y in 0..<height {
    for x in 0..<width {
      let q = y < height / 2 ? (x < width / 2 ? 0 : 1) : (x < width / 2 ? 3 : 2)
      let c = quadrantColor(q, second: n / fps)
      let p = base + y * pitch + x * 4  // BGRA
      p[0] = c.b; p[1] = c.g; p[2] = c.r; p[3] = 255
    }
  }
  CVPixelBufferUnlockBaseAddress(pb, [])
  return pb
}

let url = URL(fileURLWithPath: path)
try? FileManager.default.removeItem(at: url)
guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { fail("cannot write \(path)") }

let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
  AVVideoCodecKey: AVVideoCodecType.h264,
  AVVideoWidthKey: width,
  AVVideoHeightKey: height,
  AVVideoColorPropertiesKey: [
    AVVideoColorPrimariesKey: AVVideoColorPrimaries_SMPTE_C,
    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_601_4,
  ],
  AVVideoCompressionPropertiesKey: [
    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
    AVVideoAverageBitRateKey: 800_000,
    AVVideoMaxKeyFrameIntervalKey: fps,
    AVVideoExpectedSourceFrameRateKey: fps,
    AVVideoAllowFrameReorderingKey: true,
  ],
])
video.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
  kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
  kCVPixelBufferWidthKey as String: width,
  kCVPixelBufferHeightKey as String: height,
])

var layout = AudioChannelLayout()
layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
  AVFormatIDKey: kAudioFormatMPEG4AAC,
  AVSampleRateKey: rate,
  AVNumberOfChannelsKey: 2,
  AVEncoderBitRateKey: 128_000,
  AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
])
audio.expectsMediaDataInRealTime = false
guard writer.canAdd(video), writer.canAdd(audio) else { fail("cannot add the tracks") }
writer.add(video)
writer.add(audio)
guard writer.startWriting() else { fail("startWriting: \(writer.error?.localizedDescription ?? "?")") }
writer.startSession(atSourceTime: .zero)

var asbd = AudioStreamBasicDescription(
  mSampleRate: Float64(rate), mFormatID: kAudioFormatLinearPCM,
  mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
  mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
var pcmFormat: CMAudioFormatDescription?
CMAudioFormatDescriptionCreate(
  allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
  extensions: nil, formatDescriptionOut: &pcmFormat)

func tone(start: Int, count: Int) -> CMSampleBuffer {
  var samples = [Float](repeating: 0, count: count * 2)
  for i in 0..<count {
    let t = Double(start + i) / Double(rate)
    samples[2 * i] = Float(0.5 * sin(2 * Double.pi * 440 * t))
    samples[2 * i + 1] = Float(0.5 * sin(2 * Double.pi * 1000 * t))
  }
  var block: CMBlockBuffer?
  let bytes = count * 8
  CMBlockBufferCreateWithMemoryBlock(
    allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
    offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
  _ = samples.withUnsafeBytes {
    CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes)
  }
  var buffer: CMSampleBuffer?
  CMAudioSampleBufferCreateReadyWithPacketDescriptions(
    allocator: nil, dataBuffer: block!, formatDescription: pcmFormat!, sampleCount: count,
    presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(rate)),
    packetDescriptions: nil, sampleBufferOut: &buffer)
  return buffer!
}

// both tracks are fed from their own queue as the writer asks for data, so that it can interleave them
let group = DispatchGroup()
var nextFrame = 0, nextSample = 0
group.enter()
video.requestMediaDataWhenReady(on: DispatchQueue(label: "video")) {
  while video.isReadyForMoreMediaData {
    if nextFrame == fps * seconds { video.markAsFinished(); group.leave(); return }
    guard let pool = adaptor.pixelBufferPool else { fail("no pixel buffer pool") }
    if !adaptor.append(frame(nextFrame, pool: pool), withPresentationTime: CMTime(value: CMTimeValue(nextFrame), timescale: CMTimeScale(fps))) {
      fail("video: \(writer.error?.localizedDescription ?? "?")")
    }
    nextFrame += 1
  }
}
group.enter()
audio.requestMediaDataWhenReady(on: DispatchQueue(label: "audio")) {
  while audio.isReadyForMoreMediaData {
    if nextSample == rate * seconds { audio.markAsFinished(); group.leave(); return }
    let count = min(chunk, rate * seconds - nextSample)
    if !audio.append(tone(start: nextSample, count: count)) { fail("audio: \(writer.error?.localizedDescription ?? "?")") }
    nextSample += count
  }
}
group.wait()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else { fail("finishWriting: \(writer.error?.localizedDescription ?? "?")") }
print("wrote \(path): \(fps * seconds) frames \(width)x\(height) H.264, \(rate * seconds) samples AAC stereo")
