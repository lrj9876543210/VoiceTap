import Cocoa
import XCTest

@testable import VoiceTap

// 只测不依赖系统状态的纯逻辑。
//
// 这个项目的难点几乎全在「和外部系统的边界」上：HID 回调的重复上报、
// 输入法的异步就绪、EventTap 的时序。那些东西拿 mock 测出来的只是 mock 自己，
// 真正能被稳定测住的是下面这些不需要任何系统状态的判定 —— 而它们一旦判错，
// 表现全是静默的（不提示更新 / 快捷键录了读不回来）。

// MARK: - 版本比较

final class AppVersionTests: XCTestCase {

    func testComparisonIsNumericNotLexical() {
        // 字符串比较会把 "0.10.0" 判成小于 "0.9.0"，第九版之后就再也升不上去
        XCTAssertGreaterThan(AppVersion("0.10.0"), AppVersion("0.9.0"))
        XCTAssertLessThan(AppVersion("0.4.1"), AppVersion("0.4.2"))
        XCTAssertLessThan(AppVersion("0.4.1"), AppVersion("0.10.0"))
    }

    func testMissingSegmentsAreTreatedAsZero() {
        XCTAssertEqual(AppVersion("1.0"), AppVersion("1.0.0"))
        XCTAssertEqual(AppVersion("1"), AppVersion("1.0.0"))
        XCTAssertGreaterThan(AppVersion("1.0.1"), AppVersion("1.0"))
    }

    func testLeadingVIsStripped() {
        XCTAssertEqual(AppVersion("v1.2.3").text, "1.2.3")
        XCTAssertEqual(AppVersion("v1.2.3"), AppVersion("1.2.3"))
    }

    func testPrereleaseIsNotNewerThanItsRelease() {
        // Int("1-beta") 直接失败归零的老写法会把预发布判成**更小**，
        // 结果是预发布永远推不出去；取前导数字后二者等价
        XCTAssertEqual(AppVersion("1.0.0-beta"), AppVersion("1.0.0"))
        XCTAssertGreaterThan(AppVersion("1.0.1-beta"), AppVersion("1.0.0"))
    }
}

// MARK: - 快捷键

final class ShortcutTests: XCTestCase {

    func testRoundTripsThroughJSON() throws {
        let shortcut = Shortcut(keyCode: 6, modifiers: CGEventFlags.maskCommand.rawValue)
        let data = try JSONEncoder().encode(shortcut)
        let decoded = try JSONDecoder().decode(Shortcut.self, from: data)
        XCTAssertEqual(decoded, shortcut)
    }

    func testModifierOnlyAndEmpty() {
        XCTAssertTrue(Shortcut.fnOnly.isModifierOnly)
        XCTAssertFalse(Shortcut.fnOnly.isEmpty)
        XCTAssertTrue(Shortcut(keyCode: nil, modifiers: 0).isEmpty)
    }

    func testOnlyFnIsNotRiskyAsHotKey() {
        // 单独吞掉 ⌘ 会让 ⌘C 之类整个失效，fn 开头的组合键极少、不在此列
        XCTAssertFalse(Shortcut.fnOnly.isRiskyAsHotKey)

        let loneCommand = Shortcut(keyCode: nil, modifiers: CGEventFlags.maskCommand.rawValue)
        XCTAssertTrue(loneCommand.isRiskyAsHotKey)

        let loneShift = Shortcut(keyCode: nil, modifiers: CGEventFlags.maskShift.rawValue)
        XCTAssertTrue(loneShift.isRiskyAsHotKey)

        // 带主键的组合不算：吞的是那一个组合，不是修饰键本身
        let commandZ = Shortcut(keyCode: 6, modifiers: CGEventFlags.maskCommand.rawValue)
        XCTAssertFalse(commandZ.isRiskyAsHotKey)
    }

    func testNormalizeCGDropsNoiseBits() {
        let flags: CGEventFlags = [.maskCommand, .maskSecondaryFn, .maskNumericPad, .maskAlphaShift]
        let expected = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskSecondaryFn.rawValue
        XCTAssertEqual(Shortcut.normalizeCG(flags), expected)
    }

