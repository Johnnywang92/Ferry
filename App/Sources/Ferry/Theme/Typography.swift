import SwiftUI

public enum FerryFont {
    /// 13px 正文
    public static let body = Font.system(size: 13, weight: .regular)
    public static let bodyMedium = Font.system(size: 13, weight: .medium)
    public static let bodyBold = Font.system(size: 13, weight: .semibold)

    /// 12px 标签、列表项次要说明
    public static let subheadline = Font.system(size: 12, weight: .regular)
    public static let subheadlineMedium = Font.system(size: 12, weight: .medium)
    public static let subheadlineBold = Font.system(size: 12, weight: .semibold)

    /// 11px 小标题、侧栏分类标题、工具栏按钮说明
    public static let caption = Font.system(size: 11, weight: .regular)
    public static let captionMedium = Font.system(size: 11, weight: .medium)
    public static let captionBold = Font.system(size: 11, weight: .semibold)

    /// 10px 胶囊徽标、微型标签
    public static let micro = Font.system(size: 10, weight: .medium)

    /// 等宽字体用于权限位（如 rwxr-xr-x）、数值、日期
    public static let monoBody = Font.system(size: 13, weight: .regular, design: .monospaced)
    public static let monoSmall = Font.system(size: 12, weight: .regular, design: .monospaced)
    public static let monoCaption = Font.system(size: 11, weight: .regular, design: .monospaced)
}

public enum FerryRadius {
    public static let r3: CGFloat = 3
    public static let r4: CGFloat = 4
    public static let r5: CGFloat = 5
    public static let r6: CGFloat = 6
    public static let r7: CGFloat = 7
    public static let r8: CGFloat = 8
    public static let r12: CGFloat = 12
    public static let r18: CGFloat = 18
}
