import CoreFoundation
import Foundation

/// 远端文件名的字符集处理。方案里"编码转换有损"（R5）这条风险就落在这里。
///
/// 权威表示永远是 `RemotePath.wireBytes`，本类型只做两个方向的事：
/// 显示（解码，解不出来退回十六进制）与输入（编码，字符集装不下就整条拒绝）。
///
/// 绝不允许"把服务器字节解成 String、改一版、再编码回去"当成同一个名字。
/// 全 65536 个双字节组合逐个"解出来再编回去"实测（`spike charset`，出处见
/// docs/spike/M0b-02）：Big5、Shift-JIS、CP932、EUC-KR、EUC-CN、GB18030 都有一对多映射。
/// 例：Big5 的 `A3 75` 解出 `ㄆ` 却编不回去；Shift-JIS/CP932 的 `81 7F` 解出 `÷` 再编成 `81 80`；
/// GB18030 的单字节 `80` 解出 `€` 再编成 `A2 E3`。
/// GBK 是这批多字节码里唯一零失配的（有效区 23860 个可解序列全测往返一致），
/// latin1/cp1252/utf8 也零失配，但它们本来就不存在一对多的双字节序列。
/// 规则不能按字符集分叉——换个服务器就没了这个保证。
public struct CharsetConverter: Hashable, Sendable {
    /// 可选字符集。值来自 CoreFoundation 的编码表，不是自造编号。
    ///
    /// 注意"自动探测"这条路走不通：同一份 GBK 字节 `D6 D0 CE C4` 在 Foundation 里
    /// GBK、GB18030、EUC-CN 三个编码都能解成"中文"，latin1/cp1252 解成"ÖÐÎÄ"，
    /// Big5/EUC-KR/Shift-JIS/CP932 也能解、只是解成"笢恅/櫓匡/ﾖﾐﾎﾄ"这种像模像样的乱码。
    /// 命中多个不构成证据，所以字符集只能是连接上的配置，错了由出处标记暴露给用户。
    public enum Charset: String, CaseIterable, Sendable {
        case utf8
        case gbk
        case gb18030
        case big5
        case eucCN
        case shiftJIS
        case cp932
        case eucKR
        case isoLatin1
        case windowsCP1252

        /// Foundation 的 `String.Encoding` 没有这些成员，只能经 CF 换算。
        ///
        /// 两个坑（都实测过）：
        /// - 编号写错不会报错，只会全都解不出，所以换算结果要核对；
        /// - `String.Encoding.shiftJIS`（rawValue 8）其实等于 CF 0x0420 即 CP932，
        ///   真正的 JIS X 0208 Shift-JIS 是 0x0A01——直接写 `.shiftJIS` 会拿到错的那个。
        ///   `87 40` 在 0x0A01 下解不出、在 0x0420 下解出 `①`，`81 7C` 分别解出 `−` 与 `－`。
        var encoding: String.Encoding {
            switch self {
            case .utf8: .utf8
            case .gbk: Self.cfEncoding(0x0631)      // kCFStringEncodingGBK_95
            case .gb18030: Self.cfEncoding(0x0632)  // kCFStringEncodingGB_18030_2000
            case .big5: Self.cfEncoding(0x0A03)     // kCFStringEncodingBig5
            case .eucCN: Self.cfEncoding(0x0930)    // kCFStringEncodingEUC_CN
            case .shiftJIS: Self.cfEncoding(0x0A01) // kCFStringEncodingShiftJIS
            case .cp932: Self.cfEncoding(0x0420)    // kCFStringEncodingDOSJapanese，Windows 日文
            case .eucKR: Self.cfEncoding(0x0940)    // kCFStringEncodingEUC_KR
            case .isoLatin1: .isoLatin1
            case .windowsCP1252: .windowsCP1252
            }
        }

        private static func cfEncoding(_ value: UInt32) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(value)))
        }
    }

    /// 解码结果，带出处。UI 要靠出处决定要不要提示"已按 GBK 解释"。
    public enum Decoded: Hashable, Sendable {
        /// 合法 UTF-8，直接显示，没动过字符集。
        case utf8(String)
        /// 不是合法 UTF-8，按配置的字符集解释出来了。
        case charset(String)
        /// 两边都解不出来，只能按字节看。
        case hexadecimal
    }

    public let charset: Charset

    public init(charset: Charset) {
        self.charset = charset
    }

    /// 先试 UTF-8，再试配置字符集。
    ///
    /// 顺序不能反过来：配置成 GBK 的连接上，纯 ASCII 与合法 UTF-8 名字在 GBK 下多半也能解，
    /// 但解出来的是乱码；UTF-8 是强信号，先过一遍能把这类名字救回来。
    /// 含 NUL 的字节一律走十六进制——POSIX 里 NUL 截断路径，显示成控制字符只会让人以为名字是空的。
    public func decode(_ bytes: [UInt8]) -> Decoded {
        guard !bytes.contains(0) else { return .hexadecimal }
        if let text = String(bytes: bytes, encoding: .utf8) { return .utf8(text) }
        guard charset != .utf8 else { return .hexadecimal }
        if let text = String(bytes: bytes, encoding: charset.encoding) { return .charset(text) }
        return .hexadecimal
    }

    /// 展示用字符串。解不出来时整条按 `\xNN` 呈现，不做有损替换，也不只替换出错那几个字节——
    /// 半截可读半截转义的名字会让人以为看清楚了全部。
    public func displayString(_ bytes: [UInt8]) -> String {
        switch decode(bytes) {
        case .utf8(let text), .charset(let text): return text
        case .hexadecimal:
            return bytes.map { String(format: "\\x%02x", $0) }.joined()
        }
    }

    /// 用户输入 → 发往服务器的字节。
    ///
    /// 必须逐字符编码，不能用 `text.data(using:)` 一把梭：实测 GBK 下
    /// `"\u{FEFF}A"` 整条编码"成功"，回来的字节是 `41`——零宽字符被静默丢掉，
    /// 名字短了一截却没有任何失败信号。逐字符判定能把这类字符变成显式拒绝。
    /// 空字节也算失败，因为它就是"这个字符消失了"。
    public func encode(_ text: String) -> Encoded {
        var bytes: [UInt8] = []
        for character in text {
            guard let part = String(character).data(using: charset.encoding), !part.isEmpty else {
                return .rejected(character)
            }
            bytes.append(contentsOf: part)
        }
        return .bytes(bytes)
    }

    public enum Encoded: Hashable, Sendable {
        case bytes([UInt8])
        /// 配置字符集表示不了这个字符。调用方必须报错，不能截断或替换后上传。
        case rejected(Character)
    }
}
