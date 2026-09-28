import { invoke } from "@tauri-apps/api/core";
import { openPath } from "@tauri-apps/plugin-opener";
import type {
  AppSettings,
  DaemonStatus,
  Folder,
  GeneratedSecrets,
  KnownPeer,
  LicenseState,
  RuntimeStatus,
  SettingsUpdate,
  SpeedLimits,
} from "./types";

export const api = {
  daemonStatus: () => invoke<DaemonStatus>("daemon_status"),
  daemonStart: () => invoke<DaemonStatus>("daemon_start"),
  daemonStop: () => invoke<DaemonStatus>("daemon_stop"),
  syncStatus: () => invoke<RuntimeStatus | null>("sync_status"),
  listFolders: () => invoke<Folder[]>("list_folders"),
  listKnownPeers: () => invoke<KnownPeer[]>("list_known_peers"),
  addFolder: (path: string, secret?: string) =>
    invoke<void>("add_folder", { path, secret: secret || undefined }),
  removeFolder: (id: string) => invoke<void>("remove_folder", { id }),
  pauseFolder: (id: string, paused: boolean) =>
    invoke<void>("pause_folder", { id, paused }),
  pauseAll: (paused: boolean) => invoke<void>("pause_all", { paused }),
  generateSecret: () => invoke<GeneratedSecrets>("generate_secret"),
  licenseState: () => invoke<LicenseState>("license_state"),
  startTrial: () => invoke<void>("start_trial"),
  getSpeedLimits: () => invoke<SpeedLimits>("get_speed_limits"),
  setSpeedLimits: (upKbps: number | null, downKbps: number | null) =>
    invoke<void>("set_speed_limits", { upKbps, downKbps }),
  getAppSettings: () => invoke<AppSettings>("get_app_settings"),
  updateAppSettings: (update: SettingsUpdate) =>
    invoke<AppSettings>("update_app_settings", { update }),
  getAutostart: () => invoke<boolean>("get_autostart"),
  setAutostart: (enable: boolean) =>
    invoke<boolean>("set_autostart", { enable }),
  pickFolder: () => invoke<string | null>("pick_folder"),
  getVersion: () => invoke<string>("get_app_version"),
  openPath: (path: string) => openPath(path),
};
