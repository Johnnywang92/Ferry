import AppKit
import Foundation
import SwiftUI

// 记录启动戳（供 build-and-sign.sh 验证 LaunchServices 确实将进程拉起）
let stampPath = ProcessInfo.processInfo.environment["FERRY_STAMP"] ?? "/tmp/ferry-launch-stamp.txt"
let stamp = "pid=\(getpid()) bundle=\(Bundle.main.bundleIdentifier ?? "nil") "
    + "path=\(Bundle.main.bundlePath) when=\(Int(Date().timeIntervalSince1970))\n"
try? stamp.write(toFile: stampPath, atomically: true, encoding: .utf8)

let args = CommandLine.arguments
let isProbe = args.contains("--probe") || args.contains("--skip-keychain") || ProcessInfo.processInfo.environment["FERRY_MODE"] == "probe"

if isProbe {
    runSigningProbe()
} else {
    // 确保图形应用在 macOS 上作为常规应用激活（拥有菜单栏、Dock 图标与窗口焦点）
    NSApplication.shared.setActivationPolicy(.regular)
    FerryApp.main()
}
