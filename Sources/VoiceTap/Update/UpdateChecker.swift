import AppKit
import Security

/// 通过 GitHub Releases 检查并**自动安装**新版本。
///
/// 机制沿用 TabFlick / PasteMemo 的更新器：下载当前架构的 DMG → 校验字节数 →
/// 挂载 → 用 shell 脚本**原地替换 .app 的内容**（保持 bundle 路径与身份，
/// 「输入监控 / 辅助功能」授权跟着 bundle ID 走，不会丢）→ 重新启动。
///
/// 脚本里删除/拷贝资源 bundle 一律 glob，绝不写死名字 —— updater 脚本是编译进
/// **当前**版本的，一旦写死某个 bundle 名发出去，将来新增 SPM 依赖时旧 updater
/// 会漏拷新 bundle，而且已装旧版的用户没法远程修复（PasteMemo issue #38）。
@MainActor
final class UpdateChecker {

    private static let lastCheckKey = "lastUpdateCheck"
    private static let skippedKey = "skippedUpdateVersion"
    /// 每小时对一次账，到期才真的查
    private static let tickInterval: TimeInterval = 3600

    static var releasesPage: URL {
        URL(string: "https://github.com/\(AppInfo.repo)/releases/latest")!
    }

    var onLog: ((String) -> Void)?

    private var isChecking = false
    private var isDownloading = false
    private var downloadTask: URLSessionDownloadTask?
    private var downloadSession: URLSession?
    private var downloadDelegate: DownloadDelegate?
    private var downloadCancelled = false
    private var periodicTimer: Timer?
    private var progress: ProgressWindow?

    var currentVersion: String { AppInfo.version }

    // MARK: - 检查

