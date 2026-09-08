import Foundation

/// 版本号，逐段按数字比较。
///
/// 单独成类型而不是在 `String` 上写个扩展方法，是因为「版本比大小」决定了要不要
/// 给用户推更新：判错了要么永远不提示、要么反复提示，而且没有任何报错。
/// 它不依赖系统状态，是这个项目里少数几条能被测到的纯逻辑，值得单独立出来。
///
/// 不能直接比字符串 —— "0.10.0" < "0.9.0" 会成立，第九版之后就再也升不上去了。
struct AppVersion: Comparable, Sendable, CustomStringConvertible, Equatable {

    /// 原始文本，已去掉可能的前缀 `v`（GitHub 的 tag 习惯带它）
    let text: String

    private let segments: [Int]

    init(_ text: String) {
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        self.text = trimmed
        self.segments = trimmed.split(separator: ".").map(Self.numericPrefix)
    }

    var description: String { text }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for i in 0..<max(lhs.segments.count, rhs.segments.count) {
            let a = i < lhs.segments.count ? lhs.segments[i] : 0
            let b = i < rhs.segments.count ? rhs.segments[i] : 0
            if a != b { return a < b }
        }
        return false
    }

    /// 由 `<` 导出，而不是合成 —— 合成的 `==` 会比较原始文本和段数组，
    /// 那会让 "1.0" 与 "1.0.0"、"1.0.0-beta" 与 "1.0.0" 都判成不相等，
    /// 于是「已是最新版」的提示永远出不来。
    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    /// 每段只取前导数字。
    ///
    /// `Int("1-beta")` 直接失败归零，那会把 "1.0.0-beta" 判成小于 "1.0.0"，
    /// 预发布版本反而永远推不出去。取前导数字之后 "1.0.0-beta" 与 "1.0.0" 等价
    /// —— 预发布不比它的正式版新，这个结论是对的。
    private static func numericPrefix(_ segment: Substring) -> Int {
        Int(segment.prefix(while: \.isNumber)) ?? 0
    }
}
