import AppKit
import FloatingAICore
import ImageIO
import UniformTypeIdentifiers
import CoreImage

private struct Failure: Error { let message: String }
private final class UndescribedImageRep: NSImageRep {
    override func draw() -> Bool { fatalError("A representation without verifiable raster or vector metadata must not draw") }
}
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(message: message) }
}

private func rejected(_ body: () throws -> Void, _ message: String) throws {
    do { try body() } catch is AttachmentImageError { return } catch is AttachmentError { return }
    throw Failure(message: message)
}

private func encodedImage(_ image: CGImage, type: String = UTType.png.identifier,
                          properties: [CFString: Any] = [:], frames: Int = 1) throws -> Data {
    let data = NSMutableData()
    guard let writer = CGImageDestinationCreateWithData(data, type as CFString, frames, nil) else {
        throw Failure(message: "Image fixture encoder is unavailable: \(type)")
    }
    for _ in 0..<frames { CGImageDestinationAddImage(writer, image, properties as CFDictionary) }
    try check(CGImageDestinationFinalize(writer), "Image fixture encoding failed: \(type)")
    return data as Data
}

private func monochromeImage(width: Int, height: Int) throws -> CGImage {
    let row = (width + 7) / 8
    let bytes = Data(repeating: 0, count: row * height)
    guard let provider = CGDataProvider(data: bytes as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 1, bitsPerPixel: 1,
                              bytesPerRow: row, space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: [], provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
        throw Failure(message: "Could not create image fixture")
    }
    return image
}