    func check(userInitiated: Bool) {
        guard !isChecking, !isDownloading else { return }
        isChecking = true

        Task {
            let result = await fetchLatest()
            isChecking = false
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)

            switch result {
            case .failure(let message):
                log("检查更新失败：\(message)")
                if userInitiated { presentFailure(message) }

            case .success(let release):
                if AppVersion(release.version) > AppVersion(currentVersion) {
                    log("发现新版本 \(release.version)")
                    // 自动检查尊重「跳过此版本」；手动检查永远弹
                    let skipped = UserDefaults.standard.string(forKey: Self.skippedKey)
                    if userInitiated || release.version != skipped {
                        presentAvailable(release)
                    }
                } else {
                    log("已是最新版本 \(currentVersion)")
                    if userInitiated { presentUpToDate() }
                }
            }
        }
    }

    func startPeriodicChecks() {
        periodicTimer?.invalidate()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        periodicTimer = timer

        // 启动后稍等再对账，别抢启动窗口
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.checkIfDue()
        }
    }

    private func checkIfDue() {
        guard Settings.shared.autoCheckUpdates else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= 86_400 else { return }
        check(userInitiated: false)
    }

    // MARK: - 网络

    private struct Latest {
        let version: String
        /// 当前架构的 DMG 资产；发布时漏传该架构的包时为 nil，降级到发布页
        let assetURL: URL?
        let assetSize: Int64
    }

    private enum FetchResult {
        case success(Latest)
        case failure(String)
    }

    private func fetchLatest() async -> FetchResult {
        let url = URL(string: "https://api.github.com/repos/\(AppInfo.repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0

            // 一个 release 都还没发时 GitHub 返回 404，这不是错误
            if code == 404 {
                return .success(Latest(version: "0.0.0", assetURL: nil, assetSize: 0))
            }
            guard code == 200 else { return .failure("GitHub 返回 \(code)") }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                return .failure("无法解析发布信息")
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

            // 找当前架构的 DMG，资产名形如 VoiceTap-0.2.0-arm64.dmg
            #if arch(arm64)
            let arch = "arm64"
            #else
            let arch = "x86_64"
            #endif
            var assetURL: URL?
            var assetSize: Int64 = 0
            // 先认精确名（release.sh 的命名契约），再退回模糊匹配。
            // 只做模糊匹配的话，release 里多放一个名字含架构的包（universal 之类）
            // 就会按 assets 顺序选错，装上的不是这一版。
            let expectedName = "\(AppInfo.name)-\(version)-\(arch).dmg"
            if let assets = json["assets"] as? [[String: Any]],
               let asset = assets.first(where: { ($0["name"] as? String) == expectedName })
                ?? assets.first(where: {
                    let name = $0["name"] as? String ?? ""
                    return name.contains(arch) && name.hasSuffix(".dmg")
                }) {
                assetURL = (asset["browser_download_url"] as? String).flatMap(URL.init(string:))
                assetSize = (asset["size"] as? NSNumber)?.int64Value ?? 0
            }
            return .success(Latest(version: version, assetURL: assetURL, assetSize: assetSize))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - 下载

    private func startDownload(_ latest: Latest) {
        guard let url = latest.assetURL, !isDownloading else { return }
        isDownloading = true
        downloadCancelled = false

        let window = ProgressWindow(version: latest.version) { [weak self] in
            self?.cancelDownload()
        }
        window.show()
        progress = window

        let delegate = DownloadDelegate(
            version: latest.version,
            expectedSize: latest.assetSize,
            onProgress: { [weak self] value in
                Task { @MainActor in self?.progress?.update(value) }
            },
            onFinish: { [weak self] result in
                Task { @MainActor in self?.downloadFinished(result) }
            }
        )
        downloadDelegate = delegate
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        downloadSession = session
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()
    }

    func cancelDownload() {
        downloadCancelled = true
        downloadTask?.cancel()
        downloadTask = nil
        // session 强引用 delegate、delegate 又持有回调，不显式释放这一路会整个泄漏
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        downloadDelegate = nil
        isDownloading = false
        closeProgress()
    }

    private func downloadFinished(_ result: DownloadResult) {
        isDownloading = false
        downloadTask = nil
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        downloadDelegate = nil
        closeProgress()

        switch result {
        case .success(let fileURL, let version):
            installAndRestart(from: fileURL, version: version)
        case .failure(let message):
            guard !downloadCancelled else { return }   // 用户主动取消，别再弹错误
            presentInstallFailure(message)
        }
    }

    private func closeProgress() {
        progress?.close()
        progress = nil
    }

    // MARK: - 安装

    /// 期望的签名主体（Developer ID 的 Team ID）。
    ///
    /// 现在是 `nil`：发布包走的是 ad-hoc / 本地自签证书，没有稳定的 Team ID 可固定。
    /// 拿到 Developer ID 之后把 Team ID 填进来，校验会从「签名有效且未被篡改」
    /// 升级成「**确实是我们签的**」——那才是能真正挡住供应链攻击的那一档。
    /// 留空不等于放弃校验：下面仍会校验签名自身完整性与 bundle 身份，
    /// 只是挡不住「私钥/发布账号被盗后签出来的包」。
    private static let expectedTeamID: String? = nil

    private func installAndRestart(from dmg: URL, version: String) {
        let destApp = Bundle.main.bundlePath
        // swift run 之类的非 .app 环境没有可替换的 bundle，别把 .build 目录搅了
        guard destApp.hasSuffix(".app") else {
            NSWorkspace.shared.open(dmg)
            return
        }

        guard let mountPoint = Self.mountDMG(at: dmg.path) else {
            presentInstallFailure("更新包无法打开")
            return
        }
        let sourceApp = "\(mountPoint)/\(AppInfo.name).app"

        // 校验不过就绝不落地。这一步是整条更新链的信任根：下面那个脚本会
        // rm -rf 掉自己的 Contents 再换上包里的东西，装了什么完全由这一步决定。
        let rejection = Self.rejectionReason(forCandidateAt: sourceApp,
                                             expectedVersion: version,
                                             expectedTeamID: Self.expectedTeamID)
        if let rejection {
            Self.detachDMG(mountPoint)
            log("更新包校验失败：\(rejection)")
            presentInstallFailure("更新包未通过安全校验：\(rejection)")
            return
        }

        // 只替换内容、不动 .app 目录本身：bundle 的路径与身份保持不变，
        // 权限授权（跟 bundle ID 走）得以保住。
        //
        // 参数一律走环境变量，不拼进脚本文本：挂载点是磁盘镜像里带出来的字符串，
        // 拼进去等于把镜像内容当代码执行（卷名可控即可注入）。
        // _CodeSignature 必须和它封印的内容一起换，否则签名校验从此失败。
        let script = """
        #!/bin/bash
        set -u
        DEST_APP="${VT_DEST_APP}"
        SRC_APP="${VT_SRC_APP}"
        MOUNT="${VT_MOUNT}"
        PARENT_PID="${VT_PARENT_PID}"

        fail() {
            echo "更新失败：$1" >&2
            hdiutil detach "${MOUNT}" -quiet 2>/dev/null
            rm -rf "${STAGING:-}" "${BACKUP_DIR:-}"
            exit 1
        }

        # 等旧进程真正退出再动它的 bundle。固定 sleep 是猜的：退出慢一点就会被
        # 拆掉正在运行的那个，留下一个崩溃报告和半新半旧的 app。
        for _ in $(seq 1 100); do
            kill -0 "${PARENT_PID}" 2>/dev/null || break
            sleep 0.2
        done
        kill -0 "${PARENT_PID}" 2>/dev/null && fail "旧进程未退出"

        CONTENTS="${DEST_APP}/Contents"
        STAGING="${DEST_APP}/../.voicetap-update-staging"
        BACKUP_DIR="${DEST_APP}/../.voicetap-update-backup"
        rm -rf "${STAGING}" "${BACKUP_DIR}"
        mkdir -p "${STAGING}" "${BACKUP_DIR}" || fail "无法创建暂存目录"

        # 先在同一卷上把新内容完整拼好，再整体换上去。
        # 直接 cp 进 Contents 的话，中途断电/磁盘满会把 app 停在拆了一半的状态，
        # 而更新器本身就在被替换的那部分里，从此无法自愈。
        cp -R "${SRC_APP}/Contents/MacOS" "${STAGING}/MacOS" || fail "拷贝可执行文件失败"
        cp -R "${SRC_APP}/Contents/Resources" "${STAGING}/Resources" || fail "拷贝资源失败"
        cp "${SRC_APP}/Contents/Info.plist" "${STAGING}/Info.plist" || fail "拷贝 Info.plist 失败"
        if [ -d "${SRC_APP}/Contents/_CodeSignature" ]; then
            cp -R "${SRC_APP}/Contents/_CodeSignature" "${STAGING}/_CodeSignature" || fail "拷贝签名失败"
        fi
        shopt -s nullglob
        for b in "${SRC_APP}"/*.bundle; do
            [ -d "$b" ] && { cp -R "$b" "${STAGING}/" || fail "拷贝 bundle 失败"; }
        done
        shopt -u nullglob

        # 同卷 rename 是原子的，两步之间只有极小的空窗。
        # 旧内容先整体挪到备份目录而不是直接删：换完发现起不来还能 mv 回去。
        for part in MacOS Resources Info.plist _CodeSignature; do
            [ -e "${CONTENTS}/${part}" ] && {
                mv "${CONTENTS}/${part}" "${BACKUP_DIR}/" || fail "备份 ${part} 失败"
            }
        done
        for b in "${SRC_APP}"/*.bundle; do
            [ -d "$b" ] || continue
            name="$(basename "$b")"
            [ -e "${DEST_APP}/${name}" ] && {
                mv "${DEST_APP}/${name}" "${BACKUP_DIR}/" || fail "备份 ${name} 失败"
            }
        done

        for part in MacOS Resources Info.plist _CodeSignature; do
            [ -e "${STAGING}/${part}" ] && {
                mv "${STAGING}/${part}" "${CONTENTS}/${part}" || fail "替换 ${part} 失败"
            }
        done
        shopt -s nullglob
        for b in "${STAGING}"/*.bundle; do
            [ -d "$b" ] && { mv "$b" "${DEST_APP}/" || fail "替换 bundle 失败"; }
        done
        shopt -u nullglob

        hdiutil detach "${MOUNT}" -quiet 2>/dev/null
        rm -rf "${STAGING}" "${BACKUP_DIR}"
        xattr -dr com.apple.quarantine "${DEST_APP}" 2>/dev/null
        open "${DEST_APP}"
        rm -f "$0"
        """

        do {
            let scriptPath = NSTemporaryDirectory() + "voicetap_update_\(UUID().uuidString).sh"
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            // 脚本含本机路径，别让别的用户读到
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: scriptPath)

            let process = Process()
            // 用 bash 显式执行。脚本按 bash 语义写的（未匹配的 glob 原样传递），
            // 换 zsh 跑会因 nomatch 直接报错中断，app 会停在拆了一半的状态。
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptPath]
            process.environment = [
                "VT_DEST_APP": destApp,
                "VT_SRC_APP": sourceApp,
                "VT_MOUNT": mountPoint,
                "VT_PARENT_PID": String(ProcessInfo.processInfo.processIdentifier),
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            ]
            try process.run()
            log("更新器已启动，正在替换并重启")
            NSApp.terminate(nil)
        } catch {
            Self.detachDMG(mountPoint)
            NSWorkspace.shared.open(dmg)
        }
    }

    // MARK: 更新包校验

    /// 一个候选 .app 能不能被信任。返回 nil 表示通过，否则是给用户看的原因。
    ///
    /// 三道检查，逐层收紧：
    ///
    /// 1. **身份** —— bundle ID 必须和自己一致。挡住「挂羊头卖狗肉」的包，
    ///    也挡住 release 里混进的别的产物。
    /// 2. **版本** —— 必须和远端声明的版本一致。挡住「缓存/CDN 给了旧包」。
    /// 3. **签名完整性** —— `SecStaticCodeCheckValidity` 验证封印与内容一致。
    ///    ad-hoc 签名也有封印，所以这条对当前发布形态同样有效，
    ///    能挡住「下载途中被改过」「包根本没签名」这两类。
    ///
    /// 挡不住的只有一种：发布账号/私钥被盗后**正常签出来**的包。那要靠
    /// `expectedTeamID` 固定签名主体，等有 Developer ID 时补上。
    private static func rejectionReason(forCandidateAt appPath: String,
                                        expectedVersion: String,
                                        expectedTeamID: String?) -> String? {
        let plist = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return "读不到 Info.plist" }

        guard let bundleID = info["CFBundleIdentifier"] as? String,
              bundleID == Bundle.main.bundleIdentifier
        else { return "包标识不是 \(Bundle.main.bundleIdentifier ?? AppInfo.name)" }

        guard let version = info["CFBundleShortVersionString"] as? String,
              version == expectedVersion
        else { return "包内版本号与发布版本不一致" }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: appPath) as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode
        else { return "无法读取代码签名" }

        // 不传 requirement：校验的是封印本身（资源有没有被改过），而不是签发者。
        // 对 ad-hoc 同样有效，因为 ad-hoc 也是有封印的。
        guard SecStaticCodeCheckValidityWithErrors(code, [], nil, nil) == errSecSuccess
        else { return "代码签名校验失败，包可能已被篡改" }

        if let expectedTeamID {
            var infoCF: CFDictionary?
            guard SecCodeCopySigningInformation(code, [], &infoCF) == errSecSuccess,
                  let dict = infoCF as? [String: Any],
                  let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
                  team == expectedTeamID
            else { return "签名主体不是预期的开发者" }
        }
        return nil
    }

    private static func mountDMG(at path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        // 不加 -noverify：那是跳过镜像内部校验。更新包来自网络，
        // 少一层校验就多一层「内容被换了我们也不知道」。
        process.arguments = ["attach", path, "-nobrowse"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let line = output.components(separatedBy: "\n").first(where: { $0.contains("/Volumes/") }),
              let range = line.range(of: "/Volumes/") else { return nil }
        return String(line[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
    }

    private static func detachDMG(_ mountPoint: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint, "-quiet"]
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - 提示

    private func activate() { NSApp.activate(ignoringOtherApps: true) }

    private func presentAvailable(_ latest: Latest) {
        activate()
        let alert = NSAlert()
        alert.messageText = "有新版本 \(latest.version)"

        if latest.assetURL != nil {
            alert.informativeText = "当前版本 \(currentVersion)。点「下载并安装」后 "
                + "\(AppInfo.name) 会自动完成更新并重新启动。"
            alert.addButton(withTitle: "下载并安装")
            alert.addButton(withTitle: "稍后")
            alert.addButton(withTitle: "跳过此版本")
            switch alert.runModal() {
            case .alertFirstButtonReturn: startDownload(latest)
            case .alertThirdButtonReturn:
                UserDefaults.standard.set(latest.version, forKey: Self.skippedKey)
            default: break
            }
        } else {
            // 这一版的 release 缺当前架构的 DMG，退回发布页手动下载
            alert.informativeText = "当前版本 \(currentVersion)。这一版没有找到适配本机的安装包，"
                + "请前往发布页手动下载。"
            alert.addButton(withTitle: "前往下载")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(Self.releasesPage)
            }
        }
    }

    private func presentUpToDate() {
        activate()
        let alert = NSAlert()
        alert.messageText = "已是最新版本"
        alert.informativeText = "当前版本 \(currentVersion)。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func presentFailure(_ message: String) {
        activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "检查更新失败"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func presentInstallFailure(_ message: String) {
        activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "自动更新失败"
        alert.informativeText = message + "\n\n可以前往发布页手动下载安装。"
        alert.addButton(withTitle: "前往下载")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.releasesPage)
        }
    }

    private func log(_ message: String) { onLog?(message) }
}

