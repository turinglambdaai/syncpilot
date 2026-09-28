export interface Peer {
  id: string;
  name: string;
  status?: string | null;
  connection?: string | null;
  syncstate?: string | null;
  isreadable?: boolean | null;
  iswritable?: boolean | null;
  percent_downloaded?: number | null;
  download?: number | null;
  upload?: number | null;
}

export interface Folder {
  id: string;
  secret: string;
  path: string;
  ispaused: boolean;
  size?: number | null;
  date_added?: number | null;
  synclevel?: number | null;
  peers: Peer[];
}

export interface KnownPeer {
  id: string;
  name: string;
  clientversion?: string | null;
  os?: string | null;
}

export interface RuntimeStatus {
  speed_up: number;
  speed_down: number;
  paused: boolean;
  uptime?: number | null;
  version?: string | null;
}

export type Phase = "stopped" | "starting" | "running" | "crashed" | "failed";

export interface DaemonStatus {
  phase: Phase;
  pid?: number | null;
  uptime_secs?: number | null;
  binary?: string | null;
  error?: string | null;
  autostart: boolean;
}

export interface AppSettings {
  rslsync_path: string;
  webui_port: number;
  webui_login: string;
  webui_password: string;
  api_key: string;
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

export interface SpeedLimits {
  up_kbps?: number | null;
  down_kbps?: number | null;
}

export interface GeneratedSecrets {
  secret: string;
  read_only?: string | null;
  encryption?: string | null;
}
