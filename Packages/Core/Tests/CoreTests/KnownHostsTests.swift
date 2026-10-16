import Foundation
import Testing

@testable import FerryCore

/// 这一组是把 known_hosts 的**读侧**钉死：四个哈希向量是 2026-10-16 用
/// `ssh-keygen -H -f /tmp/khv2/kh`（本机 OpenSSH_10.3p1）在临时目录跑出来的，
/// 逐条用独立实现的 HMAC-SHA1（Python）反算对上；匹配语义则来自容器里的实测
/// （见 docs/spike/M1-03）。手写期望值一律避免——那样只能证明我们自洽。
let vectorBlob = Data(base64Encoded:
    "AAAAC3NzaC1lZDI1NTE5AAAAIMK3Zj9sOPo9ctD6772F19iXuMJpWqlJXIOn5y46I0E8")!

private func line(_ text: String) -> KnownHostLine {
    let file = KnownHostsFile.parse(text, source: "test")
    guard file.failures.isEmpty, let parsed = file.lines.first else {
        Issue.record("这一行本该能解析：\(text)（failures=\(file.failures.map(\.reason))）")
        fatalError("unparsed")
    }
    return parsed
}

private func candidates(host: String, port: Int) -> [String] { hostCandidates(host: host, port: port) }

@Test("哈希主机名：ssh-keygen -H 产出的四个向量逐条对上")
func hashedVectors() {
    let vectors: [(host: String, salt: String, hash: String)] = [
        ("a.example.com", "t2n7JSkCcIze9KGJsgvXu7oy/2g=", "1RxnOw5yjdRcmRLGWlogIDPPCr8="),
        ("b.example.com", "dD6nkaz6OroZpBpAtrihC9Dy86s=", "gQvNVMxMCPesZkjH/7RLxyZ48YY="),
        ("192.0.2.1", "gQtnD1Zub4HKvYHdWStCUd0gpbs=", "LRxNFX9lI5qTH3W0y/qnOp/BOAM="),
        ("[host.example.org]:2222", "C3qTfPhqbxcteyW8U69CVQvMlZo=", "xQMx3AKGHKnnx0rvrseYZS5gx4U="),
    ]
    for vector in vectors {
        let hashed = HashedHostName(salt: Data(base64Encoded: vector.salt)!,
                                    hash: Data(base64Encoded: vector.hash)!)
        #expect(hashed.matches(host: vector.host), "该行应命中 \(vector.host)")
        #expect(hashed.encoded == "|1|\(vector.salt)|\(vector.hash)")
        // salt 20 字节是 `ssh-keygen -H` 的实际形状，不能按 16 硬编码。
        #expect(hashed.salt.count == 20)
        #expect(!hashed.matches(host: vector.host + "x"))
    }
}

@Test("哈希行只对**查询用的那个字符串**命中：端口写进哈希输入")
func hashedPortIsPartOfTheHash() {
    let hashed = HashedHostName.make(host: "[example.com]:2222", salt: Data(repeating: 3, count: 20))
    #expect(hashed.matches(host: "[example.com]:2222"))
    #expect(!hashed.matches(host: "example.com"))
    #expect(!hashed.matches(host: "[example.com]:2223"))
}

@Test("查询主机时的两个候选串：明文行和方括号行都算命中")
func bothHostFormsMatchNonDefaultPort() {
    // 实测（本机 10.3 连 127.0.0.1:2201）：表里写 `127.0.0.1` 和写 `[127.0.0.1]:2201`
    // 两种行都能让连接通过，所以候选必须同时带裸名和 `[host]:port`。
    let plain = line("127.0.0.1 ssh-ed25519 \(vectorBlob.base64EncodedString())")
    let bracketed = line("[127.0.0.1]:2201 ssh-ed25519 \(vectorBlob.base64EncodedString())")
    let probes = candidates(host: "127.0.0.1", port: 2201)
    #expect(hostLineMatches(plain, candidates: probes))
    #expect(hostLineMatches(bracketed, candidates: probes))
    // 但表里别的端口不会因为我们连 2201 而命中。
    #expect(!hostLineMatches(line("[127.0.0.1]:9999 ssh-ed25519 \(vectorBlob.base64EncodedString())"),
                             candidates: probes))
}

