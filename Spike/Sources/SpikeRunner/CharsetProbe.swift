import CoreFoundation
import Foundation

/// 字符集实测。`CharsetConverter` 里"某字符集逐字节可往返""探测不可信"这类说法
/// 必须有可重跑的出处，否则只是凭印象的注释，而且换 Foundation 版本就可能变。
///
/// 四组测量：
///   1. CF 编号 → NSString 编码换算核对（编号写错不会报错，只会静默解不出东西）；
///   2. 单字节与全 65536 个双字节组合"解出来再编回去"，统计可解数与往返失配数；
///   3. 整条编码与逐字符编码的差异（零宽字符）；
///   4. 同一份字节在多个字符集下的解果，用来证明"命中多个不构成证据"。
enum CharsetProbe {
    private struct Row {
        let name: String
        let encoding: String.Encoding
        var decodable = 0
        var unencodable = 0
        var rewritten = 0
        var rangeDecodable = 0
        var rangeMismatch = 0
        var examples: [(from: [UInt8], text: String, back: [UInt8])] = []
    }

    private static func cf(_ value: UInt32) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(value)))
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func pad(_ s: String, _ n: Int) -> String {
        s.padding(toLength: n, withPad: " ", startingAt: 0)
    }

    static func run() {
        let table: [(String, UInt32?)] = [
            ("GBK", 0x0631), ("GB18030", 0x0632), ("Big5", 0x0A03), ("EUC-CN", 0x0930),
            ("Shift-JIS", 0x0A01), ("CP932/DOSJapanese", 0x0420), ("EUC-KR", 0x0940),
        ]

        print("1) CF 编号换算核对（写错编号不会报错，只会全都解不出）：")
        for (name, value) in table {
            let enc = cf(value!)
            let bad = enc.rawValue == 0xFFFF_FFFF || enc.rawValue == 0
            print("  \(pad(name, 20)) -> \(enc.rawValue)  \(bad ? "无效" : "有效")")
        }

        var rows: [Row] = [
            Row(name: "GBK", encoding: cf(0x0631)),
            Row(name: "GB18030", encoding: cf(0x0632)),
            Row(name: "Big5", encoding: cf(0x0A03)),
            Row(name: "EUC-CN", encoding: cf(0x0930)),
            Row(name: "EUC-KR", encoding: cf(0x0940)),
            Row(name: "Shift-JIS", encoding: cf(0x0A01)),
            Row(name: "CP932", encoding: cf(0x0420)),
            Row(name: "isoLatin1", encoding: .isoLatin1),
            Row(name: "windowsCP1252", encoding: .windowsCP1252),
            Row(name: "utf8", encoding: .utf8),
        ]

        // GBK 系双字节有效区
        var gbkRangeTotal = 0

        for lead in 0...255 {
            for trail in 0...255 {
                let bytes = [UInt8(lead), UInt8(trail)]
                let inGBKRange = lead >= 0x81 && lead <= 0xFE && trail >= 0x40 && trail <= 0xFE && trail != 0x7F
                if inGBKRange { gbkRangeTotal += 1 }
                for index in rows.indices {
                    let enc = rows[index].encoding
                    guard let text = String(bytes: bytes, encoding: enc) else { continue }
                    rows[index].decodable += 1
                    if inGBKRange { rows[index].rangeDecodable += 1 }
                    let back = text.data(using: enc).map { Array($0) }
                    if back == nil {
                        rows[index].unencodable += 1
                    } else if back! != bytes {
                        rows[index].rewritten += 1
                    }
                    if inGBKRange, back != bytes { rows[index].rangeMismatch += 1 }
                    if (back == nil || back! != bytes), rows[index].examples.count < 5 {
                        rows[index].examples.append((bytes, text, back ?? []))
                    }
                }
            }
        }

        var singles: [String: (ok: Int, bad: Int, examples: [String])] = [:]
        for row in rows {
            var ok = 0
            var bad = 0
            var examples: [String] = []
            for byte in UInt8.min...UInt8.max {
                let bytes = [byte]
                guard let text = String(bytes: bytes, encoding: row.encoding) else { continue }
                ok += 1
                let back = text.data(using: row.encoding).map { Array($0) }
                if back == bytes { continue }
                bad += 1
                if examples.count < 5 {
                    examples.append("\(hex(bytes)) -> \(text) -> \(back.map { hex($0) } ?? "<编不回去>")")
                }
            }
            singles[row.name] = (ok, bad, examples)
        }

        print("\n2) 全 65536 双字节组合的往返核对（GBK 有效区 \(gbkRangeTotal) 个）：")
        for row in rows {
            let s = singles[row.name]!
            let label = pad(row.name, 15)
            print("  \(label) 单字节 可解 \(pad(String(s.ok), 4)) 失配 \(s.bad)｜双字节 可解 \(pad(String(row.decodable), 6)) "
                + "失配 \(pad(String(row.rewritten + row.unencodable), 6))（编回不同 \(row.rewritten) / 编不回去 \(row.unencodable)）"
                + "｜GBK 有效区 可解 \(pad(String(row.rangeDecodable), 6)) 失配 \(row.rangeMismatch)")
            for e in s.examples { print("        单 \(e)") }
            for e in row.examples {
                let b = e.back.isEmpty ? "<编不回去>" : hex(e.back)
                print("        双 \(hex(e.from)) -> \(e.text) -> \(b)")
            }
        }

        print("\n3) 整条编码 vs 逐字符编码（零宽字符）：")
        for (name, enc) in [("utf8", String.Encoding.utf8), ("GBK", cf(0x0631)), ("Big5", cf(0x0A03)),
                            ("isoLatin1", String.Encoding.isoLatin1)] {
            let probe = "\u{FEFF}A"
            let whole = probe.data(using: enc).map { hex(Array($0)) } ?? "<nil>"
            var perChar: [UInt8] = []
            var rejects: [String] = []
            for character in probe {
                guard let part = String(character).data(using: enc) else { rejects.append("nil"); continue }
                if part.isEmpty { rejects.append("empty") } else { perChar.append(contentsOf: part) }
            }
            print("  \(pad(name, 10)) 整条 [\(whole)]｜逐字符 [\(hex(perChar))]"
                + (rejects.isEmpty ? "" : "  逐字符拒绝 \(rejects)"))
        }

        print("\n4) 同一份字节 D6 D0 CE C4（GBK 的\"中文\"）在各字符集下的解果：")
        let ambiguous: [UInt8] = [0xD6, 0xD0, 0xCE, 0xC4]
        for (name, enc) in [("GBK", cf(0x0631)), ("GB18030", cf(0x0632)), ("EUC-CN", cf(0x0930)),
                            ("Big5", cf(0x0A03)), ("EUC-KR", cf(0x0940)), ("Shift-JIS", cf(0x0A01)),
                            ("CP932", cf(0x0420)), ("isoLatin1", String.Encoding.isoLatin1),
                            ("windowsCP1252", String.Encoding.windowsCP1252)] {
            let text = String(bytes: ambiguous, encoding: enc) ?? "<解不出>"
            print("  \(pad(name, 14)) \(text)\(text == "中文" ? "   ← 与真名相同" : "")")
        }

        print("\n5) cp932 与 shiftJIS 是不是同一个解码器：")
        print("  String.Encoding.shiftJIS.rawValue = \(String.Encoding.shiftJIS.rawValue)"
            + "｜cf(0x0420)=\(cf(0x0420).rawValue) 相等=\(cf(0x0420) == .shiftJIS)"
            + "｜cf(0x0A01)=\(cf(0x0A01).rawValue) 相等=\(cf(0x0A01) == .shiftJIS)")
        let japanese: [[UInt8]] = [[0x88, 0x40], [0x88, 0x41], [0x81, 0x7C], [0x8F, 0x40], [0x87, 0x40], [0xF8, 0xF0], [0xFA, 0xB0]]
        for bytes in japanese {
            let a = String(bytes: bytes, encoding: .shiftJIS) ?? "<解不出>"
            let b = String(bytes: bytes, encoding: cf(0x0A01)) ?? "<解不出>"
            let c = String(bytes: bytes, encoding: cf(0x0420)) ?? "<解不出>"
            print("  \(hex(bytes))  Cocoa shiftJIS=\(a)  CF 0x0A01=\(b)  CF 0x0420=\(c)")
        }
    }
}
