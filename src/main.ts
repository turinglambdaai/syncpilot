import { api } from "./bridge";
import { navigate, setRenderApp, state } from "./store";
import { renderOverview, folderStateClass } from "./views/overview";
import { renderFolderView } from "./views/folder";
import { renderAdd } from "./views/add";
import { renderSettings } from "./views/settings";
import { basename, el, fmtSpeed, toast } from "./ui";

const PHASE_LABEL: Record<string, string> = {
  stopped: "Stopped",
  starting: "Starting…",
  running: "Running",
  crashed: "Crashed",
  failed: "Failed",
};

function renderSidebar() {
  const list = document.getElementById("nav-items");
  if (!list) return;
  list.innerHTML = "";

  const ov = el("button", `nav-item ${state.route.name === "overview" ? "active" : ""}`);
  ov.append(el("span", "nav-glyph", "⇅"), el("span", "Overview"));
  ov.onclick = () => navigate({ name: "overview" });
  list.append(ov);

  list.append(el("div", "nav-label", "Folders"));
  for (const f of state.folders) {
    const item = el(
      "button",
      `nav-item ${state.route.name === "folder" && state.route.id === f.id ? "active" : ""}`,
    );
    item.append(el("span", `nav-dot status-dot ${folderStateClass(f)}`));
    item.append(el("span", "nav-text", basename(f.path) || f.path));
    item.title = f.path;
    item.onclick = () => navigate({ name: "folder", id: f.id });
    list.append(item);
  }

  const add = el("button", "nav-add", "+ Add Folder");
  add.onclick = () => navigate({ name: "add" });
  list.append(add);

  const settingsNav = document.getElementById("nav-settings");
  if (settingsNav) {
    settingsNav.classList.toggle("active", state.route.name === "settings");
    settingsNav.onclick = () => navigate({ name: "settings" });
  }
}

function renderTopbar() {
  const bar = document.getElementById("topbar");
  if (!bar) return;
  bar.innerHTML = "";

  const d = state.daemon;
  const phase = d?.phase ?? "stopped";
  const pill = el("span", `daemon-pill ${phase}`);
  pill.append(el("span", "dot"), PHASE_LABEL[phase]);
  bar.append(pill);

  const speeds = el("div", "speeds");
  speeds.append(
    el("span", "speed down", `↓ ${fmtSpeed(state.status?.speed_down ?? 0)}`),
    el("span", "speed up", `↑ ${fmtSpeed(state.status?.speed_up ?? 0)}`),
  );
  bar.append(speeds);

  const actions = el("div", "topbar-actions");
  if (phase === "running") {
    // No pause/resume control: rslsync 3.x has no global-pause action.
    const stopBtn = el("button", "btn ghost danger", "Stop Daemon");
    stopBtn.onclick = async () => {
      try {
        await api.daemonStop();
        toast("Daemon stopped");
      } catch (e) {
        toast(String(e), "err");
      }
    };
    actions.append(stopBtn);
  } else {
    const startBtn = el(
      "button",
      "btn primary",
      phase === "starting" ? "Starting…" : "Start Daemon",
    ) as HTMLButtonElement;
    startBtn.disabled = phase === "starting";
    startBtn.onclick = async () => {
      startBtn.disabled = true;
      try {
        await api.daemonStart();
        toast("Daemon started");
      } catch (e) {
        toast(String(e), "err");
      }
    };
    actions.append(startBtn);
  }
  bar.append(actions);
}

function renderView() {
  const view = document.getElementById("view");
  if (!view) return;
  view.innerHTML = "";
  switch (state.route.name) {
    case "overview":
      renderOverview(view);
      break;
    case "folder":
      renderFolderView(view, state.route.id);
      break;
    case "add":
      renderAdd(view);
      break;
    case "settings":
      renderSettings(view);
      break;
  }
}

function renderApp() {
  renderSidebar();
  renderTopbar();
  renderView();
}

// While the user is on a form view, only refresh chrome — never the form.
function refreshDynamic() {
  renderSidebar();
  renderTopbar();
  if (state.route.name === "overview" || state.route.name === "folder") {
    renderView();
  }
}

let ticking = false;
async function tick() {
  if (ticking) return;
  ticking = true;
  try {
    const d = await api.daemonStatus();
    state.daemon = d;
    if (d.phase === "running") {
      const [st, folders, lic] = await Promise.all([
        api.syncStatus(),
        api.listFolders(),
        api.licenseState().catch(() => null),
      ]);
      state.status = st;
      state.folders = folders ?? [];
      state.license = lic;
      if (st) {
        state.history.push({ up: st.speed_up, down: st.speed_down });
        if (state.history.length > 90) state.history.shift();
      }
    } else {
      state.status = null;
      state.folders = [];
      state.license = null;
    }
    refreshDynamic();
  } catch (e) {
    console.error("tick failed", e);
  } finally {
    ticking = false;
  }
}

async function init() {
  try {
    const [settings, version] = await Promise.all([api.getAppSettings(), api.getVersion()]);
    state.settings = settings;
    state.version = version;
  } catch (e) {
    console.error("init failed", e);
  }
  const sideVersion = document.getElementById("side-version");
  if (sideVersion) sideVersion.textContent = `v${state.version}`;
  setRenderApp(renderApp);
  renderApp();
  await tick();
  setInterval(tick, 1500);
}

init();
