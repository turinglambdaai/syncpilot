import { api } from "../bridge";
import { state } from "../store";
import { el, toast } from "../ui";
import type { SettingsUpdate } from "../types";

function fieldLabel(text: string): HTMLElement {
  return el("div", "field-label", text);
}

function checkbox(label: string, checked: boolean, on: (v: boolean) => void): HTMLElement {
  const row = el("label", "check-row");
  const cb = el("input") as HTMLInputElement;
  cb.type = "checkbox";
  cb.checked = checked;
  cb.onchange = () => on(cb.checked);
  row.append(cb, el("span", "check-label", label));
  return row;
}

function textInput(value: string, placeholder?: string): HTMLInputElement {
  const i = el("input", "text-input") as HTMLInputElement;
  i.value = value;
  if (placeholder) i.placeholder = placeholder;
  return i;
}

export function renderSettings(root: HTMLElement) {
  const wrap = el("div", "view narrow");
  wrap.append(el("h1", "view-title", "Settings"));
  const s = state.settings;
  if (!s) {
    wrap.append(el("p", "empty-sub", "Loading…"));
    root.append(wrap);
    return;
  }

  const draft: SettingsUpdate = {
    rslsync_path: s.rslsync_path,
    webui_port: s.webui_port,
    device_name: s.device_name,
    autostart_daemon: s.autostart_daemon,
    restart_on_crash: s.restart_on_crash,
    keep_daemon_on_exit: s.keep_daemon_on_exit,
    close_to_tray: s.close_to_tray,
  };

  // ---- daemon ----
  const g1 = el("div", "card settings-card");
  g1.append(el("div", "card-title", "Daemon"));
  const binInput = textInput(s.rslsync_path, "auto-detect (/usr/bin/rslsync)");
  binInput.oninput = () => (draft.rslsync_path = binInput.value);
  const binRow = el("div", "field-row");
  binRow.append(binInput);
  g1.append(fieldLabel(`rslsync binary — ${state.daemon?.binary ?? "not detected yet"}`), binRow);
  g1.append(
    checkbox("Start daemon together with SyncPilot", s.autostart_daemon, (v) => (draft.autostart_daemon = v)),
    checkbox("Restart daemon after a crash", s.restart_on_crash, (v) => (draft.restart_on_crash = v)),
    checkbox("Keep daemon running when SyncPilot exits", s.keep_daemon_on_exit, (v) => (draft.keep_daemon_on_exit = v)),
    checkbox("Hide to tray on close instead of quitting", s.close_to_tray, (v) => (draft.close_to_tray = v)),
  );

  // ---- device ----
  const g2 = el("div", "card settings-card");
  g2.append(el("div", "card-title", "Device"));
  const nameInput = textInput(s.device_name);
  nameInput.oninput = () => (draft.device_name = nameInput.value);
  g2.append(fieldLabel("Device name shown to peers"), nameInput);
  const portInput = el("input", "text-input") as HTMLInputElement;
  portInput.type = "number";
  portInput.value = String(s.webui_port);
  portInput.oninput = () => (draft.webui_port = Number(portInput.value) || s.webui_port);
  g2.append(fieldLabel("Local API port (loopback only, 1024–65535)"), portInput);

  // ---- desktop ----
  const g3 = el("div", "card settings-card");
  g3.append(el("div", "card-title", "Desktop"));
  const autoRow = checkbox("Launch SyncPilot at login", false, () => {});
  const autoBox = autoRow.querySelector("input") as HTMLInputElement;
  api
    .getAutostart()
    .then((v) => (autoBox.checked = v))
    .catch(() => {});
  autoBox.onchange = async () => {
    try {
      await api.setAutostart(autoBox.checked);
      toast(autoBox.checked ? "Will start at login" : "Will not start at login");
    } catch (e) {
      toast(String(e), "err");
      autoBox.checked = !autoBox.checked;
    }
  };
  g3.append(autoRow);

  // ---- transfers ----
  const g4 = el("div", "card settings-card");
  g4.append(el("div", "card-title", "Speed limits"));
  const upInput = el("input", "text-input") as HTMLInputElement;
  const downInput = el("input", "text-input") as HTMLInputElement;
  upInput.type = "number";
  downInput.type = "number";
  upInput.placeholder = "unlimited";
  downInput.placeholder = "unlimited";
  g4.append(
    fieldLabel("Upload limit (kbit/s, empty = unlimited)"),
    upInput,
    fieldLabel("Download limit (kbit/s, empty = unlimited)"),
    downInput,
  );
  const applyLimits = el("button", "btn ghost", "Apply limits") as HTMLButtonElement;
  applyLimits.onclick = async () => {
    applyLimits.disabled = true;
    try {
      const parse = (v: HTMLInputElement) => {
        const n = Number(v.value);
        return v.value.trim() === "" ? null : isFinite(n) && n >= 0 ? Math.round(n) : null;
      };
      await api.setSpeedLimits(parse(upInput), parse(downInput));
      toast("Speed limits applied");
    } catch (e) {
      toast(String(e), "err");
    } finally {
      applyLimits.disabled = false;
    }
  };
  g4.append(applyLimits);
  if (state.daemon?.phase !== "running") {
    g4.append(el("div", "card-note", "The daemon must be running to apply limits."));
  } else {
    api
      .getSpeedLimits()
      .then((l) => {
        if (l.up_kbps != null) upInput.value = String(l.up_kbps);
        if (l.down_kbps != null) downInput.value = String(l.down_kbps);
      })
      .catch(() => {});
  }

  // ---- about ----
  const g5 = el("div", "card settings-card");
  g5.append(el("div", "card-title", "About"));
  g5.append(
    el(
      "div",
      "card-note",
      `SyncPilot v${state.version} — an unofficial desktop GUI for Resilio Sync (rslsync) on Linux. AGPL-3.0. github.com/turinglambdaai/syncpilot`,
    ),
  );

  // ---- save ----
  const err = el("div", "form-error");
  const save = el("button", "btn primary", "Save Settings") as HTMLButtonElement;
  save.onclick = async () => {
    save.disabled = true;
    try {
      const updated = await api.updateAppSettings(draft);
      state.settings = updated;
      const portChanged = updated.webui_port !== s.webui_port;
      toast(
        portChanged
          ? "Saved. Restart the daemon to apply the new port."
          : "Settings saved",
      );
    } catch (e) {
      err.textContent = String(e);
    } finally {
      save.disabled = false;
    }
  };

  wrap.append(g1, g2, g3, g4, g5, save, err);
  root.append(wrap);
}
