import AppKit
import PDFKit
import Foundation
import FloatingAICore
import Darwin

enum FileReader {
    static let textLimit = 120_000
    private static func bounded(_ text: String) -> String {
        guard text.utf8.count > 160_000 else { return text }
        return String(decoding: text.utf8.prefix(159_800), as: UTF8.self) + "\n[Output truncated; ask for a specific PDF page or use a smaller file.]"
    }
    private static func imageContent(_ image: CGImage) throws -> JSONValue {
        if let png = try? AttachmentImageCodec.png(image), png.count <= 5_500_000 {
            return ["mimeType": "image/png", "data": .string(png.base64EncodedString())]
        }
        let jpeg = try AttachmentImageCodec.jpeg(image)
        guard jpeg.count <= 5_500_000 else { throw AttachmentError.malformed }
        return ["mimeType": "image/jpeg", "data": .string(jpeg.base64EncodedString())]
    }
    static func read(context: FileAccessContext, path: String, page: Int?) throws -> JSONValue {
        let data = try context.readData(path: path)
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        var text: String
        switch ext {
        case "pdf":
            guard let document = PDFDocument(data: data), !document.isLocked else { throw AttachmentError.malformed }
            if let number = page {
                guard number >= 1, number <= document.pageCount, let pdfPage = document.page(at: number - 1) else { throw AttachmentError.malformed }
                let thumbnail = pdfPage.thumbnail(of: NSSize(width: 1600, height: 1600), for: .mediaBox)
                return ["text": .string(bounded("PDF page \(number) of \(document.pageCount)\n" + (pdfPage.string ?? ""))),
                        "images": .array([try imageContent(AttachmentImageCodec.decode(thumbnail, maximumOutputDimension: 1600))])]
            }
            text = "PDF: \(document.pageCount) pages. Use page (1-based) to inspect a page visually.\n"
            for index in 0..<document.pageCount {
                text += "\n[Page \(index + 1)]\n" + (document.page(at: index)?.string ?? "")
                if text.count > textLimit { break }
            }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 150 {
                text += "\nThis PDF may be scanned. Request a page to receive its image."
            }
        case "docx", "xlsx": text = try office(data, ext: ext, scratch: context.scratchDirectory)
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp":
            return ["text": "Image attachment", "images": .array([try imageContent(AttachmentImageCodec.decode(data))])]
        case "doc", "xls", "ppt", "pptx", "zip", "dmg", "app", "exe": throw AttachmentError.unsupported
        default:
            guard data.count <= 8 * 1024 * 1024 else { throw AttachmentError.tooLarge }
            if let value = String(data: data, encoding: .utf8), !value.contains("\0") { text = value }
            else if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let value = String(data: data, encoding: .utf16) { text = value }
            else { throw AttachmentError.unsupported }
        }
        let truncated = text.count > textLimit || text.utf8.count > 160_000
        return ["text": .string(bounded(String(text.prefix(textLimit)) + (truncated ? "\n[Output truncated; ask for a specific PDF page or use a smaller file.]" : ""))),
                "images": [], "truncated": .bool(truncated)]
    }

