import Foundation

/// 标准 gzip（Foundation 的 zlib 输出是裸 DEFLATE，补头尾即可被 gunzip 读取）
public enum Gzip {
    public static func compress(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        out.append(deflated)
        var crc = crc32(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }

    /// 解 gzip（单成员；头部可选字段按 RFC 1952 跳过）。校验和不对返回 nil
    public static func decompress(_ gz: Data) -> Data? {
        let b = [UInt8](gz)
        guard b.count >= 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return nil }
        let flags = b[3]
        var p = 10
        if flags & 0x04 != 0 { guard p + 2 <= b.count else { return nil }; p += 2 + Int(b[p]) | Int(b[p + 1]) << 8 }
        for bit in [UInt8(0x08), 0x10] where flags & bit != 0 {          // 文件名、注释：0 结尾
            while p < b.count, b[p] != 0 { p += 1 }
            p += 1
        }
        if flags & 0x02 != 0 { p += 2 }
        guard p <= b.count - 8 else { return nil }
        guard let out = try? (Data(b[p..<(b.count - 8)]) as NSData).decompressed(using: .zlib) as Data else { return nil }
        let crc = UInt32(b[b.count - 8]) | UInt32(b[b.count - 7]) << 8 | UInt32(b[b.count - 6]) << 16 | UInt32(b[b.count - 5]) << 24
        return crc32(out) == crc ? out : nil
    }

    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in d { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
}
