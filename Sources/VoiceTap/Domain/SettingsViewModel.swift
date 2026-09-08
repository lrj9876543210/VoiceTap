import Combine
import SwiftUI

/// 设置界面的数据源。
///
/// 除了持久化配置，还镜像了三类**不可观察的系统状态**：开机启动、权限、音频设备。
/// 这些东西 SwiftUI 感知不到变化，直接在 View 里现读会让控件状态在重渲染间隙
/// 漂移（显示的值和实际的对不上）。规则：镜像到 `@Published` 作唯一事实源，
/// 操作后回读真实值写回，窗口显示 / app 激活时刷新。
@MainActor
final class SettingsViewModel: ObservableObject {

    /// 触发键或触发方式变更 —— 需要先把当前按着的键释放掉
    var onTriggerChanged: ((String) -> Void)?
    /// 需要重启 HID 监听的变更
    var onMonitorSettingChanged: (() -> Void)?
    /// 自动切麦开关刚打开，立即应用一次
    var onAutoMicEnabled: (() -> Void)?
    /// 「抢占正在播放」开关变了，要跟着注册/注销
    var onNowPlayingSettingChanged: (() -> Void)?
    /// 全局快捷键的开关或键位变了，要重新挂 / 撤掉 EventTap
    var onHotKeySettingChanged: (() -> Void)?
    var onCheckUpdates: (() -> Void)?

    // MARK: 持久化配置
    //
    // 属性一律 `private(set)`，写入只能走下面的 `setXxx` 方法。
    //
    // 这不是洁癖：每项变更都带副作用（释放正按着的触发键、重建 EventTap、
    // 归还借来的输入法），而且**顺序有含义** —— 用旧值还是新值决定了结果对不对。
    // 早先这些序列写在 `didSet` 里，其中两处方向还相反，全靠注释互相提醒：
    // 谁把那两行重排一次，错误是静默的（用户的输入法再也还不回去）。
    // 收进方法之后，序列只写一次，且属性从外部只读 —— 绕不过去。

    @Published private(set) var enabled: Bool

    @Published private(set) var triggerShortcut: Shortcut

    @Published private(set) var triggerMode: TriggerMode

    /// 用哪个输入法做语音输入（`TISInputSourceID`，空串 = 不指定）。
    @Published private(set) var voiceInputMethodID: String

    @Published private(set) var hotKeyEnabled: Bool

    /// 用户按的全局快捷键。注意和 `triggerShortcut` 的分工：这个是**监听**的，
    /// 那个是**合成发给输入法**的。
    @Published private(set) var hotKey: Shortcut

    @Published private(set) var longPressThreshold: Double
    @Published private(set) var seizeDevice: Bool
    @Published private(set) var singleClickPlayPause: Bool
    @Published private(set) var preemptNowPlaying: Bool
    @Published private(set) var autoSwitchMic: Bool
    @Published private(set) var autoCheckUpdates: Bool

    // MARK: 变更入口

    func setEnabled(_ newValue: Bool) {
        enabled = newValue
        Settings.shared.enabled = newValue
        onMonitorSettingChanged?()
    }

    /// **先回调，后写配置。**
    ///
    /// 回调要用**旧**触发键去释放正按着的那个——换了键之后旧键的「松开」
    /// 永远不会再来，先用新值释放等于旧键永久卡在按下状态。
    func setTriggerShortcut(_ newValue: Shortcut) {
        triggerShortcut = newValue
        onTriggerChanged?("切换触发键")
        Settings.shared.triggerShortcut = newValue
    }

    /// **先写配置，后回调。**
    ///
    /// 和 `setTriggerShortcut` 的顺序**相反**，别照抄那边：换触发方式不改触发键，
    /// `forceRelease` 用的还是同一个键，没有「必须用旧值释放」的问题；
    /// 而回调里要按**新**模式决定抢占开关等一堆东西，先回调后写等于让它们
    /// 全读到旧值 —— 判断会整个反过来（切去按住模式反而保持抢占、切回轻点反而关掉）。
    func setTriggerMode(_ newValue: TriggerMode) {
        triggerMode = newValue
        Settings.shared.triggerMode = newValue
        onTriggerChanged?("切换触发方式")
        onHotKeySettingChanged?()
    }

    /// **先回调，后写配置**（同 `setTriggerShortcut`）。
    ///
    /// 回调要用**旧**目标把可能正借着的输入法还回去；先写配置的话就变成
    /// 拿新目标去还，用户原来的输入法再也回不来了。
    func setVoiceInputMethodID(_ newValue: String) {
        voiceInputMethodID = newValue
        onTriggerChanged?("切换语音输入法")
        Settings.shared.voiceInputMethodID = newValue.isEmpty ? nil : newValue
    }

    func setHotKeyEnabled(_ newValue: Bool) {
        hotKeyEnabled = newValue
        onTriggerChanged?("切换全局快捷键开关")
        Settings.shared.hotKeyEnabled = newValue
        onHotKeySettingChanged?()
    }

    /// 换键之后旧键的「松开」永远不会再来，正按着的会卡住 —— 先收尾再换。
    func setHotKey(_ newValue: Shortcut) {
        hotKey = newValue
        onTriggerChanged?("切换全局快捷键")
        Settings.shared.hotKey = newValue
        onHotKeySettingChanged?()
    }

