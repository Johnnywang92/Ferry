import Foundation
import Testing

@testable import FerryCore

/// 所有期望值都来自实测，不是推测。编码这块只要有一条是猜的，
/// 上线后就是"文件名显示成乱码"或"改名把名字改坏"，而这两条都没有回滚办法。
private func utf8(_ string: String) -> [UInt8] { Array(string.utf8) }

@Test("合法 UTF-8 先按 UTF-8 解，配置成 GBK 也不能把名字解成乱码")
func utf8WinsOverConfiguredCharset() {
    let gbkName: [UInt8] = [0xD6, 0xD0, 0xCE, 0xC4]                 // GBK 的"中文"
    let converter = CharsetConverter(charset: .gbk)

    #expect(converter.decode(utf8("中文.txt")) == .utf8("中文.txt"))
    #expect(converter.decode(gbkName) == .charset("中文"))
    #expect(CharsetConverter(charset: .utf8).decode(gbkName) == .hexadecimal)
}

@Test("同一份字节在不同配置下解出不同名字，所以字符集只能配、不能猜")
func sameBytesMeanDifferentNamesPerCharset() {
    let gbkName: [UInt8] = [0xD6, 0xD0, 0xCE, 0xC4]
    func decode(_ charset: CharsetConverter.Charset) -> CharsetConverter.Decoded {
        CharsetConverter(charset: charset).decode(gbkName)
    }

    // 三种中文编码都能解成"中文"——命中多个不构成证据
    #expect(decode(.gbk) == .charset("中文"))
    #expect(decode(.gb18030) == .charset("中文"))
    #expect(decode(.eucCN) == .charset("中文"))

    // 而 Big5/CP932/EUC-KR 也能解，只是解成像模像样的乱码：探测永远发现不了这种错
    #expect(decode(.big5) == .charset("笢恅"))
    #expect(decode(.cp932) == .charset("ﾖﾐﾎﾄ"))
    #expect(decode(.eucKR) == .charset("櫓匡"))
}

@Test("解不出来时整条按十六进制呈现，不做有损替换也不只替换出错字节")
func hexadecimalFallbackCoversWholeName() {
    let converter = CharsetConverter(charset: .utf8)
    #expect(converter.displayString([0xCA, 0xD6]) == "\\xca\\xd6")
    #expect(converter.displayString(utf8("/uploads/\u{0}"))
            == "\\x2f\\x75\\x70\\x6c\\x6f\\x61\\x64\\x73\\x2f\\x00")
}

@Test("含 NUL 的字节走十六进制，不当控制字符显示")
func nulBytesNeverDisplayAsControlCharacters() {
    // Foundation 会把 0x00 老老实实解成 U+0000，UI 上就是一条看起来空掉的名字
    let withNul: [UInt8] = [0x2F, 0x00, 0x61]
    #expect(String(bytes: withNul, encoding: .utf8) != nil)
    for charset in CharsetConverter.Charset.allCases {
        #expect(CharsetConverter(charset: charset).decode(withNul) == .hexadecimal)
    }
    #expect(CharsetConverter(charset: .utf8).displayString(withNul) == "\\x2f\\x00\\x61")
}

@Test("latin1 什么字节都能解，配置错时唯一线索是出处标记")
func singleByteCharsetsAlwaysDecode() {
    let gbkName: [UInt8] = [0xCA, 0xD6]
    // GBK 下这是"手"；选错成 latin1 就得到两个带重音的字母，且永远不会报"解不出来"
    #expect(CharsetConverter(charset: .gbk).decode(gbkName) == .charset("手"))
    #expect(CharsetConverter(charset: .isoLatin1).decode(gbkName) == .charset("ÊÖ"))
}

@Test("编码方向按所选字符集出字节，UTF-8 与 GBK 的字节数不同")
func encodeUsesConfiguredCharset() {
    #expect(CharsetConverter(charset: .utf8).encode("中文") == .bytes(utf8("中文")))
    #expect(CharsetConverter(charset: .gbk).encode("中文") == .bytes([0xD6, 0xD0, 0xCE, 0xC4]))
    #expect(CharsetConverter(charset: .gb18030).encode("😀.txt")
            == .bytes([0x94, 0x39, 0xFC, 0x36, 0x2E, 0x74, 0x78, 0x74]))
}

@Test("字符集装不下就整条拒绝，交回出错字符，不返回半截字节")
func encodeRejectsUnrepresentableCharacters() {
    let result = CharsetConverter(charset: .gbk).encode("😀.txt")
    #expect(result == .rejected("😀"))
    guard case .rejected(let offender) = result else { Issue.record("应当拒绝"); return }
    #expect(offender == "😀")
}