@Test("通配、?、转义与否证")
func patternSyntax() {
    let probes = candidates(host: "db-1.example.com", port: 22)
    let row = KnownHostKey(keyType: "ssh-ed25519", blob: vectorBlob)
    #expect(hostLineMatches(line("db-?.example.com ssh-ed25519 \(vectorBlob.base64EncodedString())"),
                             candidates: probes))
    #expect(hostLineMatches(line("db-*.example.com ssh-ed25519 \(vectorBlob.base64EncodedString())"),
                             candidates: probes))
    #expect(!hostLineMatches(line("db-2.example.com ssh-ed25519 \(vectorBlob.base64EncodedString())"),
                              candidates: probes))
    // 逗号列表里任何一项否证命中 → 整行不算匹配（OpenSSH match_pattern_list）。
    #expect(!hostLineMatches(line("db-1.example.com,!db-1.example.com ssh-ed25519 \(vectorBlob.base64EncodedString())"),
                              candidates: probes))
    #expect(hostLineMatches(line("db-1.example.com,!other.example.com ssh-ed25519 \(vectorBlob.base64EncodedString())"),
                             candidates: probes))
    // 只有否证的列表永不命中。
    #expect(!hostLineMatches(line("!db-1.example.com ssh-ed25519 \(vectorBlob.base64EncodedString())"),
                              candidates: probes))
    #expect(!hostLineMatches(line("!*.other.com ssh-ed25519 \(vectorBlob.base64EncodedString())"),
                              candidates: probes))
    // `\,` 转义属于主机名的一部分，不当分隔符。
    let escaped = line("a\\,b.example.com ssh-ed25519 \(vectorBlob.base64EncodedString())")
    #expect(escaped.patterns == ["a\\,b.example.com"])
    #expect(hostLineMatches(escaped, candidates: candidates(host: "a,b.example.com", port: 22)))
    // 通配行本身要能参与判定，否则上面那些断言只是自娱。
    #expect(lookupHostKey(host: "db-1.example.com", port: 22, key: row,
                          in: [KnownHostsFile.parse("db-*.example.com ssh-ed25519 \(vectorBlob.base64EncodedString())",
                                                    source: "wild")])
            == .trusted(source: "wild", line: 1, keyType: "ssh-ed25519"))
}

@Test("同一主机多算法：只有类型相同的那行参与判定")
func multipleAlgorithmsPerHost() {
    let text = """
        github.com ssh-ed25519 \(vectorBlob.base64EncodedString())
        github.com ssh-rsa \(wireBlob(type: "ssh-rsa", payload: [7, 7]).base64EncodedString())
        """
    let files = [KnownHostsFile.parse(text, source: "user")]

    // 本次谈成 ed25519 且密钥一致 → 命中，而不是"看到另一行 rsa 就报密钥变了"。
    #expect(lookupHostKey(host: "github.com", port: 22,
                          key: KnownHostKey(keyType: "ssh-ed25519", blob: vectorBlob), in: files)
            == .trusted(source: "user", line: 1, keyType: "ssh-ed25519"))
    #expect(lookupHostKey(host: "github.com", port: 22,
                          key: KnownHostKey(keyType: "ssh-rsa", blob: wireBlob(type: "ssh-rsa", payload: [7, 7])),
                          in: files) == .trusted(source: "user", line: 2, keyType: "ssh-rsa"))
    // 表里只有别的算法 → otherAlgorithm，不是 keyChanged。这一格就是任务里点名的误报。
    #expect(lookupHostKey(host: "github.com", port: 22,
                          key: KnownHostKey(keyType: "ecdsa-sha2-nistp256", blob: wireBlob(type: "ecdsa-sha2-nistp256")),
                          in: files) == .otherAlgorithm(sources: ["user"],
                                                         knownTypes: ["ssh-ed25519", "ssh-rsa"]))
}

@Test("同类型不同密钥 → keyChanged；带指纹")
func sameTypeDifferentKeyIsChange() {
    let files = [KnownHostsFile.parse("host.example ssh-ed25519 \(vectorBlob.base64EncodedString())", source: "user")]
    let other = KnownHostKey(keyType: "ssh-ed25519", blob: wireBlob(type: "ssh-ed25519", payload: [1]))
    let verdict = lookupHostKey(host: "host.example", port: 22, key: other, in: files)
    guard case .keyChanged(let source, let number, let keyType, let fingerprint) = verdict else {
        Issue.record("本该判 keyChanged，实得 \(verdict)")
        return
    }
    #expect(source == "user")
    #expect(number == 1)
    #expect(keyType == "ssh-ed25519")
    #expect(fingerprint == HostKey.fingerprint(of: vectorBlob))
}

