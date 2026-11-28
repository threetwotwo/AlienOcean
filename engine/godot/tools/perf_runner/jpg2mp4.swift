import AVFoundation; import AppKit
let a = CommandLine.arguments; let dir = a[1], out = a[2]; let W = Int(a[3])!, H = Int(a[4])!, fps = Int32(a[5])!
let files = try! FileManager.default.contentsOfDirectory(atPath: dir).filter{$0.hasSuffix(".jpg")}.sorted()
try? FileManager.default.removeItem(atPath: out)
let w = try! AVAssetWriter(outputURL: URL(fileURLWithPath: out), fileType: .mp4)
let inp = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000]])
let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: inp, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H])
w.add(inp); w.startWriting(); w.startSession(atSourceTime: .zero)
for (i, f) in files.enumerated() {
  guard let img = NSImage(contentsOfFile: dir + "/" + f), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
  var pb: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, ad.pixelBufferPool!, &pb)
  CVPixelBufferLockBaseAddress(pb!, [])
  let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: W, height: H, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb!), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
  ctx.interpolationQuality = .high; ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
  CVPixelBufferUnlockBaseAddress(pb!, [])
  while !inp.isReadyForMoreMediaData { usleep(1000) }
  ad.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
}
inp.markAsFinished(); let sem = DispatchSemaphore(value: 0); w.finishWriting { sem.signal() }; sem.wait(); print("wrote", files.count, "frames")
