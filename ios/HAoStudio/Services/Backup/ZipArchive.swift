// HAo Studio 2.0 — minimal ZIP archive reader/writer (S6, leg A).
//
// Stored entries only (method 0, no compression), hand-written CRC32,
// Foundation-only. The backup zip must be readable by the system
// unzipper, so the layout follows the plain ZIP spec: local file
// header + data per entry, one central directory, end of central
// directory record. No data descriptors, no encryption, no ZIP64
// (a backup larger than 4 GiB is rejected at write time instead of
// silently producing a file nothing can open).
//
// Why stored, not deflated: the payload is already-compressed media
// (images, audio, video) plus small JSON; deflate would buy almost
// nothing and would need a third-party coder. Stored also keeps the
// reader trivial to audit: every byte is accounted for by offset.
//
// Why two passes at write time: a streamed file entry's CRC and size
// are only known after reading it, and the local header must carry
// them up front (no data descriptors, so nothing may patch the
// header afterwards). Pass 1 streams each file entry once to learn
// its CRC and size; pass 2 writes headers and streams the bytes
// again. Nothing is held in memory except 64 KiB chunks, so large
// files (downloads, recordings) fit in the package.
//
// Only old FileHandle APIs are used here (forWritingTo /
// forReadingFrom / readData / seek / closeFile): the package pins
// Swift 5.0 with a macOS 10.15 floor, and the newer FileHandle
// calls need 10.15.4. Same lesson as S3 (seekToEnd needs 10.15.4,
// use seekToEndOfFile).

import Foundation

/// One entry inside a zip archive, as listed in the central directory.
struct ZipEntryInfo: Equatable {
    /// Entry path inside the zip (`collections/hao_fav.json`).
    /// Always uses `/` separators, never absolute.
    let name: String
    /// Compression method. The writer only emits 0 (stored); the
    /// reader refuses anything else.
    let method: UInt16
    let crc32: UInt32
    let compressedSize: UInt32
    let uncompressedSize: UInt32
    /// Byte offset of the entry's local file header.
    let localHeaderOffset: UInt32
}

/// One entry to write. `.file` streams from disk in chunks; `.data`
/// is for the small in-memory entries (the envelope JSON).
enum ZipEntry {
    case data(name: String, data: Data)
    case file(name: String, fileURL: URL)

    var name: String {
        switch self {
        case .data(let name, _):
            return name
        case .file(let name, _):
            return name
        }
    }
}

enum ZipArchive {
    static let storedMethod: UInt16 = 0
    static let maxEntrySize: UInt64 = 0xFFFF_FFFF
    static let chunkSize = 64 * 1024

    private static let localHeaderSignature: UInt32 = 0x0403_4B50
    private static let centralHeaderSignature: UInt32 = 0x0201_4B50
    private static let endOfCentralSignature: UInt32 = 0x0605_4B50

    // MARK: - CRC32 (IEEE, polynomial 0xEDB88320)

    static let crcTable: [UInt32] = {
        var table: [UInt32] = []
        table.reserveCapacity(256)
        for i in 0..<256 {
            var value = UInt32(i)
            for _ in 0..<8 {
                if value & 1 != 0 {
                    value = 0xEDB8_8320 ^ (value >> 1)
                } else {
                    value = value >> 1
                }
            }
            table.append(value)
        }
        return table
    }()

    /// Running CRC state (before the final xor). Start from
    /// `0xFFFF_FFFF`, feed chunks with `crcUpdate`, finish with
    /// `crcFinalize`.
    static func crcUpdate(_ running: UInt32, _ data: Data) -> UInt32 {
        var value = running
        for byte in data {
            let index = Int((value ^ UInt32(byte)) & 0xFF)
            value = crcTable[index] ^ (value >> 8)
        }
        return value
    }

    static func crcFinalize(_ running: UInt32) -> UInt32 {
        return running ^ 0xFFFF_FFFF
    }

    /// One-shot CRC32 of a whole buffer. Known vector: the bytes
    /// of "123456789" give 0xCBF43926 (see BackupTests).
    static func crc32(_ data: Data) -> UInt32 {
        return crcFinalize(crcUpdate(0xFFFF_FFFF, data))
    }

    // MARK: - Little-endian helpers