@Test("撤销优先：别处有同一把密钥的合法行也不放行")
func revokedOutranksValid() {
    let key = KnownHostKey(keyType: "ssh-ed25519", blob: vectorBlob)
    let files = [KnownHostsFile.parse("""
        good.example ssh-ed25519 \(vectorBlob.base64EncodedString())
        @revoked good.example ssh-ed25519 \(vectorBlob.base64EncodedString())
        """, source: "user")]
    #expect(lookupHostKey(host: "good.example", port: 22, key: key, in: files)
            == .revoked(source: "user", line: 2))
}

@Test("证书不参与匹配：CA 行与 *-cert- 行都归 certificateOnly")
func certificateLinesAreNeverAMatch() {
    let key = KnownHostKey(keyType: "ssh-ed25519", blob: vectorBlob)
    // @cert-authority 行即使 blob 与本次一致也不能算命中：它是 CA，不是这台的密钥。
    let ca = [KnownHostsFile.parse("@cert-authority ca.example ssh-ed25519 \(vectorBlob.base64EncodedString())",
                                   source: "ca")]
    #expect(lookupHostKey(host: "ca.example", port: 22, key: key, in: ca)
            == .certificateOnly(sources: ["ca"]))
    let cert = [KnownHostsFile.parse("cert.example ssh-ed25519-cert-v01@openssh.com \(vectorBlob.base64EncodedString())",
                                     source: "cert")]
    #expect(lookupHostKey(host: "cert.example", port: 22, key: key, in: cert)
            == .certificateOnly(sources: ["cert"]))
    #expect(KnownHostKey(keyType: "ssh-rsa-cert-v01@openssh.com", blob: vectorBlob).isCertificate)
}

@Test("一行里的哈希名与明文模式互斥；形状不对就判失败，不静默跳过")
func malformedLinesAreReported() {
    let file = KnownHostsFile.parse("""
        # 注释
        host ssh-ed25519 \(vectorBlob.base64EncodedString())

        @unknown-marker host ssh-ed25519 \(vectorBlob.base64EncodedString())
        host ssh-ed25519
        host ssh-ed25519 不是base64!!!
        |1|只有盐| ssh-ed25519 \(vectorBlob.base64EncodedString())
        127.0.0.1 ssh-ed25519 \(vectorBlob.base64EncodedString())
        """, source: "mixed")
    #expect(file.lines.count == 2)
    #expect(file.failures.map(\.lineNumber) == [4, 5, 6, 7])

    // 少填充的 base64 是手改文件的真实形状：49 字节的 blob（51−2）除以 3 余 1，
    // 写出来末尾正好两个填充位。能补就补；补了还对不上才判失败。
    let paddedSource = Data(vectorBlob.dropLast(2))
    #expect(paddedSource.count == 49)
    #expect(paddedSource.base64EncodedString().hasSuffix("=="))
    let unpadded = KnownHostsFile.parse(
        "host ssh-ed25519 \(String(paddedSource.base64EncodedString().dropLast(2)))", source: "unpadded")
    #expect(unpadded.lines.count == 1)
    #expect(unpadded.lines.first?.key.blob == paddedSource)
}

@Test("分隔符：Tab 与行尾 \\r 都不能让合法行读失败")
func whitespaceShapes() {
    let tabbed = KnownHostsFile.parse("host\tssh-ed25519\t\(vectorBlob.base64EncodedString())\t我的注释",
                                      source: "tab")
    #expect(tabbed.lines.first?.key.blob == vectorBlob)
    #expect(tabbed.lines.first?.comment == "我的注释")
    let crlf = KnownHostsFile.parse("host ssh-ed25519 \(vectorBlob.base64EncodedString())\r\n", source: "crlf")
    #expect(crlf.lines.first?.patterns == ["host"])
    let multiline = KnownHostsFile.parse("a.example ssh-ed25519 \(vectorBlob.base64EncodedString()) 注释 里有 空格",
                                         source: "space-comment")
    #expect(multiline.lines.first?.key.blob == vectorBlob)
    #expect(multiline.lines.first?.comment == "注释 里有 空格")
}

