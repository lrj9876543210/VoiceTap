// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceTap",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VoiceTap",
            path: "Sources/VoiceTap"
        ),
        // 只覆盖不依赖系统状态的纯逻辑（版本比较、快捷键编解码）。
        // HID 回调、输入法借用这些的真实行为绑在系统上，硬测只会测出一堆 mock。
        .testTarget(
            name: "VoiceTapTests",
            dependencies: ["VoiceTap"],
            path: "Tests/VoiceTapTests"
        )
    ]
)