    private static func office(_ data: Data, ext: String, scratch: URL) throws -> String {
        try AttachmentStore.rejectLinkedDirectories([scratch.deletingLastPathComponent(), scratch])
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for candidate in [scratch, scratch.deletingLastPathComponent()] {
            guard try candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AttachmentError.outsideNote }
        }
        let work = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let archive = work.appendingPathComponent("document.zip")
        try data.write(to: archive, options: .atomic)
        if ext == "docx" {
            let document = DocumentXML()
            try parse(try member("word/document.xml", archive: archive), delegate: document)
            return "Word document (text and tables; layout and embedded objects are not included):\n" + document.text
        }
        let workbook = WorkbookXML()
        try parse(try member("xl/workbook.xml", archive: archive), delegate: workbook)
        let relationships = RelationshipsXML()
        try parse(try member("xl/_rels/workbook.xml.rels", archive: archive), delegate: relationships)
        let shared = SharedStringsXML()
        if let xml = try? member("xl/sharedStrings.xml", archive: archive) { try parse(xml, delegate: shared) }
        guard !shared.truncated else { throw AttachmentError.malformed }
        var text = "Excel workbook: stored values/formulas only; formulas are not recalculated. Dates may be stored as serial numbers.\n"
        for sheet in workbook.sheets.prefix(50) {
            guard let target = relationships.targets[sheet.id] else { continue }
            let part = target.hasPrefix("/xl/") ? String(target.dropFirst()) : "xl/" + target
            guard part.hasPrefix("xl/worksheets/"), part.hasSuffix(".xml"), !part.contains(".."),
                  part.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "/_- .".unicodeScalars.contains($0) }) else { continue }
            let reader = WorksheetXML(shared: shared.strings)
            try parse(try member(part, archive: archive), delegate: reader)
            text += "\n[Sheet: \(sheet.name)]\n" + reader.text
            if text.count > textLimit { break }
        }
        if workbook.sheets.count > 50 { text += "\n[Only the first 50 sheets are included.]" }
        return text
    }

    private static func parse(_ data: Data, delegate: BoundedXML) throws {
        guard data.count <= 8 * 1024 * 1024 else { throw AttachmentError.malformed }
        // External entities and DTDs are not part of supported Office content.
        let source = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? ""
        if source.contains("<!DOCTYPE") || source.contains("<!ENTITY") { throw AttachmentError.malformed }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.delegate = delegate
        let parsed = parser.parse()
        guard delegate.hasValidRoot, !delegate.invalidRoot,
              parsed || delegate.truncated else { throw AttachmentError.malformed }
    }

    private static func member(_ name: String, archive: URL) throws -> Data {
        let process = Process(), pipe = Pipe()
        let exited = DispatchGroup()
        exited.enter()
        process.terminationHandler = { _ in exited.leave() }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, name]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; process.standardOutput = pipe
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        var data = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            if data.count + chunk.count > 8 * 1024 * 1024 {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                exited.wait()
                throw AttachmentError.malformed
            }
            data.append(chunk)
        }
        exited.wait()
        guard process.terminationStatus == 0 else { throw AttachmentError.malformed }
        return data
    }
}

private enum OfficeNamespace {
    static let word: Set<String> = [
        "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
        "http://purl.oclc.org/ooxml/wordprocessingml/main"
    ]
    static let spreadsheet: Set<String> = [
        "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
        "http://purl.oclc.org/ooxml/spreadsheetml/main"
    ]
    static let documentRelationships: Set<String> = [
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
        "http://purl.oclc.org/ooxml/officeDocument/relationships"
    ]
    // Strict and Transitional documents both use the OPC package namespace.
    static let packageRelationships: Set<String> = ["http://schemas.openxmlformats.org/package/2006/relationships"]
}

private class BoundedXML: NSObject, XMLParserDelegate {
    var truncated = false
    var characters = 0
    private(set) var hasValidRoot = false
    private(set) var invalidRoot = false
    private let rootName: String
    private let namespaces: Set<String>
    private let allowsNamespaceFree: Bool
    private var rootNamespace = ""
    private var elements: [(name: String, namespace: String)] = []
    private var prefixes: [String: [String]] = [:]

    init(rootName: String, namespaces: Set<String>, allowsNamespaceFree: Bool = false) {
        self.rootName = rootName
        self.namespaces = namespaces
        self.allowsNamespaceFree = allowsNamespaceFree
    }

    func limit(_ parser: XMLParser, amount: Int) -> Bool {
        characters += amount
        if characters > 500_000 { truncated = true; parser.abortParsing(); return true }
        return false
    }

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        prefixes[prefix, default: []].append(namespaceURI)
    }
    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
        prefixes[prefix]?.removeLast()
        if prefixes[prefix]?.isEmpty == true { prefixes.removeValue(forKey: prefix) }
    }

    // XMLParser leaves attribute names qualified even when element names are local.
    // Keep each prefix's scope so a nested rebinding cannot impersonate r:id.
    func attribute(_ name: String, namespaces: Set<String>, in attributes: [String: String]) -> String? {
        for (qualifiedName, value) in attributes {
            let parts = qualifiedName.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[1] == name,
                  let namespace = prefixes[String(parts[0])]?.last, namespaces.contains(namespace) else { continue }
            return value
        }
        return nil
    }

    func isCurrent(_ name: String) -> Bool {
        guard let element = elements.last else { return false }
        return element.name == name && element.namespace == rootNamespace
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let namespace = namespaceURI ?? ""
        if elements.isEmpty {
            guard !hasValidRoot, elementName == rootName,
                  namespaces.contains(namespace) || (allowsNamespaceFree && namespace.isEmpty) else {
                invalidRoot = true
                parser.abortParsing()
                return
            }
            hasValidRoot = true
            rootNamespace = namespace
        }
        elements.append((elementName, namespace))
        if namespace == rootNamespace { startElement(parser, name: elementName, attributes: attributes) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if (namespaceURI ?? "") == rootNamespace { endElement(parser, name: elementName) }
        if !elements.isEmpty { elements.removeLast() }
    }

    func startElement(_ parser: XMLParser, name: String, attributes: [String: String]) {}
    func endElement(_ parser: XMLParser, name: String) {}
}