@Test("写出的行与 ssh-keyscan 的形状一致，且能被自己重新读回命中")
func renderedRoundTrip() {
    let key = KnownHostKey(keyType: "ssh-ed25519", blob: vectorBlob)
    let plain = KnownHostLine(lineNumber: 0, marker: nil, patterns: ["[127.0.0.1]:2201"], hashed: nil,
                              key: key, comment: nil)
    #expect(plain.rendered == "[127.0.0.1]:2201 ssh-ed25519 \(vectorBlob.base64EncodedString())")
    let revoked = KnownHostLine(lineNumber: 0, marker: .revoked, patterns: ["host"], hashed: nil,
                                key: key, comment: nil)
    #expect(revoked.rendered.hasPrefix("@revoked host ssh-ed25519 "))

    let reparsed = KnownHostsFile.parse(plain.rendered, source: "round")
    #expect(lookupHostKey(host: "127.0.0.1", port: 2201, key: key, in: [reparsed])
            == .trusted(source: "round", line: 1, keyType: "ssh-ed25519"))
    // 哈希行同样能往返：`ssh-keygen -H -f` 作用于我们的存储之后仍然命中。
    let hashed = HashedHostName.make(host: "[127.0.0.1]:2201", salt: Data(repeating: 5, count: 20))
    let hashedLine = KnownHostLine(lineNumber: 0, marker: nil, patterns: nil, hashed: hashed, key: key, comment: nil)
    let hashedFile = KnownHostsFile.parse(hashedLine.rendered, source: "hashed")
    #expect(lookupHostKey(host: "127.0.0.1", port: 2201, key: key, in: [hashedFile])
            == .trusted(source: "hashed", line: 1, keyType: "ssh-ed25519"))
}

@Test("主机名大小写：一律按小写比，写法不同的行也认")
func caseInsensitiveHosts() {
    let key = KnownHostKey(keyType: "ssh-ed25519", blob: vectorBlob)
    let files = [KnownHostsFile.parse("Example.COM ssh-ed25519 \(vectorBlob.base64EncodedString())", source: "upper")]
    #expect(lookupHostKey(host: "example.com", port: 22, key: key, in: files)
            == .trusted(source: "upper", line: 1, keyType: "ssh-ed25519"))
    #expect(lookupHostKey(host: "EXAMPLE.com", port: 22, key: key, in: files)
            == .trusted(source: "upper", line: 1, keyType: "ssh-ed25519"))
}

@Test("多个文件：任一文件精确命中即放行，冲突行按优先级报出")
func multipleFilesPriority() {
    let key = KnownHostKey(keyType: "ssh-ed25519", blob: vectorBlob)
    let store = KnownHostsFile.parse("host ssh-ed25519 \(wireBlob(type: "ssh-ed25519", payload: [9]).base64EncodedString())",
                                     source: "store")
    let user = KnownHostsFile.parse("host ssh-ed25519 \(vectorBlob.base64EncodedString())", source: "user")
    // man：任一文件里有有效信息即接受。所以 user 里的合法行赢，但报出来的来源是 user。
    #expect(lookupHostKey(host: "host", port: 22, key: key, in: [store, user])
            == .trusted(source: "user", line: 1, keyType: "ssh-ed25519"))
    #expect(lookupHostKey(host: "host", port: 22, key: key, in: [store])
            == .keyChanged(source: "store", line: 1, keyType: "ssh-ed25519",
                           knownFingerprint: HostKey.fingerprint(of: wireBlob(type: "ssh-ed25519", payload: [9]))))
}

func wireBlob(type: String, payload: [UInt8] = [1, 2, 3]) -> Data {
    var data = Data()
    var length = UInt32(type.utf8.count).bigEndian
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(contentsOf: type.utf8)
    data.append(contentsOf: payload)
    return data
}

func hostKeyFor(_ type: String, payload: [UInt8] = [1, 2, 3]) throws -> HostKey {
    try HostKey(algorithm: type, blob: wireBlob(type: type, payload: payload))
}
