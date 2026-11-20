// Encode PNG frames to H.264 MP4 and add a synthesised chime at a given time.
// swift encode.swift <framesDir> <fps> <chimeAtSeconds> <out.mp4>
import AVFoundation
import CoreGraphics
import ImageIO
import Foundation

let args = CommandLine.arguments
guard args.count == 5, let fps = Int32(args[2]), let chimeAt = Double(args[3]) else {
    FileHandle.standardError.write("usage: encode.swift <framesDir> <fps> <chimeAt> <out.mp4>\n".data(using: .utf8)!)
    exit(2)
}
let framesDir = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[4])
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nudge-encode-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

func loadImage(_ url: URL) -> CGImage {
    let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}

// ---- 1. frames -> silent H.264 video ----------------------------------------
let frameURLs = try FileManager.default.contentsOfDirectory(at: framesDir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
let first = loadImage(frameURLs[0])
let (w, h) = (first.width, first.height)
let videoURL = tmp.appendingPathComponent("video.mp4")
let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000,
                                      AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)
for (i, url) in frameURLs.enumerated() {
    while !input.isReadyForMoreMediaData { usleep(2000) }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    guard let buf = pb else { fatalError("no pixel buffer") }
    CVPixelBufferLockBaseAddress(buf, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.draw(loadImage(url), in: CGRect(x: 0, y: 0, width: w, height: h))
    CVPixelBufferUnlockBaseAddress(buf, [])
    adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else { fatalError("video write failed: \(String(describing: writer.error))") }

// ---- 2. synthesise a two-note chime (our own sound, nothing borrowed) ---------
let rate = 44_100.0, length = 1.8
let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
let chimeURL = tmp.appendingPathComponent("chime.caf")
let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(rate * length))!
pcm.frameLength = pcm.frameCapacity
let notes: [(start: Double, freq: Double, gain: Double)] = [(0.0, 1318.51, 0.32), (0.13, 1975.53, 0.26)]
for n in 0..<Int(pcm.frameLength) {
    let t = Double(n) / rate
    var s = 0.0
    for note in notes where t >= note.start {
        let u = t - note.start
        let env = min(1, u / 0.004) * exp(-u * 3.2)
        s += note.gain * env * (sin(2 * .pi * note.freq * u) + 0.25 * sin(2 * .pi * note.freq * 2.01 * u) * exp(-u * 6))
    }
    let v = Float(max(-1, min(1, s)))
    pcm.floatChannelData![0][n] = v
    pcm.floatChannelData![1][n] = v
}
do {
    let file = try AVAudioFile(forWriting: chimeURL, settings: fmt.settings)
    try file.write(from: pcm)
}

// ---- 3. mux video + chime at chimeAt -> mp4 --------------------------------------
let comp = AVMutableComposition()
let vAsset = AVURLAsset(url: videoURL), aAsset = AVURLAsset(url: chimeURL)
let vSrc = vAsset.tracks(withMediaType: .video)[0], aSrc = aAsset.tracks(withMediaType: .audio)[0]
let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
try vTrack.insertTimeRange(CMTimeRange(start: .zero, duration: vAsset.duration), of: vSrc, at: .zero)
let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
try aTrack.insertTimeRange(CMTimeRange(start: .zero, duration: aAsset.duration), of: aSrc,
                           at: CMTime(seconds: chimeAt, preferredTimescale: 600))
try? FileManager.default.removeItem(at: outURL)
let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough)!
export.outputURL = outURL
export.outputFileType = .mp4
export.shouldOptimizeForNetworkUse = true
export.exportAsynchronously { done.signal() }
done.wait()
guard export.status == .completed else { fatalError("export failed: \(String(describing: export.error))") }
print("encoded \(frameURLs.count) frames at \(w)x\(h), chime at \(chimeAt)s")
