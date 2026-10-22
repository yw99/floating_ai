import AppKit
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import Darwin

/// Every image entry point checks raster dimensions before asking a decoder to
/// allocate pixels. AppKit's `NSImage.size` is a size in points, not pixels.
public enum AttachmentImageCodec {
    public static let maximumPixels = 40_000_000
    public static let maximumDecodedBytes = 320_000_000
    public static let encodedTypeIdentifiers = [UTType.png.identifier, UTType.jpeg.identifier,
        UTType.heic.identifier, UTType.tiff.identifier, UTType.gif.identifier,
        UTType.webP.identifier, UTType.bmp.identifier]

    /// Prefer the provider's encoded bytes so metadata can be checked before
    /// AppKit decodes a dropped raster. Object-only providers use bounded decode.
    public static func importedData(from provider: NSItemProvider, completion: @escaping (Data?, String?) -> Void) {
        if let type = encodedTypeIdentifiers.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) ??
            provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let data, data.count > AttachmentStore.maximumFileBytes { completion(nil, AttachmentError.tooLarge.localizedDescription) }
                else { completion(data, error?.localizedDescription) }
            }
        } else {
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                do {
                    guard let image = object as? NSImage else { throw AttachmentError.malformed }
                    completion(try png(decode(image)), nil)
                } catch { completion(nil, error.localizedDescription) }
            }
        }
    }

    public static func validateRaster(width: Int, height: Int, bytesPerRow: Int? = nil,
                                      planes: Int = 1) throws {
        guard width > 0, height > 0, planes > 0 else { throw AttachmentError.malformed }
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow, pixels <= maximumPixels else { throw AttachmentImageError.dimensions }
        if let bytesPerRow {
            guard bytesPerRow > 0 else { throw AttachmentError.malformed }
            let (planeBytes, rowOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
            let (bytes, planeOverflow) = planeBytes.multipliedReportingOverflow(by: planes)
            guard !rowOverflow, !planeOverflow, bytes <= maximumDecodedBytes else { throw AttachmentImageError.storage }
        }
    }

    private static func dimension(_ value: Any?) throws -> Int {
        guard let number = value as? NSNumber else { throw AttachmentError.malformed }
        let value = number.doubleValue
        guard value.isFinite, value > 0, value.rounded(.down) == value,
              value <= Double(maximumPixels) else { throw AttachmentImageError.dimensions }
        return Int(value)
    }

    public static func decode(_ data: Data) throws -> CGImage {
        guard data.count <= AttachmentStore.maximumFileBytes else { throw AttachmentError.tooLarge }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] else {
            throw AttachmentError.malformed
        }
        let width = try dimension(properties[kCGImagePropertyPixelWidth])
        let height = try dimension(properties[kCGImagePropertyPixelHeight])
        try validateRaster(width: width, height: height)
        // ImageIO's supported integer raster formats need at most 16-bit RGBA.
        // Reject larger samples rather than allocating an unbounded intermediate.
        let depth = (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 8
        guard depth > 0, depth <= 16 else { throw AttachmentImageError.storage }
        let (rowBytes, overflow) = width.multipliedReportingOverflow(by: depth > 8 ? 8 : 4)
        guard !overflow else { throw AttachmentImageError.storage }
        try validateRaster(width: width, height: height, bytesPerRow: rowBytes)
        // Transform the first frame at its original pixel size, including EXIF
        // orientation; never silently shrink an image that exceeds the limit.
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions as CFDictionary) else {
            throw AttachmentError.malformed
        }
        try validate(image)
        return image
    }

    /// Read and validate the same regular-file descriptor, including if the
    /// source changes while being read. No symbolic link or unbounded Data read.
    public static func decode(fileURL: URL) throws -> CGImage {
        guard fileURL.isFileURL else { throw AttachmentError.invalidFile }
        let input = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard input >= 0 else { throw AttachmentError.unreadable }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw AttachmentError.invalidFile }
        guard info.st_size >= 0, info.st_size <= AttachmentStore.maximumFileBytes else { throw AttachmentError.tooLarge }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(input, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw AttachmentError.unreadable }
            guard data.count <= Int(AttachmentStore.maximumFileBytes) - count else { throw AttachmentError.tooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
        return try decode(data)
    }

    public static func decode(_ image: NSImage, maximumOutputDimension: Int? = nil) throws -> CGImage {
        if let limit = maximumOutputDimension, limit <= 0 { throw AttachmentError.malformed }
        let representations = image.representations
        guard !representations.isEmpty else { throw AttachmentError.malformed }
        var rasters: [(representation: NSImageRep, width: Int, height: Int)] = []
        for representation in representations {
            if let bitmap = representation as? NSBitmapImageRep {
                try validateRaster(width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
                                   bytesPerRow: bitmap.bytesPerRow,
                                   planes: bitmap.isPlanar ? bitmap.samplesPerPixel : 1)
                guard bitmap.bitsPerSample > 0, bitmap.bitsPerSample <= 16 else { throw AttachmentImageError.storage }
                rasters.append((bitmap, bitmap.pixelsWide, bitmap.pixelsHigh))
                continue
            }
            var width = representation.pixelsWide, height = representation.pixelsHigh
            if let ci = representation as? NSCIImageRep {
                // A CI image is a raster even if its NSImage logical size or
                // mutable representation metadata claims otherwise.
                let extent = ci.ciImage.extent.integral
                guard !extent.isInfinite, !extent.isNull,
                      extent.origin.x.isFinite, extent.origin.y.isFinite else { throw AttachmentImageError.dimensions }
                let ciWidth = try dimension(NSNumber(value: Double(extent.width)))
                let ciHeight = try dimension(NSNumber(value: Double(extent.height)))
                try validateRaster(width: ciWidth, height: ciHeight, bytesPerRow: ciWidth * 8)
                if let underlying = ci.ciImage.cgImage { try validate(underlying) }
                width = max(width, ciWidth); height = max(height, ciHeight)
            }
            if width != 0 || height != 0 {
                try validateRaster(width: width, height: height)
                guard representation.bitsPerSample >= 0, representation.bitsPerSample <= 16 else { throw AttachmentImageError.storage }
                // Non-bitmap raster reps (including PDFKit's snapshot reps)
                // expose pixel dimensions, though not their exact row stride.
                // Bound a conservative 16-bit RGBA raster before drawing.
                try validateRaster(width: width, height: height, bytesPerRow: width * 8)
                rasters.append((representation, width, height))
            } else {
                // Zero means "matches the device" in NSImageRep. Only known
                // vector or drawing representations may use point dimensions.
                guard representation is NSPDFImageRep || representation is NSEPSImageRep ||
                        representation is NSCustomImageRep else { throw AttachmentImageError.representation }
            }
        }
        if let selected = rasters.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            if let bitmap = selected.representation as? NSBitmapImageRep,
               maximumOutputDimension.map({ max(selected.width, selected.height) <= $0 }) ?? true {
                guard let raster = bitmap.cgImage else { throw AttachmentError.malformed }
                try validate(raster)
                return raster
            }
            return try render(selected.representation, width: selected.width, height: selected.height,
                              maximumDimension: maximumOutputDimension)
        }
        // Only actual vector/drawing representations remain. Render at
        // 1 px/point into a context whose allocation is explicitly bounded.
        let width = try dimension(NSNumber(value: Double(image.size.width.rounded(.up))))
        let height = try dimension(NSNumber(value: Double(image.size.height.rounded(.up))))
        return try render(representations[0], width: width, height: height, maximumDimension: maximumOutputDimension)
    }

    private static func render(_ representation: NSImageRep, width sourceWidth: Int, height sourceHeight: Int,
                               maximumDimension: Int?) throws -> CGImage {
        // Thumbnail sizing happens only after validating the source raster.
        try validateRaster(width: sourceWidth, height: sourceHeight)
        let ratio = min(1, Double(maximumDimension ?? max(sourceWidth, sourceHeight)) / Double(max(sourceWidth, sourceHeight)))
        let width = max(1, Int((Double(sourceWidth) * ratio).rounded(.down)))
        let height = max(1, Int((Double(sourceHeight) * ratio).rounded(.down)))
        try validateRaster(width: width, height: height, bytesPerRow: width * 4)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AttachmentError.malformed
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        guard representation.draw(in: NSRect(x: 0, y: 0, width: width, height: height)) else { throw AttachmentError.malformed }
        guard let raster = context.makeImage() else { throw AttachmentError.malformed }
        try validate(raster)
        return raster
    }

    private static func validate(_ image: CGImage) throws {
        try validateRaster(width: image.width, height: image.height, bytesPerRow: image.bytesPerRow)
    }

    public static func png(_ image: CGImage) throws -> Data { try encode(image, type: UTType.png.identifier) }
    public static func jpeg(_ image: CGImage, quality: Double = 0.75) throws -> Data {
        try encode(image, type: UTType.jpeg.identifier, properties: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    private static func encode(_ image: CGImage, type: String, properties: [CFString: Any] = [:]) throws -> Data {
        try validate(image)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else { throw AttachmentError.malformed }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AttachmentError.malformed }
        guard output.length <= AttachmentStore.maximumFileBytes else { throw AttachmentError.tooLarge }
        return output as Data
    }
}

public enum AttachmentImageError: Error, LocalizedError {
    case dimensions, storage, representation
    public var errorDescription: String? {
        switch self {
        case .dimensions: return "This image exceeds the 40,000,000-pixel limit. Resize it before attaching it."
        case .storage: return "This image exceeds the 320,000,000-byte decoded-image limit. Resize it or reduce its color depth."
        case .representation: return "This image representation cannot be safely read. Export it as PNG, JPEG, HEIC, or TIFF first."
        }
    }
}