    func testNormalizeCGPreservesLeftRightCommandOption() {
        // 右 ⌘ / 左 ⌥ 的侧键位必须保留，才能精确绑定到某一侧
        let rightCmdLeftOpt: CGEventFlags = [.maskCommand, .rightCommandBit, .maskAlternate, .leftAlternateBit]
        let normalized = CGEventFlags(rawValue: Shortcut.normalizeCG(rightCmdLeftOpt))
        XCTAssertTrue(normalized.contains(.maskCommand))
        XCTAssertTrue(normalized.contains(.rightCommandBit))
        XCTAssertFalse(normalized.contains(.leftCommandBit))
        XCTAssertTrue(normalized.contains(.maskAlternate))
        XCTAssertTrue(normalized.contains(.leftAlternateBit))
        XCTAssertFalse(normalized.contains(.rightAlternateBit))
    }

    func testModifiersMatchDistinguishesRightCommand() {
        // 新快捷键：绑到右 ⌘ → 只认右 ⌘，左 ⌘ 不匹配
        let rightCmd = CGEventFlags.maskCommand.rawValue | CGEventFlags.rightCommandBit.rawValue
        let rightEvent = CGEventFlags.maskCommand.rawValue | CGEventFlags.rightCommandBit.rawValue
        let leftEvent = CGEventFlags.maskCommand.rawValue | CGEventFlags.leftCommandBit.rawValue
        XCTAssertTrue(Shortcut.modifiersMatch(stored: rightCmd, event: rightEvent))
        XCTAssertFalse(Shortcut.modifiersMatch(stored: rightCmd, event: leftEvent))
    }

    func testModifiersMatchLegacyCommandMatchesEitherSide() {
        // 旧快捷键：只存通用 ⌘ → 左 ⌘ 和右 ⌘ 都匹配（向后兼容）
        let legacyCmd = CGEventFlags.maskCommand.rawValue
        let rightEvent = CGEventFlags.maskCommand.rawValue | CGEventFlags.rightCommandBit.rawValue
        let leftEvent = CGEventFlags.maskCommand.rawValue | CGEventFlags.leftCommandBit.rawValue
        XCTAssertTrue(Shortcut.modifiersMatch(stored: legacyCmd, event: rightEvent))
        XCTAssertTrue(Shortcut.modifiersMatch(stored: legacyCmd, event: leftEvent))
    }

    func testDisplayStringShowsSideForCommandOption() {
        let rightCmdLeftOpt = Shortcut(keyCode: nil,
            modifiers: (CGEventFlags.maskCommand.rawValue | CGEventFlags.rightCommandBit.rawValue
                        | CGEventFlags.maskAlternate.rawValue | CGEventFlags.leftAlternateBit.rawValue))
        XCTAssertTrue(rightCmdLeftOpt.displayString.contains("⌘右"), "右 ⌘ 应标出「右」：\(rightCmdLeftOpt.displayString)")
        XCTAssertTrue(rightCmdLeftOpt.displayString.contains("⌥左"), "左 ⌥ 应标出「左」：\(rightCmdLeftOpt.displayString)")
    }
}

// MARK: - 触发方式

final class TriggerModeTests: XCTestCase {

    func testOnlyToggleKeepsRecordingAfterRelease() {
        // 这个判定决定要不要挂自动停止监听：按住说话本来就有「松手」这条出口，
        // 给它加自动停止只会在用户还按着的时候把话截断
        XCTAssertTrue(TriggerMode.toggle.keepsRecordingAfterRelease)
        XCTAssertFalse(TriggerMode.hold.keepsRecordingAfterRelease)
    }

    func testRawValuesRemainStable() {
        // rawValue 是写进 UserDefaults 的，改了会让老用户悄悄退回按住说话
        XCTAssertEqual(TriggerMode.hold.rawValue, "hold")
        XCTAssertEqual(TriggerMode.toggle.rawValue, "toggle")
    }
}
