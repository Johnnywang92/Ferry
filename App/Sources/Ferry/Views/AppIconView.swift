import AppKit
import SwiftUI

public struct AppIconView: View {
    public let size: CGFloat

    public init(size: CGFloat = 24) {
        self.size = size
    }

    public var body: some View {
        Group {
            if let iconUrl = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
               let nsImg = NSImage(contentsOf: iconUrl) {
                Image(nsImage: nsImg)
                    .resizable()
                    .scaledToFit()
            } else if let appSupportPath = Bundle.main.executablePath {
                let supportUrl = URL(fileURLWithPath: appSupportPath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("Resources/AppIcon.png")
                if let nsImg = NSImage(contentsOf: supportUrl) {
                    Image(nsImage: nsImg)
                        .resizable()
                        .scaledToFit()
                } else {
                    fallbackView
                }
            } else {
                fallbackView
            }
        }
        .frame(width: size, height: size)
        .cornerRadius(size * 0.22)
        .shadow(color: Color.black.opacity(0.15), radius: 2, x: 0, y: 1)
    }

    private var fallbackView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(Color(hex: "#12151C"))
            Image(systemName: "ferry.fill")
                .font(.system(size: size * 0.5))
                .foregroundColor(Color(hex: "#00F5D4"))
        }
    }
}