@Test("零宽字符被整条编码静默丢弃，所以必须逐字符判定")
func wholeStringEncodingSilentlyDropsZeroWidth() {
    let text = "\u{FEFF}A"
    let converter = CharsetConverter(charset: .gbk)

    // Foundation 的整条编码"成功"了，却把 BOM 吃掉，只剩 'A'——比失败更危险
    #expect(Array(text.data(using: converter.charset.encoding) ?? Data()) == [0x41])
    #expect(converter.encode(text) == .rejected("\u{FEFF}"))
}

@Test("解码结果不许再编码回去当同一个名字：Big5 有解得出编不回的字符")
func decodingThenReencodingIsNotIdentity() {
    let converter = CharsetConverter(charset: .big5)
    let name: [UInt8] = [0xA3, 0x75]

    #expect(converter.decode(name) == .charset("ㄆ"))
    #expect(converter.encode("ㄆ") == .rejected("ㄆ"))
}

@Test("往返会改字节：Shift-JIS 的 81 7F 解出÷，再编成 81 80")
func roundTripCanChangeBytes() {
    let converter = CharsetConverter(charset: .shiftJIS)
    let name: [UInt8] = [0x81, 0x7F]

    #expect(converter.decode(name) == .charset("÷"))
    #expect(converter.encode("÷") == .bytes([0x81, 0x80]))
}

@Test("`87 40` 区分 Shift-JIS 与 CP932：写成 Swift 的 .shiftJIS 会拿到 CP932")
func shiftJISAndCP932AreDifferentDecoders() {
    let name: [UInt8] = [0x87, 0x40]
    #expect(CharsetConverter(charset: .shiftJIS).decode(name) == .hexadecimal)
    #expect(CharsetConverter(charset: .cp932).decode(name) == .charset("①"))
    #expect(CharsetConverter(charset: .shiftJIS).decode([0x81, 0x7C]) == .charset("−"))
    #expect(CharsetConverter(charset: .cp932).decode([0x81, 0x7C]) == .charset("－"))

    // Swift 的 .shiftJIS（rawValue 8）等于 CF 0x0420，也就是 CP932；
    // 所以本类型必须走 CF 编号，直接用 String.Encoding 会把两个字符集合成一个。
    #expect(CharsetConverter.Charset.cp932.encoding == .shiftJIS)
    #expect(CharsetConverter.Charset.shiftJIS.encoding != .shiftJIS)
}

@Test("GBK 这组字节确实能原样往返，但规则不许为它单独开口子")
func gbkRoundTripsWithoutSpecialCasing() {
    let converter = CharsetConverter(charset: .gbk)
    let name: [UInt8] = [0xCA, 0xD6]

    // 实测 GBK 有效区 23860 个可解双字节序列全部零失配——多字节码里只有它。
    // 但"能往返"是运气，不是协议保证，所以 decode→encode 依然不许当成同一条路径。
    #expect(converter.decode(name) == .charset("手"))
    guard case .charset(let text) = converter.decode(name) else { Issue.record("应为 GBK 解释"); return }
    #expect(converter.encode(text) == .bytes(name))
}

@Test("GB18030 的单字节 80 解出欧元号再编就变成三个字节")
func gb18030SingleByteEuroExpandsOnReencode() {
    let converter = CharsetConverter(charset: .gb18030)
    let name: [UInt8] = [0x80]

    #expect(converter.decode(name) == .charset("€"))
    #expect(converter.encode("€") == .bytes([0xA2, 0xE3]))
}

@Test("EUC-CN 把 A1 21 解成全角空格，再编回 A1 A1——同名字节完全不同")
func eucCNRewritesSymbolArea() {
    let converter = CharsetConverter(charset: .eucCN)
    let name: [UInt8] = [0xA1, 0x21]

    #expect(converter.decode(name) == .charset("\u{3000}"))
    #expect(converter.encode("\u{3000}") == .bytes([0xA1, 0xA1]))
}

@Test("displayString(using:) 只影响显示，wireBytes 一个字节都不动")
func displayDoesNotTouchWireBytes() {
    let gbkName: [UInt8] = [0x2F] + [0xD6, 0xD0, 0xCE, 0xC4]
    let path = RemotePath(wireBytes: gbkName, isAbsolute: true)

    #expect(path.displayString(using: CharsetConverter(charset: .gbk)) == "/中文")
    #expect(path.displayString() == "\\x2f\\xd6\\xd0\\xce\\xc4")   // 默认按 UTF-8，整条降级
    #expect(path.wireBytes == gbkName)

    // 服务器寻址用的还是原字节：显示换了字符集，同一条路径仍然是同一个文件
    #expect(path == RemotePath(wireBytes: gbkName, isAbsolute: true))
}

@Test("空字节序列是合法路径名的一种，解成空串而不是报错")
func emptyBytesDecodeToEmptyString() {
    let converter = CharsetConverter(charset: .gbk)
    #expect(converter.decode([]) == .utf8(""))
    #expect(converter.displayString([]) == "")
    #expect(converter.encode("") == .bytes([]))
}