private final class DocumentXML: BoundedXML {
    var text = ""
    init() { super.init(rootName: "document", namespaces: OfficeNamespace.word) }
    override func startElement(_ parser: XMLParser, name: String, attributes: [String: String]) {
        if name == "tab" { text += "\t" }
        if name == "br" { text += "\n" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isCurrent("t"), !limit(parser, amount: string.count) { text += string }
    }
    override func endElement(_ parser: XMLParser, name: String) {
        if name == "p" || name == "tr" { text += "\n" }
        if name == "tc" { text += "\t" }
    }
}

private final class WorkbookXML: BoundedXML {
    var sheets: [(name: String, id: String)] = []
    init() { super.init(rootName: "workbook", namespaces: OfficeNamespace.spreadsheet, allowsNamespaceFree: true) }
    override func startElement(_ parser: XMLParser, name: String, attributes: [String: String]) {
        if name == "sheet", let sheetName = attributes["name"],
           let id = attribute("id", namespaces: OfficeNamespace.documentRelationships, in: attributes), sheets.count < 1000 {
            sheets.append((sheetName, id))
        }
    }
}

private final class RelationshipsXML: BoundedXML {
    var targets: [String: String] = [:]
    init() { super.init(rootName: "Relationships", namespaces: OfficeNamespace.packageRelationships, allowsNamespaceFree: true) }
    override func startElement(_ parser: XMLParser, name: String, attributes: [String: String]) {
        if name == "Relationship", attributes["TargetMode"] != "External", let id = attributes["Id"], let target = attributes["Target"], targets.count < 2000 { targets[id] = target }
    }
}

private final class SharedStringsXML: BoundedXML {
    var strings: [String] = [], current = ""
    init() { super.init(rootName: "sst", namespaces: OfficeNamespace.spreadsheet, allowsNamespaceFree: true) }
    override func startElement(_ parser: XMLParser, name: String, attributes: [String: String]) {
        if name == "si" { current = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if isCurrent("t"), !limit(parser, amount: string.count) { current += string } }
    override func endElement(_ parser: XMLParser, name: String) {
        if name == "si" {
            strings.append(current)
            if strings.count > 100_000 { truncated = true; parser.abortParsing() }
        }
    }
}

private final class WorksheetXML: BoundedXML {
    let shared: [String]
    var text = "", address = "", type = "", value = "", formula = ""
    init(shared: [String]) {
        self.shared = shared
        super.init(rootName: "worksheet", namespaces: OfficeNamespace.spreadsheet, allowsNamespaceFree: true)
    }
    override func startElement(_ parser: XMLParser, name: String, attributes: [String: String]) {
        if name == "c" { address = attributes["r"] ?? "?"; type = attributes["t"] ?? ""; value = ""; formula = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !limit(parser, amount: string.count) else { return }
        if isCurrent("v") || isCurrent("t") { value += string }
        if isCurrent("f") { formula += string }
    }
    override func endElement(_ parser: XMLParser, name: String) {
        if name == "c" {
            let resolved: String
            if type == "s" {
                guard let index = Int(value), shared.indices.contains(index) else { parser.abortParsing(); return }
                resolved = shared[index]
            } else { resolved = value }
            text += "\(address): \(resolved)" + (formula.isEmpty ? "" : " [formula: =\(formula)]") + "\n"
            if text.count > FileReader.textLimit { truncated = true; parser.abortParsing() }
        }
    }
}