    func setLongPressThreshold(_ newValue: Double) {
        longPressThreshold = newValue
        Settings.shared.longPressThreshold = newValue
    }

    func setSeizeDevice(_ newValue: Bool) {
        seizeDevice = newValue
        Settings.shared.seizeDevice = newValue
        onMonitorSettingChanged?()
    }

    func setSingleClickPlayPause(_ newValue: Bool) {
        singleClickPlayPause = newValue
        Settings.shared.singleClickPlayPause = newValue
    }

    func setPreemptNowPlaying(_ newValue: Bool) {
        preemptNowPlaying = newValue
        Settings.shared.preemptNowPlaying = newValue
        onNowPlayingSettingChanged?()
    }

    func setAutoSwitchMic(_ newValue: Bool) {
        autoSwitchMic = newValue
        Settings.shared.autoSwitchMicToHeadset = newValue
        if newValue { onAutoMicEnabled?() }
    }

    func setAutoCheckUpdates(_ newValue: Bool) {
        autoCheckUpdates = newValue
        Settings.shared.autoCheckUpdates = newValue
    }

    // MARK: 系统状态镜像

    @Published private(set) var launchState: LaunchAtLogin.State
    @Published private(set) var inputDevices: [AudioInputDevice] = []
    @Published private(set) var currentInputUID: String = ""
    /// 有耳机麦在场。只服务于下面的 `micMismatched`，所以判据是「存在耳机的输入设备」，
    /// 比状态栏那个「耳机在场」窄一档——没有麦克风的耳机在这里不算，
    /// 那种情况下也谈不上「录音走没走耳机麦」。
    @Published private(set) var headsetPluggedIn = false
    @Published private(set) var inputMonitoring: Permissions.State = .unknown
    @Published private(set) var accessibility: Permissions.State = .unknown

    /// 本机装了哪些有语音能力的输入法。
    /// 这同样是**外部状态**——用户随时可能在系统设置里增删输入法，
    /// 在 View 里现读会让 Picker 的选项和实际的对不上，所以镜像到这里。
    @Published private(set) var voiceInputMethods: [VoiceInputMethod] = []

    /// 选中的那个输入法已经不在了（被用户从系统设置里移除 / 卸载）。
    /// 不提示的话表现是「按了没反应」，且毫无线索。
    var selectedInputMethodMissing: Bool {
        !voiceInputMethodID.isEmpty && !voiceInputMethods.contains { $0.id == voiceInputMethodID }
    }

    /// 耳机插着，但录音走的不是耳机麦 —— 说的话会被电脑麦收进去，
    /// 用户几乎不可能自己发现
    var micMismatched: Bool {
        guard headsetPluggedIn else { return false }
        guard let current = inputDevices.first(where: { $0.uid == currentInputUID }) else { return false }
        return !current.isHeadsetMic
    }

    var allPermissionsGranted: Bool {
        inputMonitoring == .granted && accessibility == .granted
    }

    init() {
        // init 内的赋值不触发 didSet，所以不会在启动时反向写回一遍
        enabled = Settings.shared.enabled
        triggerShortcut = Settings.shared.triggerShortcut
        triggerMode = Settings.shared.triggerMode
        longPressThreshold = Settings.shared.longPressThreshold
        seizeDevice = Settings.shared.seizeDevice
        singleClickPlayPause = Settings.shared.singleClickPlayPause
        preemptNowPlaying = Settings.shared.preemptNowPlaying
        autoSwitchMic = Settings.shared.autoSwitchMicToHeadset
        autoCheckUpdates = Settings.shared.autoCheckUpdates
        voiceInputMethodID = Settings.shared.voiceInputMethodID ?? ""
        hotKeyEnabled = Settings.shared.hotKeyEnabled
        hotKey = Settings.shared.hotKey
        launchState = LaunchAtLogin.state
        refreshSystemState()
    }

    // MARK: 刷新

    func refreshSystemState() {
        launchState = LaunchAtLogin.state
        inputDevices = AudioDeviceWatcher.inputDevices()
        currentInputUID = AudioDeviceWatcher.currentInputDevice()?.uid ?? ""
        headsetPluggedIn = inputDevices.contains(where: \.isHeadsetMic)
        inputMonitoring = Permissions.inputMonitoring
        accessibility = Permissions.accessibility
        voiceInputMethods = InputMethodCatalog.voiceInputMethods()
    }

    // MARK: 动作

    func setLaunchAtLogin(_ on: Bool) {
        // 用回读到的真实状态覆盖镜像，不假定操作一定成功
        launchState = LaunchAtLogin.set(on)
    }

    func selectInputDevice(uid: String) {
        guard let device = inputDevices.first(where: { $0.uid == uid }) else { return }
        if AudioDeviceWatcher.setInputDevice(device) {
            currentInputUID = device.uid
        }
        refreshSystemState()
    }

    func switchToHeadsetMic() {
        guard let mic = inputDevices.first(where: \.isHeadsetMic) else { return }
        selectInputDevice(uid: mic.uid)
    }
}
