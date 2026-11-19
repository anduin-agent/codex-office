import Foundation
import ImageIO
import UniformTypeIdentifiers

struct OfficeRobotSkin: Sendable {
    enum ImportError: Error { case invalidImage, tooManyImages }

    struct Import: Sendable {
        let images: [Data]
        let skipped: Int
    }

    let file: URL
    private var legacyFile: URL { file.deletingLastPathComponent().appendingPathComponent("robot-skin.png") }
    private static let maximumImageCount = 256
    private static let maximumSourceBytes = 25 * 1024 * 1024
    private static let maximumEdge = 192
    private static let maximumStoredImageBytes = maximumEdge * maximumEdge * 5
    private static let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

    func load() -> [Data] {
        let archiveLimit = Self.maximumStoredImageBytes * Self.maximumImageCount + 1024 * 1024
        if let archive = Self.read(file, limit: archiveLimit),
           let images = try? PropertyListDecoder().decode([Data].self, from: archive),
           (1...Self.maximumImageCount).contains(images.count),
           images.allSatisfy({
               $0.count <= Self.maximumStoredImageBytes && ($0.starts(with: Self.pngSignature) || Self.isGIF($0))
           }) {
            return images
        }
        if let legacy = Self.read(legacyFile, limit: 384 * 384 * 5), legacy.starts(with: Self.pngSignature) {
            return [legacy]
        }
        return []
    }

    static func isGIF(_ data: Data) -> Bool {
        data.starts(with: "GIF89a".utf8) || data.starts(with: "GIF87a".utf8)
    }

    static func stillFrame(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let frame = firstFrame(source)
        else { return nil }
        return makePNG(frame)
    }

    private static func read(_ file: URL, limit: Int) -> Data? {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, (1...limit).contains(size),
              let data = try? Data(contentsOf: file), data.count <= limit
        else { return nil }
        return data
    }

    static func prepare(_ urls: [URL], folder: Bool) throws -> Import {
        let files: [URL]
        if folder {
            guard let directory = urls.first,
                  let children = try? FileManager.default.contentsOfDirectory(
                      at: directory, includingPropertiesForKeys: [.contentTypeKey, .isRegularFileKey],
                      options: [.skipsHiddenFiles]
                  )
            else { throw ImportError.invalidImage }
            files = children.filter {
                guard let info = try? $0.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey]) else { return false }
                return info.isRegularFile == true && info.contentType?.conforms(to: .image) == true
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        } else {
            files = urls
        }

        var images = [Data]()
        for file in files {
            guard let image = try? prepareImage(file) else { continue }
            guard images.count < maximumImageCount else { throw ImportError.tooManyImages }
            images.append(image)
        }
        guard !images.isEmpty else { throw ImportError.invalidImage }
        return Import(images: images, skipped: files.count - images.count)
    }

    private static func prepareImage(_ url: URL) throws -> Data {
        let file = url.resolvingSymlinksInPath()
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, (1...maximumSourceBytes).contains(size),
              let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...16_384).contains(width), (1...16_384).contains(height), width * height <= 64_000_000,
              let frame = firstFrame(source)
        else { throw ImportError.invalidImage }

        if CGImageSourceGetType(source) as String? == UTType.gif.identifier, width <= 512, height <= 512 {
            let frames = CGImageSourceGetCount(source)
            if (1...120).contains(frames), width * height * frames <= 8_000_000,
               let original = read(file, limit: maximumStoredImageBytes), isGIF(original) {
                return original
            }
        }
        guard let png = makePNG(frame) else { throw ImportError.invalidImage }
        return png
    }

    private static func firstFrame(_ source: CGImageSource) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumEdge,
        ] as CFDictionary)
    }

    private static func makePNG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let normalized = bitmap.makeImage() else { return nil }
        CGImageDestinationAddImage(destination, normalized, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    func save(_ images: [Data]) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let archive = try encoder.encode(images)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try archive.write(to: file, options: .atomic)
    }

    func remove() throws {
        for url in [legacyFile, file] {
            do {
                try FileManager.default.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // A legacy or current copy may already be absent.
            }
        }
    }
}