// MARK: - 进度窗口

/// 纯 AppKit，跟项目其余部分保持一致
@MainActor
private final class ProgressWindow {

    private let window: NSWindow
    private let bar = NSProgressIndicator()
    private let percentLabel = NSTextField(labelWithString: "0%")
    private let onCancel: () -> Void

    init(version: String, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
            styleMask: [.titled],      // 不给关闭按钮，取消走窗口里的按钮
            backing: .buffered,
            defer: false
        )
        window.title = "软件更新"
        window.isReleasedWhenClosed = false

        let content = NSView()

        let title = NSTextField(labelWithString: "正在下载 \(AppInfo.name) \(version)…")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.translatesAutoresizingMaskIntoConstraints = false

        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.translatesAutoresizingMaskIntoConstraints = false

        percentLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        percentLabel.textColor = .secondaryLabelColor
        percentLabel.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelAction))
        cancel.bezelStyle = .rounded
        cancel.translatesAutoresizingMaskIntoConstraints = false

        for view in [title, bar, percentLabel, cancel] as [NSView] { content.addSubview(view) }

        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 340),

            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),

            bar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            percentLabel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            percentLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),

            cancel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            cancel.centerYAnchor.constraint(equalTo: percentLabel.centerYAnchor),

            content.bottomAnchor.constraint(equalTo: cancel.bottomAnchor, constant: 20),
        ])

        window.contentView = content
        // 先布局定尺寸再居中，反过来会以近零尺寸居中后向右下展开
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func update(_ value: Double) {
        bar.doubleValue = value
        percentLabel.stringValue = "\(Int(value * 100))%"
    }

    func close() {
        window.orderOut(nil)
    }

    @objc private func cancelAction() { onCancel() }
}

