import AppKit
import FerryCore
import Foundation
import QuickLookUI
import SwiftUI

/// Quick Look 预览条目包装器。
public final class FerryPreviewItem: NSObject, QLPreviewItem, Sendable {
    public let previewItemURL: URL?
    public let previewItemTitle: String?

    public init(url: URL, title: String? = nil) {
        self.previewItemURL = url
        self.previewItemTitle = title ?? url.lastPathComponent
        super.init()
    }
}

/// Quick Look 预览服务（v2.3 §374）。
///
/// 核心规范：
/// 1. 本地文件直接由 QLPreviewPanel 预览；
/// 2. 远端文件拉取到隔离临时目录（`NSTemporaryDirectory() + Ferry/QuickLook`）后交付预览；
/// 3. 空格键（Space）控制显示与关闭（Finder 标准行为）；
/// 4. 临时预览文件在窗口关闭或应用退出时清理。
@MainActor
public final class QuickLookService: NSObject {
    public static let shared = QuickLookService()

    public private(set) var currentItem: FerryPreviewItem?
    public private(set) var isDownloading: Bool = false
    public private(set) var downloadProgress: Double = 0.0

    private let temporaryDirectory: URL

    private override init() {
        let baseTemp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let qlDir = baseTemp.appendingPathComponent("Ferry/QuickLook", isDirectory: true)
        try? FileManager.default.createDirectory(at: qlDir, withIntermediateDirectories: true)
        self.temporaryDirectory = qlDir
        super.init()
    }

    /// 清理所有临时预览缓存。
    public func cleanUpTempFiles() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    /// 切换本地项预览状态（空格键行为：已打开且为同项则关闭，否则打开或切换）。
    public func togglePreview(localURL: URL) {
        let panel = QLPreviewPanel.shared()
        if panel?.isVisible == true, currentItem?.previewItemURL?.path == localURL.path {
            panel?.orderOut(nil)
            return
        }
        presentPreview(for: localURL, title: localURL.lastPathComponent)
    }

    /// 切换远端项预览。
    public func togglePreview(
        remoteItem: RemoteDisplayItem,
        connection: (any RemoteTransfer)?
    ) {
        guard !remoteItem.isDirectory else { return }
        let destination = temporaryDirectory.appendingPathComponent(remoteItem.name)
        let panel = QLPreviewPanel.shared()

        if panel?.isVisible == true, currentItem?.previewItemURL?.path == destination.path {
            panel?.orderOut(nil)
            return
        }

        // 若临时文件已存在且大小一致，直接快速展示
        if FileManager.default.fileExists(atPath: destination.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path),
           let size = attrs[.size] as? Int64,
           size == remoteItem.size {
            presentPreview(for: destination, title: remoteItem.name)
            return
        }

        // 远端通过 TransferEngine 拉取到临时目录
        guard let transfer = connection else { return }
        self.isDownloading = true
        self.downloadProgress = 0.0

        Task { [weak self] in
            do {
                _ = try await TransferEngine.download(
                    remoteItem.path,
                    to: destination,
                    using: transfer,
                    usePartFile: false
                )
                self?.isDownloading = false
                self?.presentPreview(for: destination, title: remoteItem.name)
            } catch {
                self?.isDownloading = false
            }
        }

    }

    private func presentPreview(for url: URL, title: String) {
        self.currentItem = FerryPreviewItem(url: url, title: title)
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }
}

extension QuickLookService: QLPreviewPanelDataSource {
    public nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated {
            currentItem != nil ? 1 : 0
        }
    }

    public nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated {
            currentItem
        }
    }
}

extension QuickLookService: QLPreviewPanelDelegate {
    public nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown {
            if event.keyCode == 49 /* Space */ || event.keyCode == 53 /* Escape */ {
                Task { @MainActor in
                    panel.orderOut(nil)
                }
                return true
            }
        }
        return false
    }
}
