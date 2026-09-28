import type { AppSettings, DaemonStatus, Folder, LicenseState, RuntimeStatus } from "./types";

export type Route =
  | { name: "overview" }
  | { name: "folder"; id: string }
  | { name: "add" }
  | { name: "settings" };

export interface AppState {
  route: Route;
  folders: Folder[];
  status: RuntimeStatus | null;
  daemon: DaemonStatus | null;
  license: LicenseState | null;
  history: { up: number; down: number }[];
  settings: AppSettings | null;
  version: string;
}

export const state: AppState = {
  route: { name: "overview" },
  folders: [],
  status: null,
  daemon: null,
  license: null,
  history: [],
  settings: null,
  version: "",
};

export function navigate(route: Route) {
  state.route = route;
  renderApp();
}

// Set by main.ts at startup; avoids a circular import between views and main.
export let renderApp: () => void = () => {};
export function setRenderApp(fn: () => void) {
  renderApp = fn;
}
