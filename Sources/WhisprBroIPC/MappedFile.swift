import Foundation

/// Thrown by the two single-writer types when their backing file cannot be
/// created or mapped. Readers never throw — an unmappable file on the read
/// side is just "no page yet" and degrades to nil/empty (see the graceful
/// App Group degradation in `SharedContainer`).
public enum IPCError: Error, Equatable {
    case cannotMap(URL)
}

/// A fixed-size POSIX shared file mapping — the transport under both the
/// status page and the command mailbox. Deliberately raw mmap, not
/// FileHandle/Data: both files are an ABI of explicit little-endian fields at
/// fixed offsets, and both sides re-read the same mapping for the file's whole
/// lifetime (MAP_SHARED is coherent across processes on the same host).
///
/// Atomicity note, load-bearing: every multi-byte field in both layouts is
/// naturally aligned, and aligned loads/stores up to 8 bytes are single-copy
/// atomic on arm64/x86_64 — a reader never sees half a field. Cross-FIELD
/// consistency is what the layer above adds: the status page's seqlock
/// generation + CRC-32 (a torn or reordered view fails one of the two and
/// reads as nil, never as plausible state), and the mailbox's publish-seq-last
/// write order + per-record seq check. That pair of guards is why plain
/// stores suffice here without fence intrinsics Swift doesn't expose.
final class MappedFile {
    enum Mode {
        /// Open read-write, creating and zero-extending the file to
        /// `byteCount` if needed (owner-only 0600 — the App Group container
        /// is already the access boundary, the mode just documents intent).
        case readWrite
        /// Open read-only; fails (nil) until the writer has created a file of
        /// at least `byteCount` bytes, so a reader racing the writer's first
        /// ftruncate simply retries on its next poll tick.
        case readOnly
    }

    let base: UnsafeMutableRawPointer
    let byteCount: Int
    private let fileDescriptor: Int32

    init?(url: URL, byteCount: Int, mode: Mode) {
        let fd: Int32
        switch mode {
        case .readWrite: fd = open(url.path, O_RDWR | O_CREAT, 0o600)
        case .readOnly: fd = open(url.path, O_RDONLY)
        }
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            close(fd)
            return nil
        }
        if info.st_size < off_t(byteCount) {
            guard case .readWrite = mode, ftruncate(fd, off_t(byteCount)) == 0 else {
                close(fd)
                return nil
            }
        }
        let prot = mode == .readOnly ? PROT_READ : PROT_READ | PROT_WRITE
        guard let mapped = mmap(nil, byteCount, prot, MAP_SHARED, fd, 0),
              mapped != MAP_FAILED else {
            close(fd)
            return nil
        }
        self.base = mapped
        self.byteCount = byteCount
        self.fileDescriptor = fd
    }

    deinit {
        munmap(base, byteCount)
        close(fileDescriptor)
    }

    // MARK: Little-endian field access (all offsets naturally aligned)

    func storeUInt8(_ value: UInt8, at offset: Int) {
        base.storeBytes(of: value, toByteOffset: offset, as: UInt8.self)
    }

    func loadUInt8(at offset: Int) -> UInt8 {
        base.load(fromByteOffset: offset, as: UInt8.self)
    }

    func storeUInt16(_ value: UInt16, at offset: Int) {
        base.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt16.self)
    }

    func loadUInt16(at offset: Int) -> UInt16 {
        UInt16(littleEndian: base.load(fromByteOffset: offset, as: UInt16.self))
    }

    func storeUInt32(_ value: UInt32, at offset: Int) {
        base.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt32.self)
    }

    func loadUInt32(at offset: Int) -> UInt32 {
        UInt32(littleEndian: base.load(fromByteOffset: offset, as: UInt32.self))
    }

    func storeUInt64(_ value: UInt64, at offset: Int) {
        base.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt64.self)
    }

    func loadUInt64(at offset: Int) -> UInt64 {
        UInt64(littleEndian: base.load(fromByteOffset: offset, as: UInt64.self))
    }

    /// Float32 travels as its little-endian IEEE-754 bit pattern.
    func storeFloat(_ value: Float, at offset: Int) {
        storeUInt32(value.bitPattern, at: offset)
    }

    func loadFloat(at offset: Int) -> Float {
        Float(bitPattern: loadUInt32(at: offset))
    }

    /// Raw uuid_t bytes, exactly as `UUID.uuid` lays them out (RFC 4122 big-
    /// endian field order — a byte string, so "little-endian fields" does not
    /// apply and hex dumps match Foundation's uuidString).
    func storeUUID(_ value: UUID, at offset: Int) {
        withUnsafeBytes(of: value.uuid) { raw in
            base.advanced(by: offset).copyMemory(from: raw.baseAddress!, byteCount: 16)
        }
    }

    /// Raw byte-region copy (the partial page's UTF-8 text field).
    func storeBytes(_ bytes: [UInt8], at offset: Int) {
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeBytes { src in
            base.advanced(by: offset).copyMemory(from: src.baseAddress!, byteCount: src.count)
        }
    }

    func loadUUID(at offset: Int) -> UUID {
        var raw = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &raw) { dst in
            dst.copyMemory(from: UnsafeRawBufferPointer(start: base + offset, count: 16))
        }
        return UUID(uuid: raw)
    }
}