    static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    static func readUInt16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 1 < data.count else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 3 < data.count else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    /// DOS date/time fields for "now" (UTC). Falls back to the
    /// DOS epoch (1980-01-01) when the calendar cannot produce
    /// components; a wrong timestamp never fails the archive.
    static func dosDateTime(for date: Date) -> (date: UInt16, time: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        let year = max(1980, min(2107, parts.year ?? 1980))
        let month = max(1, min(12, parts.month ?? 1))
        let day = max(1, min(31, parts.day ?? 1))
        let hour = max(0, min(23, parts.hour ?? 0))
        let minute = max(0, min(59, parts.minute ?? 0))
        let second = max(0, min(59, parts.second ?? 0))
        let dosDate = UInt16(((year - 1980) << 9) | (month << 5) | day)
        let dosTime = UInt16((hour << 11) | (minute << 5) | (second / 2))
        return (date: dosDate, time: dosTime)
    }

    /// Entry names must be relative, slash-separated, with no
    /// empty, `.` or `..` component. A name that fails this check
    /// is refused at write time and rejected at read time.
    static func isSafeEntryName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\") else {
            return false
        }
        for part in name.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty || part == "." || part == ".." {
                return false
            }
        }
        return true
    }

    // MARK: - Write

    /// Writes a new zip file. Pass 1 learns every entry's CRC and
    /// size; pass 2 writes headers plus bytes. Returns false when
    /// any entry name is unsafe, any file entry cannot be read or
    /// is 4 GiB or larger, or the destination cannot be written.
    /// A failed write leaves no partial file behind.
    static func write(entries: [ZipEntry], to destinationURL: URL) -> Bool {
        for entry in entries {
            guard isSafeEntryName(entry.name) else { return false }
        }

        // Pass 1: CRC + size per entry, streaming files in chunks.
        struct Measured {
            let crc: UInt32
            let size: UInt32
        }
        var measured: [Measured] = []
        for entry in entries {
            switch entry {
            case .data(_, let data):
                guard UInt64(data.count) <= maxEntrySize else { return false }
                measured.append(Measured(crc: crc32(data), size: UInt32(data.count)))
            case .file(_, let fileURL):
                guard let info = measureFile(at: fileURL) else { return false }
                measured.append(Measured(crc: info.crc, size: info.size))
            }
        }

        // Pass 2: headers + bytes. The file is created empty first
        // so forWritingTo has something to open.
        let path = destinationURL.path
        FileManager.default.createFile(atPath: path, contents: nil, attributes: nil)
        guard let handle = try? FileHandle(forWritingTo: destinationURL) else {
            try? FileManager.default.removeItem(at: destinationURL)
            return false
        }
        let stamp = dosDateTime(for: Date())
        var localOffsets: [UInt32] = []
        var ok = true
        for (index, entry) in entries.enumerated() {
            let info = measured[index]
            guard let nameData = entry.name.data(using: .utf8) else {
                ok = false
                break
            }
            let offset = UInt32(handle.seekToEndOfFile())
            localOffsets.append(offset)
            var header = Data()
            appendUInt32(localHeaderSignature, to: &header)
            appendUInt16(20, to: &header)
            appendUInt16(0, to: &header)
            appendUInt16(storedMethod, to: &header)
            appendUInt16(stamp.time, to: &header)
            appendUInt16(stamp.date, to: &header)
            appendUInt32(info.crc, to: &header)
            appendUInt32(info.size, to: &header)
            appendUInt32(info.size, to: &header)
            appendUInt16(UInt16(nameData.count), to: &header)
            appendUInt16(0, to: &header)
            header.append(nameData)
            handle.write(header)
            switch entry {
            case .data(_, let data):
                handle.write(data)
            case .file(_, let fileURL):
                if !streamFile(at: fileURL, to: handle) {
                    ok = false
                }
            }
            if !ok {
                break
            }
        }

        // Central directory + end record, then close.
        var centralStart: UInt64 = 0
        if ok {
            centralStart = handle.seekToEndOfFile()
            for (index, entry) in entries.enumerated() {
                let info = measured[index]
                guard let nameData = entry.name.data(using: .utf8) else {
                    ok = false
                    break
                }
                var central = Data()
                appendUInt32(centralHeaderSignature, to: &central)
                appendUInt16(20, to: &central)
                appendUInt16(20, to: &central)
                appendUInt16(0, to: &central)
                appendUInt16(storedMethod, to: &central)
                appendUInt16(stamp.time, to: &central)
                appendUInt16(stamp.date, to: &central)
                appendUInt32(info.crc, to: &central)
                appendUInt32(info.size, to: &central)
                appendUInt32(info.size, to: &central)
                appendUInt16(UInt16(nameData.count), to: &central)
                appendUInt16(0, to: &central)
                appendUInt16(0, to: &central)
                appendUInt16(0, to: &central)
                appendUInt16(0, to: &central)
                appendUInt32(0, to: &central)
                appendUInt32(localOffsets[index], to: &central)
                central.append(nameData)
                handle.write(central)
            }
        }
        if ok {
            let centralEnd = handle.seekToEndOfFile()
            // No ZIP64: a total archive past 4 GiB would wrap the
            // 32-bit offsets, so refuse it instead of writing a
            // file nothing can open.
            if centralStart > UInt64(UInt32.max) || centralEnd > UInt64(UInt32.max) {
                ok = false
            } else {
                let centralSize = UInt32(centralEnd - centralStart)
                var end = Data()
                appendUInt32(endOfCentralSignature, to: &end)
                appendUInt16(0, to: &end)
                appendUInt16(0, to: &end)
                appendUInt16(UInt16(entries.count), to: &end)
                appendUInt16(UInt16(entries.count), to: &end)
                appendUInt32(centralSize, to: &end)
                appendUInt32(UInt32(centralStart), to: &end)
                appendUInt16(0, to: &end)
                handle.write(end)
            }
        }
        handle.closeFile()
        if !ok {
            try? FileManager.default.removeItem(at: destinationURL)
            return false
        }
        return true
    }

    /// Streams one file to learn its CRC32 and size. Nil when the
    /// file cannot be read or is 4 GiB or larger.
    private static func measureFile(at fileURL: URL) -> (crc: UInt32, size: UInt32)? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        var running: UInt32 = 0xFFFF_FFFF
        var total: UInt64 = 0
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty {
                break
            }
            running = crcUpdate(running, chunk)
            total += UInt64(chunk.count)
            if total > maxEntrySize {
                handle.closeFile()
                return nil
            }
        }
        handle.closeFile()
        return (crc: crcFinalize(running), size: UInt32(total))
    }

    /// Streams one file's bytes into an open output handle.
    private static func streamFile(at fileURL: URL, to handle: FileHandle) -> Bool {
        guard let input = try? FileHandle(forReadingFrom: fileURL) else {
            return false
        }
        while true {
            let chunk = input.readData(ofLength: chunkSize)
            if chunk.isEmpty {
                break
            }
            handle.write(chunk)
        }
        input.closeFile()
        return true
    }

    // MARK: - Read (list)

    /// Lists the entries of a zip file by parsing its central
    /// directory. Nil when the file is not a zip, the end record
    /// cannot be found, or any central entry is truncated or has
    /// an unsafe name. The data itself is not read here.
    static func listEntries(at zipURL: URL) -> [ZipEntryInfo]? {
        guard let size = fileSize(at: zipURL), size >= 22 else {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: zipURL) else {
            return nil
        }
        // The end record sits in the last 64 KiB + 22 bytes (the
        // comment may be up to 64 KiB long).
        let tailLength = min(size, 65_557)
        handle.seek(toFileOffset: size - tailLength)
        let tail = handle.readData(ofLength: Int(tailLength))
        handle.closeFile()
        var endOffset: Int?
        var scan = tail.count - 22
        while scan >= 0 {
            if readUInt32(tail, at: scan) == endOfCentralSignature {
                endOffset = scan
                break
            }
            scan -= 1
        }
        guard let found = endOffset else { return nil }
        guard let totalEntries = readUInt16(tail, at: found + 10),
              let centralSize = readUInt32(tail, at: found + 12),
              let centralOffset = readUInt32(tail, at: found + 16)
        else { return nil }
        guard UInt64(centralOffset) + UInt64(centralSize) <= size else {
            return nil
        }
        guard let centralHandle = try? FileHandle(forReadingFrom: zipURL) else {
            return nil
        }
        centralHandle.seek(toFileOffset: UInt64(centralOffset))
        let central = centralHandle.readData(ofLength: Int(centralSize))
        centralHandle.closeFile()
        var entries: [ZipEntryInfo] = []
        var cursor = 0
        for _ in 0..<totalEntries {
            guard readUInt32(central, at: cursor) == centralHeaderSignature,
                  let method = readUInt16(central, at: cursor + 10),
                  let crc = readUInt32(central, at: cursor + 16),
                  let compressedSize = readUInt32(central, at: cursor + 20),
                  let uncompressedSize = readUInt32(central, at: cursor + 24),
                  let nameLength = readUInt16(central, at: cursor + 28),
                  let extraLength = readUInt16(central, at: cursor + 30),
                  let commentLength = readUInt16(central, at: cursor + 32),
                  let localOffset = readUInt32(central, at: cursor + 42)
            else { return nil }
            let nameStart = cursor + 46
            let nameEnd = nameStart + Int(nameLength)
            guard nameEnd <= central.count,
                  let name = String(data: central.subdata(in: nameStart..<nameEnd), encoding: .utf8),
                  isSafeEntryName(name)
            else { return nil }
            entries.append(ZipEntryInfo(
                name: name, method: method, crc32: crc,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localOffset
            ))
            cursor = nameEnd + Int(extraLength) + Int(commentLength)
        }
        return entries
    }

    // MARK: - Read (one entry)

    /// Reads one stored entry fully into memory and verifies its
    /// CRC32. Nil when the entry is not stored, the local header
    /// disagrees with the central directory, or the CRC fails.
    /// Use this for the small entries (envelope, collections);
    /// use `extract` for the payload files.
    static func readEntryData(_ entry: ZipEntryInfo, from zipURL: URL) -> Data? {
        guard entry.method == storedMethod else { return nil }
        guard let data = readEntryBytes(entry, from: zipURL) else {
            return nil
        }
        guard crc32(data) == entry.crc32 else { return nil }
        return data
    }

    /// Streams one stored entry out to a file, verifying its CRC32
    /// as it goes. The destination is written via a temp file in
    /// the same directory and moved into place, so a failed or
    /// interrupted extract never leaves a half-written file. Nil
    /// result / false means nothing was left behind.
    static func extract(_ entry: ZipEntryInfo, from zipURL: URL, to destinationURL: URL) -> Bool {
        guard entry.method == storedMethod else { return false }
        guard let handle = try? FileHandle(forReadingFrom: zipURL) else {
            return false
        }
        guard let dataStart = dataStartOffset(entry, handle: handle) else {
            handle.closeFile()
            return false
        }
        let tempURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(destinationURL.lastPathComponent + ".part-" + UUID().uuidString)
        FileManager.default.createFile(atPath: tempURL.path, contents: nil, attributes: nil)
        guard let output = try? FileHandle(forWritingTo: tempURL) else {
            handle.closeFile()
            return false
        }
        handle.seek(toFileOffset: dataStart)
        var remaining = UInt64(entry.compressedSize)
        var running: UInt32 = 0xFFFF_FFFF
        var ok = true
        while remaining > 0 {
            let want = Int(min(UInt64(chunkSize), remaining))
            let chunk = handle.readData(ofLength: want)
            if chunk.isEmpty {
                ok = false
                break
            }
            running = crcUpdate(running, chunk)
            output.write(chunk)
            remaining -= UInt64(chunk.count)
        }
        handle.closeFile()
        output.closeFile()
        if ok, crcFinalize(running) != entry.crc32 {
            ok = false
        }
        if !ok {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
    }

    /// Reads an entry's raw bytes (no CRC check — the callers
    /// check). Shared by `readEntryData` and the size checks.
    private static func readEntryBytes(_ entry: ZipEntryInfo, from zipURL: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: zipURL) else {
            return nil
        }
        guard let dataStart = dataStartOffset(entry, handle: handle) else {
            handle.closeFile()
            return nil
        }
        handle.seek(toFileOffset: dataStart)
        let data = handle.readData(ofLength: Int(entry.compressedSize))
        handle.closeFile()
        guard data.count == Int(entry.compressedSize) else { return nil }
        return data
    }

    /// Byte offset where an entry's data starts, from its local
    /// file header. Nil when the header is missing, truncated, or
    /// disagrees with the central directory (wrong name length,
    /// encrypted flag, or data-descriptor flag — this reader only
    /// accepts plain stored entries with sizes up front).
    private static func dataStartOffset(_ entry: ZipEntryInfo, handle: FileHandle) -> UInt64? {
        handle.seek(toFileOffset: UInt64(entry.localHeaderOffset))
        let header = handle.readData(ofLength: 30)
        guard header.count == 30,
              readUInt32(header, at: 0) == localHeaderSignature,
              let flags = readUInt16(header, at: 6),
              let method = readUInt16(header, at: 8),
              let nameLength = readUInt16(header, at: 26),
              let extraLength = readUInt16(header, at: 28)
        else { return nil }
        guard flags & 0x0001 == 0, flags & 0x0008 == 0, method == storedMethod else {
            return nil
        }
        return UInt64(entry.localHeaderOffset) + 30 + UInt64(nameLength) + UInt64(extraLength)
    }

    private static func fileSize(at url: URL) -> UInt64? {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return nil
        }
        return size.uint64Value
    }
}