// MARK: - 下载代理

/// 成功时连版本号一起带回：装包前要用它和包内 Info.plist 对账，
/// 光凭「下载成功」无法保证拿到的就是这一版。
private enum DownloadResult: Sendable {
    case success(URL, String)
    case failure(String)
}

/// URLSession 的回调不在主线程，单独一个类接住，回主线程只传数据。
///
/// `@unchecked Sendable`：`finished` 是可变状态，但 URLSession 的 delegate 回调
/// 都投递到同一个串行 delegate queue，不会并发进入，因此无需额外加锁。
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let version: String
    private let expectedSize: Int64
    private let onProgress: @Sendable (Double) -> Void
    private let onFinish: @Sendable (DownloadResult) -> Void
    /// 成功路径已经回调过，didCompleteWithError 的 nil error 不再重复回调
    private var finished = false

    init(version: String,
         expectedSize: Int64,
         onProgress: @escaping @Sendable (Double) -> Void,
         onFinish: @escaping @Sendable (DownloadResult) -> Void) {
        self.version = version
        self.expectedSize = expectedSize
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // 名字随机：固定路径等于给同机其他进程留了一个可预测的可写目标
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceTap-update-\(UUID().uuidString).dmg")

        // location 是系统临时文件，回调返回后立即被删，必须先挪走
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            finished = true
            onFinish(.failure(error.localizedDescription))
            return
        }

        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)

        // 校验字节数：CDN 截断、连接中断的包不能进安装环节
        if expectedSize > 0,
           let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
           let fileSize = attrs[.size] as? Int64,
           fileSize != expectedSize {
            try? FileManager.default.removeItem(at: dest)
            finished = true
            onFinish(.failure("下载不完整（\(fileSize)/\(expectedSize) 字节）"))
            return
        }

        finished = true
        onFinish(.success(dest, version))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : max(expectedSize, 1)
        onProgress(Double(totalBytesWritten) / Double(total))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: (any Error)?) {
        guard let error, !finished else { return }
        finished = true
        onFinish(.failure(error.localizedDescription))
    }
}