@MainActor private func imageChecks(root: URL) async throws {
    try AttachmentImageCodec.validateRaster(width: 8000, height: 5000, bytesPerRow: 64_000)
    try rejected({ try AttachmentImageCodec.validateRaster(width: 8001, height: 5000) }, "Pixel limit boundary was accepted")
    try rejected({ try AttachmentImageCodec.validateRaster(width: 8000, height: 5000, bytesPerRow: 64_001) }, "Decoded-byte boundary was accepted")
    try rejected({ try AttachmentImageCodec.validateRaster(width: Int.max, height: Int.max) }, "Overflowing dimensions were accepted")
    try rejected({ try AttachmentImageCodec.validateRaster(width: 1, height: 2, bytesPerRow: Int.max) }, "Overflowing row storage was accepted")
    try rejected({ try AttachmentImageCodec.validateRaster(width: 1, height: 2, bytesPerRow: 10, planes: Int.max) }, "Overflowing planar storage was accepted")
    try rejected({ _ = try AttachmentImageCodec.decode(Data("not an image".utf8)) }, "Malformed image was accepted")
    try rejected({ _ = try AttachmentImageCodec.decode(Data(repeating: 0, count: Int(AttachmentStore.maximumFileBytes) + 1)) }, "Encoded file limit was bypassed")

    let large = try monochromeImage(width: 9000, height: 5000)
    let ordinary = try encodedImage(large, properties: [kCGImagePropertyDPIWidth: 72, kCGImagePropertyDPIHeight: 72])
    let highDPI = try encodedImage(large, properties: [kCGImagePropertyDPIWidth: 720, kCGImagePropertyDPIHeight: 720])
    for data in [ordinary, highDPI] {
        try rejected({ _ = try AttachmentImageCodec.decode(data) }, "45-million-pixel raster was accepted")
    }
    let small = try monochromeImage(width: 50, height: 30)
    let smallData = try encodedImage(small, properties: [kCGImagePropertyDPIWidth: 720, kCGImagePropertyDPIHeight: 720])
    let decoded = try AttachmentImageCodec.decode(smallData)
    try check(decoded.width == 50 && decoded.height == 30, "Small high-DPI raster lost pixels")
    guard let context = CGContext(data: nil, width: 50, height: 30, bitsPerComponent: 8, bytesPerRow: 200,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
          let color = context.makeImage() else { throw Failure(message: "Color fixture allocation failed") }
    for type in [UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier, UTType.heic.identifier,
                 UTType.gif.identifier, UTType.bmp.identifier] {
        let data = try encodedImage(color, type: type)
        let raster = try AttachmentImageCodec.decode(data)
        try check(raster.width == 50 && raster.height == 30, "Raster dimensions changed for \(type)")
    }
    let oriented = try encodedImage(color, type: UTType.jpeg.identifier, properties: [kCGImagePropertyOrientation: 6])
    let upright = try AttachmentImageCodec.decode(oriented)
    try check(upright.width == 30 && upright.height == 50, "EXIF orientation was not applied")
    let nativeUpright = try AttachmentImageCodec.decode(NSImage(data: oriented)!)
    try check(nativeUpright.width == 30 && nativeUpright.height == 50, "Object-only JPEG import lost EXIF orientation")
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 50, height: 30))
    let firstFrame = context.makeImage()!
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 50, height: 30))
    let secondFrame = context.makeImage()!
    let animatedData = NSMutableData()
    let animation = CGImageDestinationCreateWithData(animatedData, UTType.gif.identifier as CFString, 2, nil)!
    CGImageDestinationAddImage(animation, firstFrame, nil)
    CGImageDestinationAddImage(animation, secondFrame, nil)
    try check(CGImageDestinationFinalize(animation), "Animated fixture encoding failed")
    let animated = animatedData as Data
    try check(CGImageSourceGetCount(CGImageSourceCreateWithData(animated as CFData, nil)!) == 2, "Animated fixture did not have two frames")
    let firstPixel = NSBitmapImageRep(cgImage: try AttachmentImageCodec.decode(animated)).colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB)
    try check(firstPixel != nil && firstPixel!.redComponent > 0.9 && firstPixel!.blueComponent < 0.1,
              "Animated image import did not use the first frame")
    let native = NSBitmapImageRep(cgImage: large)
    native.size = NSSize(width: 900, height: 500)
    let nativeImage = NSImage(size: native.size)
    nativeImage.addRepresentation(native)
    try rejected({ _ = try AttachmentImageCodec.decode(nativeImage) }, "Native bitmap used logical size instead of raster dimensions")
    try rejected({ _ = try AttachmentImageCodec.decode(nativeImage, maximumOutputDimension: 1600) },
                 "Thumbnail sizing bypassed validation of oversized source pixels")
    let ci = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
    let ciRepresentation = NSCIImageRep(ciImage: ci.cropped(to: CGRect(x: 0, y: 0, width: 9000, height: 5000)))
    ciRepresentation.size = NSSize(width: 900, height: 500)
    let ciImage = NSImage(size: ciRepresentation.size)
    ciImage.addRepresentation(ciRepresentation)
    try rejected({ _ = try AttachmentImageCodec.decode(ciImage) }, "Oversized CI raster used logical point dimensions")
    ciRepresentation.pixelsWide = 0; ciRepresentation.pixelsHigh = 0
    try rejected({ _ = try AttachmentImageCodec.decode(ciImage) }, "CI raster hid its extent with mutable pixel metadata")
    let smallCI = NSCIImageRep(ciImage: ci.cropped(to: CGRect(x: 10, y: 20, width: 50, height: 30)))
    smallCI.size = NSSize(width: 5, height: 3)
    let smallCIImage = NSImage(size: smallCI.size)
    smallCIImage.addRepresentation(smallCI)
    let decodedCI = try AttachmentImageCodec.decode(smallCIImage)
    try check(decodedCI.width == 50 && decodedCI.height == 30, "Valid CI raster lost pixels at high DPI")
    let customRaster = NSCustomImageRep(size: NSSize(width: 900, height: 500), flipped: false) { _ in
        fatalError("An oversized custom raster must not draw")
    }
    customRaster.pixelsWide = 9000; customRaster.pixelsHigh = 5000
    let customRasterImage = NSImage(size: customRaster.size)
    customRasterImage.addRepresentation(customRaster)
    try rejected({ _ = try AttachmentImageCodec.decode(customRasterImage) }, "Custom raster dimensions were not checked")
    let unknownImage = NSImage(size: NSSize(width: 50, height: 30))
    unknownImage.addRepresentation(UndescribedImageRep())
    try rejected({ _ = try AttachmentImageCodec.decode(unknownImage) }, "Unknown representation was treated as a vector")
    let vector = NSImage(size: NSSize(width: 50, height: 30), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
    try check(try AttachmentImageCodec.decode(vector).width == 50, "Bounded drawing-handler image failed")
    let hugeVector = NSImage(size: NSSize(width: 9000, height: 5000), flipped: false) { _ in
        fatalError("An oversized vector should not be rendered")
    }
    try rejected({ _ = try AttachmentImageCodec.decode(hugeVector) }, "Oversized vector was accepted")
    print("PASS: image pixel/byte/overflow boundaries, DPI, formats, orientation, first frame, native/CI/custom rasters and bounded vector")

    let dataRoot = root.appendingPathComponent("image-app")
    let store = AppStore(directory: dataRoot, previewAuthentication: (.codexSignIn, false))
    let note = store.createNote(title: "Image safety", model: "fixture", effort: "medium")
    let input = root.appendingPathComponent("large-high-dpi.png")
    try highDPI.write(to: input)
    store.attachFiles([input], to: note)
    for _ in 0..<500 {
        if !note.isImportingFiles { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try check(!note.isImportingFiles, "Image import timed out")
    try check(note.error?.contains("40,000,000-pixel") == true, "File import did not report the pixel limit")
    store.attachImage(nativeImage, to: note)
    try check(note.error?.contains("40,000,000-pixel") == true, "Native paste bypassed pixel validation")
    store.attachImageData(highDPI, to: note)
    try check(note.error?.contains("40,000,000-pixel") == true, "Encoded paste bypassed pixel validation")
    let dropped = NSItemProvider()
    dropped.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
        completion(highDPI, nil); return nil
    }
    let (dropData, dropError): (Data?, String?) = await withCheckedContinuation { continuation in
        AttachmentImageCodec.importedData(from: dropped) { continuation.resume(returning: ($0, $1)) }
    }
    try check(dropError == nil && dropData == highDPI, "Drop importer did not preserve encoded data")
    store.attachImageData(dropData!, to: note)
    try check(note.attachments.isEmpty && note.fileLibrary.isEmpty, "Rejected image left attachment metadata")
    let folder = AttachmentStore(directory: dataRoot).noteDirectory(note.id)
    try check(!FileManager.default.fileExists(atPath: folder.path) || (try FileManager.default.contentsOfDirectory(atPath: folder.path)).isEmpty,
              "Rejected image left a stored copy")
    let link = root.appendingPathComponent("linked-image.png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: input)
    try rejected({ _ = try AttachmentImageCodec.decode(fileURL: link) }, "Image file decoder followed a symbolic link")
    store.attachImageData(smallData, to: note)
    try check(note.attachments.count == 1 && note.fileLibrary.count == 1, "Valid high-DPI image was rejected")
    let stored = try AttachmentImageCodec.decode(fileURL: URL(fileURLWithPath: note.attachments[0].path))
    try check(stored.width == 50 && stored.height == 30, "Stored image dimensions changed")
    await store.shutdown()
    print("PASS: file/paste/drop image entry points, rejected images leave no copy, symlink denial, valid high-DPI import")
}

@main enum FileChecks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floating-files-store-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await imageChecks(root: root)
        let dataRoot = root.appendingPathComponent("app")
        let store = AppStore(directory: dataRoot, previewAuthentication: (.codexSignIn, false))
        let first = store.createNote(title: "Files", model: "fixture", effort: "medium")
        let second = store.createNote(title: "Private", model: "fixture", effort: "medium")
        let original = root.appendingPathComponent("A very long 文件 name with spaces & dollar $ symbols.txt")
        try Data("Owned file content 中文".utf8).write(to: original)
        store.attachFiles([original], to: first)
        try check(first.isImportingFiles && !store.canDeleteNote(first), "Import did not reserve the note")
        for _ in 0..<500 {
            if !first.isImportingFiles { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try check(first.attachments.count == 1 && store.files(for: first).count == 1, "Add Files did not attach to the current message and library")
        let file = first.attachments[0]
        let imageBytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVv8AAAAASUVORK5CYII=")!
        let savedImage = try AttachmentStore(directory: dataRoot).storePNG(imageBytes, noteID: second.id, name: "Screenshot.png")
        second.fileLibrary = [savedImage]
        try check(savedImage.isImage && (try Data(contentsOf: URL(fileURLWithPath: savedImage.path))) == imageBytes, "PNG import failed or changed bytes")
        try check((try FileManager.default.attributesOfItem(atPath: savedImage.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                  "PNG copy permissions are not private")
        try check(!file.isImage && file.name == original.lastPathComponent && file.path != original.path, "Document metadata/copy is wrong")
        try check(try Data(contentsOf: URL(fileURLWithPath: file.path)) == Data(contentsOf: original), "Copied data changed")
        store.referenceFiles([file.id], in: second)
        try check(second.attachments.isEmpty && store.files(for: second) == [savedImage], "Another note could reference or see this library")
        store.removeAttachment(file, from: first)
        try check(first.attachments.isEmpty && store.files(for: first).count == 1, "Removing from draft destroyed library")
        store.referenceFiles([file.id], in: first)
        store.referenceFiles([file.id], in: first)
        try check(first.attachments == [file], "Reusing file lost or duplicated attachment")
        first.draft = "Read this file"
        first.compactWidth = 410; first.compactHeight = 72
        store.persist()
        try FileManager.default.removeItem(at: original)
        let restored = AppStore(directory: dataRoot, previewAuthentication: (.codexSignIn, false))
        let recovered = restored.notes.first { $0.id == first.id }!
        try check(recovered.attachments == [file] && recovered.fileLibrary == [file] && recovered.draft == first.draft,
                  "Draft/library did not restore independently of original file")
        try check(recovered.compactWidth == 410 && recovered.compactHeight == 72, "Compact size was lost")
        await restored.shutdown()
        print("PASS: import → draft, note-private reuse/dedup, remove draft, deleted original, restart persistence")

        let encoded = AttachmentMessage.encode(text: "正文\n[example]", attachments: [file])
        let item: JSONValue = ["id": "new", "type": "userMessage", "content": [["type": "text", "text": .string(encoded)]]]
        let decoded = Transcript.message(from: item)!
        let pending = PendingMessage(text: "正文\n[example]", attachments: [file], model: "fixture", effort: "medium", previousUserMessageID: "old")
        try check(decoded.text == pending.text && decoded.fileAttachments == [file] && decoded.imagePaths.isEmpty,
                  "Native history did not restore document card/original text")
        try check(pending.matchesNewReceipt(decoded), "Document receipt could not reconcile pending message")
        let quotedEnvelope = AttachmentMessage.encode(text: encoded, attachments: [])
        try check(AttachmentMessage.decode(quotedEnvelope).text == encoded && AttachmentMessage.decode(quotedEnvelope).files.isEmpty,
                  "A user quoting an attachment manifest lost their literal message")
        let image = StoredAttachment(path: "/legacy.png", name: "legacy.png")
        try check(image.isImage, "Legacy image decoding changed")
        print("PASS: native history envelope and pending receipt reconciliation")

        let target = ChatModel(provider: .claude, model: CodexModel(id: "fixture", displayName: "Fixture", defaultReasoningEffort: "medium", supportedReasoningEfforts: [.init(reasoningEffort: "medium", description: "")]))
        first.messages = [decoded]
        let copy = store.copyConversation(first, to: target)
        try check(copy.attachments.count == 1 && copy.attachments[0].path != file.path, "Copy History shares files")
        let copyPath = copy.attachments[0].path
        try check(AttachmentStore(directory: dataRoot).owns(copy.attachments[0], noteID: copy.id), "Copy does not own its files")
        let scratch = dataRoot.appendingPathComponent("FileScratch").appendingPathComponent(first.id.uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Data("scratch".utf8).write(to: scratch.appendingPathComponent("temporary"))
        await store.deleteNote(first)
        try check(!store.notes.contains { $0.id == first.id } && !FileManager.default.fileExists(atPath: file.path), "Deleting note retained its file")
        try check(!FileManager.default.fileExists(atPath: scratch.path), "Deleting note retained its analysis scratch data")
        try check(FileManager.default.fileExists(atPath: copyPath), "Deleting original broke independently copied note")
        await store.deleteNote(copy)
        try check(!FileManager.default.fileExists(atPath: copyPath), "Deleting copied note left its private files")
        print("PASS: independent cross-provider copies and note deletion/scratch cleanup")
        await store.deleteNote(second)
        try check(!FileManager.default.fileExists(atPath: savedImage.path), "Deleting note did not delete owned image")
        await store.shutdown()
    }
}
