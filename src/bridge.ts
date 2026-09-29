import { invoke } from "@tauri-apps/api/core";
import { openPath, openUrl } from "@tauri-apps/plugin-opener";

export interface DaemonStatus {
  phase: "stopped" | "starting" | "running" | "crashed" | "failed";
  pid?: number | null;
  uptime_secs?: number | null;
  binary?: string | null;
  error?: string | null;
  autostart: boolean;
}

export interface GuiHandoff {
  url: string;
  version?: string | null;
}

export interface AppSettings {
  rslsync_path: string;
  webui_port: number;
  webui_login: string;
  webui_password: string;
  device_name: string;
  autostart_daemon: boolean;
  restart_on_crash: boolean;
  keep_daemon_on_exit: boolean;
  close_to_tray: boolean;
}

export interface SettingsUpdate {
  rslsync_path?: string;
  webui_port?: number;
  device_name?: string;
  autostart_daemon?: boolean;
  restart_on_crash?: boolean;
  keep_daemon_on_exit?: boolean;
  close_to_tray?: boolean;
}

export interface UpdateInfo {
  version: string;
  notes?: string | null;
  appimage: boolean;
}

export const api = {
  daemonStatus: () => invoke<DaemonStatus>("daemon_status"),
  daemonStart: () => invoke<DaemonStatus>("daemon_start"),
  daemonStop: () => invoke<DaemonStatus>("daemon_stop"),
  guiUrl: () => invoke<GuiHandoff>("gui_url"),
  installRslsync: () => invoke<string>("install_rslsync"),
  getAppSettings: () => invoke<AppSettings>("get_app_settings"),
  updateAppSettings: (update: SettingsUpdate) =>
    invoke<AppSettings>("update_app_settings", { update }),
  getAutostart: () => invoke<boolean>("get_autostart"),
  setAutostart: (enable: boolean) =>
    invoke<boolean>("set_autostart", { enable }),
  openSettings: () => invoke<void>("open_settings"),
  pickFolder: () => invoke<string | null>("pick_folder"),
  getVersion: () => invoke<string>("get_app_version"),
  openPath: (path: string) => openPath(path),
  openUrl: (url: string) => openUrl(url),
  checkForUpdates: () => invoke<UpdateInfo | null>("check_for_updates"),
  installUpdate: () => invoke<void>("install_update"),
};
