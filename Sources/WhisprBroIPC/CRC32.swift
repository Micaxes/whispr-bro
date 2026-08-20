import Foundation

/// CRC-32 (zlib/IEEE 802.3: reflected, polynomial 0xEDB88320, init and final
/// xor 0xFFFFFFFF) — the checksum named by the `StatusPage` contract.
/// Implemented locally because Foundation exposes no CRC and this module links
/// nothing else; 40 bytes at ≤30Hz makes table lookup speed a non-issue, but
/// the standard 256-entry table keeps it obviously correct against any zlib
/// reference.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var crc = UInt32(index)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
        }
        return crc
    }

    static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        checksum(regions: [bytes])
    }

    /// Multi-region form, equivalent to checksumming the concatenation — for
    /// layouts whose checksummed bytes are not contiguous (the partial page:
    /// header, then text on the far side of the checksum + generation words).
    static func checksum(regions: [UnsafeRawBufferPointer]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for bytes in regions {
            for byte in bytes {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
