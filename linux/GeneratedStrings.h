// Generated from shared/i18n/{zh,en}.json — the single i18n source.
// Do not edit; run: node scripts/gen-c-strings.mjs
#pragma once

#include <cstddef>
#include <map>
#include <string>
#include <vector>

namespace l10n {

// Active UI language: "zh" (default) or "en".
inline std::string language = "zh";

// zh is the default language (byte-identical copy of shared/i18n/zh.json).
inline const std::map<std::string, std::string> kZh = {
    {"boot.starting", "正在启动 Resilio Sync 守护进程…"},
    {"boot.handoff", "正在移交官方界面（rslsync {version}）…"},
    {"boot.notReady", "守护进程尚未就绪。"},
    {"boot.retry", "重试"},
    {"boot.notInstalled", "尚未安装 Resilio Sync。"},
    {"boot.installDetail", "SyncPilot 运行官方 rslsync 二进制。现在从 Resilio CDN 下载（已校验哈希）到 ~/.local/bin，或在设置中指定已有二进制的路径。"},
    {"boot.download", "下载 Resilio Sync（约 15 MB）"},
    {"boot.downloading", "下载中…"},
    {"boot.downloadFailedRetry", "下载失败 — 重试"},
    {"boot.installedToast", "已安装：{path}"},
    {"boot.installHint", "{error} —— 你也可以自行安装 rslsync 并在设置中指定其路径。"},
    {"boot.openSettings", "打开 SyncPilot 设置"},
    {"settings.title", "SyncPilot 设置"},
    {"settings.loading", "加载中…"},
    {"settings.daemon", "守护进程"},
    {"settings.binaryLabel", "rslsync 二进制 — {detail}"},
    {"settings.binaryNotDetected", "尚未检测到"},
    {"settings.binaryPlaceholder", "自动检测（~/.local/bin、/usr/bin 等）"},
    {"settings.browse", "浏览…"},
    {"settings.restartDaemon", "重启守护进程"},
    {"settings.daemonRestarted", "守护进程已重启"},
    {"settings.startWithApp", "随 SyncPilot 一起启动守护进程"},
    {"settings.restartOnCrash", "守护进程崩溃后自动重启"},
    {"settings.keepDaemonOnExit", "SyncPilot 退出时保持守护进程运行"},
    {"settings.device", "设备"},
    {"settings.deviceNameLabel", "显示给同步对端的设备名"},
    {"settings.portLabel", "本地 API 端口（仅本机回环，1024–65535）"},
    {"settings.desktop", "桌面"},
    {"settings.launchAtLogin", "登录时启动 SyncPilot"},
    {"settings.willStartAtLogin", "将在登录时启动"},
    {"settings.willNotStartAtLogin", "将不在登录时启动"},
    {"settings.hideToTray", "关闭窗口时隐藏到托盘而非退出"},
    {"settings.updates", "更新"},
    {"settings.checkForUpdates", "检查更新"},
    {"settings.checking", "检查中…"},
    {"settings.upToDate", "已是最新版本（v{version}）。"},
    {"settings.updateAvailable", "SyncPilot {version} 可用。"},
    {"settings.downloadAndRestart", "下载并重启"},
    {"settings.downloadAndInstall", "下载并安装…"},
    {"settings.openReleasePage", "打开发布页"},
    {"settings.downloadingUpdate", "正在下载更新…"},
    {"settings.downloadingDeb", "下载中…随后请在系统对话框中确认安装"},
    {"settings.updateCheckFailed", "检查更新失败：{error}"},
    {"settings.about", "关于"},
    {"settings.aboutText", "SyncPilot v{version} —— Linux 上 Resilio Sync（rslsync）的非官方桌面外壳。窗口内展示的是官方 Resilio Web UI。AGPL-3.0。github.com/turinglambdaai/syncpilot"},
    {"settings.save", "保存设置"},
    {"settings.saved", "设置已保存"},
    {"settings.savedRestartForPort", "已保存。重启守护进程以应用新端口。"},
    {"settings.regeneratePassword", "重新生成 Web UI 密码"},
    {"settings.passwordRegenerated", "已生成新密码。重启守护进程后生效。"},
    {"daemon.phase.stopped", "已停止"},
    {"daemon.phase.starting", "启动中"},
    {"daemon.phase.running", "运行中"},
    {"daemon.phase.crashed", "已崩溃"},
    {"daemon.phase.failed", "失败"},
    {"daemon.probe.compatible", "端口上是兼容的守护进程"},
    {"daemon.probe.foreign", "端口被其他服务占用"},
    {"daemon.probe.unreachable", "端口上没有服务响应"},
    {"error.binaryNotFound", "未找到 rslsync 二进制。请安装 Resilio Sync，或在设置中指定其路径。"},
    {"error.portConflict", "端口 {port} 已被另一个使用不同凭据的 Resilio Sync 守护进程占用——通常是遗留的系统服务。请退出该守护进程，或在托盘 → SyncPilot 设置… 中更改 SyncPilot 的端口后重试。"},
    {"error.startTimeout", "守护进程在 {seconds} 秒内未响应"},
    {"error.crashed", "守护进程意外退出"},
    {"error.notInitialized", "后端尚未初始化；请先调用 init"},
    {"error.checksumMismatch", "校验和不匹配：期望 {expected}，实际 {actual}——固定的 Resilio stable 可能已更新；请重新固定或手动安装"},
    {"error.installFailed", "{error} —— 请检查网络连接后重试，或手动安装 Resilio Sync"},
    {"error.authRejected", "基本认证被拒绝（请检查 Web UI 凭据）"},
};

inline const std::map<std::string, std::string> kEn = {
    {"boot.starting", "Starting the Resilio Sync daemon…"},
    {"boot.handoff", "Handing over to the official interface (rslsync {version})…"},
    {"boot.notReady", "The daemon is not ready."},
    {"boot.retry", "Retry"},
    {"boot.notInstalled", "Resilio Sync is not installed yet."},
    {"boot.installDetail", "SyncPilot runs the official rslsync binary. Download it now from Resilio's CDN (checksum verified) into ~/.local/bin, or point SyncPilot at an existing binary in Settings."},
    {"boot.download", "Download Resilio Sync (~15 MB)"},
    {"boot.downloading", "Downloading…"},
    {"boot.downloadFailedRetry", "Download failed — retry"},
    {"boot.installedToast", "Installed: {path}"},
    {"boot.installHint", "{error} — you can also install rslsync yourself and set its path in Settings."},
    {"boot.openSettings", "Open SyncPilot Settings"},
    {"settings.title", "SyncPilot Settings"},
    {"settings.loading", "Loading…"},
    {"settings.daemon", "Daemon"},
    {"settings.binaryLabel", "rslsync binary — {detail}"},
    {"settings.binaryNotDetected", "not detected yet"},
    {"settings.binaryPlaceholder", "auto-detect (~/.local/bin, /usr/bin, …)"},
    {"settings.browse", "Browse…"},
    {"settings.restartDaemon", "Restart Daemon"},
    {"settings.daemonRestarted", "Daemon restarted"},
    {"settings.startWithApp", "Start daemon together with SyncPilot"},
    {"settings.restartOnCrash", "Restart daemon after a crash"},
    {"settings.keepDaemonOnExit", "Keep daemon running when SyncPilot exits"},
    {"settings.device", "Device"},
    {"settings.deviceNameLabel", "Device name shown to peers"},
    {"settings.portLabel", "Local API port (loopback only, 1024–65535)"},
    {"settings.desktop", "Desktop"},
    {"settings.launchAtLogin", "Launch SyncPilot at login"},
    {"settings.willStartAtLogin", "Will start at login"},
    {"settings.willNotStartAtLogin", "Will not start at login"},
    {"settings.hideToTray", "Hide to tray on close instead of quitting"},
    {"settings.updates", "Updates"},
    {"settings.checkForUpdates", "Check for updates"},
    {"settings.checking", "Checking…"},
    {"settings.upToDate", "You are up to date (v{version})."},
    {"settings.updateAvailable", "SyncPilot {version} is available."},
    {"settings.downloadAndRestart", "Download & restart"},
    {"settings.downloadAndInstall", "Download & install…"},
    {"settings.openReleasePage", "Open release page"},
    {"settings.downloadingUpdate", "Downloading update…"},
    {"settings.downloadingDeb", "Downloading… then approve the install in the system dialog"},
    {"settings.updateCheckFailed", "Update check failed: {error}"},
    {"settings.about", "About"},
    {"settings.aboutText", "SyncPilot v{version} — an unofficial desktop shell for Resilio Sync (rslsync) on Linux. The window shows the official Resilio Web UI. AGPL-3.0. github.com/turinglambdaai/syncpilot"},
    {"settings.save", "Save Settings"},
    {"settings.saved", "Settings saved"},
    {"settings.savedRestartForPort", "Saved. Restart the daemon to apply the new port."},
    {"settings.regeneratePassword", "Regenerate Web UI password"},
    {"settings.passwordRegenerated", "New password generated. Restart the daemon to apply it."},
    {"daemon.phase.stopped", "Stopped"},
    {"daemon.phase.starting", "Starting"},
    {"daemon.phase.running", "Running"},
    {"daemon.phase.crashed", "Crashed"},
    {"daemon.phase.failed", "Failed"},
    {"daemon.probe.compatible", "Compatible daemon on the port"},
    {"daemon.probe.foreign", "Another service owns the port"},
    {"daemon.probe.unreachable", "Nothing answered on the port"},
    {"error.binaryNotFound", "rslsync binary not found. Install Resilio Sync or set its path in Settings."},
    {"error.portConflict", "Port {port} is used by another Resilio Sync daemon with different credentials — often a leftover system service. Quit that daemon, or change SyncPilot's port under tray → SyncPilot Settings…, then retry."},
    {"error.startTimeout", "daemon did not answer within {seconds}s"},
    {"error.crashed", "daemon exited unexpectedly"},
    {"error.notInitialized", "backend is not initialized; call init first"},
    {"error.checksumMismatch", "checksum mismatch: expected {expected}, got {actual} — the pinned Resilio stable may have moved; re-pin or install manually"},
    {"error.installFailed", "{error} — check your network connection and retry, or install Resilio Sync manually"},
    {"error.authRejected", "basic auth rejected (check webui credentials)"},
};

// Placeholder names per key, in the order l10n::t binds its args.
inline const std::map<std::string, std::vector<std::string>> kPlaceholders = {
    {"boot.handoff", {"version"}},
    {"boot.installedToast", {"path"}},
    {"boot.installHint", {"error"}},
    {"settings.binaryLabel", {"detail"}},
    {"settings.upToDate", {"version"}},
    {"settings.updateAvailable", {"version"}},
    {"settings.updateCheckFailed", {"error"}},
    {"settings.aboutText", {"version"}},
    {"error.portConflict", {"port"}},
    {"error.startTimeout", {"seconds"}},
    {"error.checksumMismatch", {"expected", "actual"}},
    {"error.installFailed", {"error"}},
};

// Look up a key in the active language, falling back to zh then the key
// itself. The i-th arg replaces the key's i-th named placeholder.
inline std::string t(std::string const& key,
                     std::vector<std::string> const& args = {}) {
  auto const find = [&](std::map<std::string, std::string> const& table)
      -> std::string const* {
    auto const it = table.find(key);
    return it == table.end() ? nullptr : &it->second;
  };
  std::string const* text = language == "en" ? find(kEn) : find(kZh);
  if (text == nullptr) text = find(kZh);
  std::string out = text != nullptr ? *text : key;

  auto const names = kPlaceholders.find(key);
  if (names != kPlaceholders.end()) {
    std::size_t const count =
        names->second.size() < args.size() ? names->second.size() : args.size();
    for (std::size_t i = 0; i < count; ++i) {
      std::string const placeholder = "{" + names->second[i] + "}";
      std::size_t pos = 0;
      while ((pos = out.find(placeholder, pos)) != std::string::npos) {
        out.replace(pos, placeholder.size(), args[i]);
        pos += args[i].size();
      }
    }
  }
  return out;
}

}  // namespace l10n
