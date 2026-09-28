import { api } from "../bridge";
import { state, navigate } from "../store";
import { el, fmtSize, toast, basename } from "../ui";
import type { Folder } from "../types";

export function folderStateClass(f: Folder): string {
  if (f.ispaused) return "paused";
  const syncing = f.peers.some((p) => (p.syncstate ?? "") === "syncing");
  if (syncing) return "sync";
  const online = f.peers.some(
    (p) => (p.status ?? "") === "online" || (p.syncstate ?? "") === "synced",
  );
  return online ? "ok" : "idle";
}

export function peerStateClass(p: { status?: string | null; syncstate?: string | null }): string {
  if ((p.syncstate ?? "") === "syncing") return "sync";
  if ((p.status ?? "") === "online" || (p.syncstate ?? "") === "synced") return "ok";
  return "idle";
}

function speedCard(label: string, value: number, cls: string): HTMLElement {
  const card = el("div", `card stat-card ${cls}`);
  card.append(el("div", "stat-label", label));
  card.append(el("div", "stat-value", fmtSize(value)));
  card.append(el("div", "stat-unit", "per second"));
  return card;
}

function drawSparkline(canvas: HTMLCanvasElement) {
  const ctx = canvas.getContext("2d");
  if (!ctx) return;
  const { width: w, height: h } = canvas;
  ctx.clearRect(0, 0, w, h);
  const hist = state.history;
  if (hist.length < 2) {
    ctx.fillStyle = "#98a2b3";
    ctx.font = "12px sans-serif";
    ctx.fillText("waiting for data…", 10, h / 2);
    return;
  }
  const max = Math.max(1, ...hist.map((p) => Math.max(p.up, p.down)));
  const step = w / (hist.length - 1);
  const line = (key: "up" | "down", color: string) => {
    ctx.beginPath();
    hist.forEach((p, i) => {
      const x = i * step;
      const y = h - 6 - (p[key] / max) * (h - 16);
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    });
    ctx.strokeStyle = color;
    ctx.lineWidth = 1.8;
    ctx.lineJoin = "round";
    ctx.stroke();
  };
  line("down", "#2563eb");
  line("up", "#16a34a");
}

function folderCard(f: Folder): HTMLElement {
  const card = el("div", "card folder-card");
  card.onclick = () => navigate({ name: "folder", id: f.id });
  const head = el("div", "folder-card-head");
  head.append(el("span", `status-dot ${folderStateClass(f)}`));
  head.append(el("span", "folder-name", basename(f.path) || f.path));
  if (f.ispaused) head.append(el("span", "badge", "Paused"));
  head.append(el("span", "spacer"));
  head.append(el("span", "chev", "›"));
  card.append(head);
  card.append(el("div", "folder-path", f.path));

  const peersOnline = f.peers.filter(
    (p) => (p.status ?? "") === "online" || (p.syncstate ?? "") !== "offline",
  ).length;
  const syncing = f.peers.filter((p) => (p.syncstate ?? "") === "syncing").length;
  const meta = el("div", "folder-meta");
  meta.append(el("span", "", fmtSize(f.size)));
  meta.append(el("span", "", `${peersOnline} peer${peersOnline === 1 ? "" : "s"}`));
  if (syncing > 0) meta.append(el("span", "syncing-label", `${syncing} syncing`));
  card.append(meta);
  return card;
}

export function renderOverview(root: HTMLElement) {
  const wrap = el("div", "view");
  const d = state.daemon;

  if (d && d.phase !== "running") {
    const banner = el("div", "banner warn");
    const msg =
      d.phase === "starting"
        ? "Starting the rslsync daemon…"
        : (d.error ?? `The daemon is ${d.phase}.`);
    banner.append(el("div", "banner-text", msg));
    if (d.phase === "stopped" || d.phase === "failed" || d.phase === "crashed") {
      const b = el("button", "btn primary", "Start Daemon");
      b.onclick = async () => {
        b.disabled = true;
        try {
          await api.daemonStart();
          toast("Daemon started");
        } catch (e) {
          toast(String(e), "err");
        }
      };
      banner.append(b);
    }
    wrap.append(banner);
  }

  if (d && d.phase === "running" && state.license && !state.license.allowed_to_sync) {
    const banner = el("div", "banner warn");
    banner.append(
      el(
        "div",
        "banner-text",
        "rslsync 3.x requires activation before folders can sync. " +
          "Start the free trial here, or sign in via the official web UI at " +
          `http://127.0.0.1:${state.settings?.webui_port ?? 38889}/gui/.`,
      ),
    );
    if (state.license.can_use_trial) {
      const b = el("button", "btn primary", "Start Free Trial");
      b.onclick = async () => {
        b.disabled = true;
        try {
          await api.startTrial();
          toast("Trial started");
        } catch (e) {
          toast(String(e), "err");
        } finally {
          b.disabled = false;
        }
      };
      banner.append(b);
    }
    wrap.append(banner);
  }

  const row = el("div", "stat-row");
  row.append(
    speedCard("Down", state.status?.speed_down ?? 0, "down"),
    speedCard("Up", state.status?.speed_up ?? 0, "up"),
  );
  const sparkCard = el("div", "card spark-card");
  sparkCard.append(el("div", "card-title", "Transfer rate"));
  const canvas = document.createElement("canvas");
  canvas.className = "sparkline";
  canvas.width = 620;
  canvas.height = 110;
  sparkCard.append(canvas);
  row.append(sparkCard);
  wrap.append(row);
  drawSparkline(canvas);

  if (state.status?.paused) {
    wrap.append(el("div", "banner info", "Syncing is paused for all folders."));
  }

  wrap.append(el("h2", "section-title", "Folders"));
  if (state.folders.length === 0) {
    const empty = el("div", "card empty-state");
    empty.append(el("div", "empty-title", "No synced folders yet"));
    empty.append(
      el(
        "p",
        "empty-sub",
        "Add a folder with a share key from another device, or create a new one to start syncing.",
      ),
    );
    const b = el("button", "btn primary", "Add your first folder");
    b.onclick = () => navigate({ name: "add" });
    empty.append(b);
    wrap.append(empty);
  } else {
    const grid = el("div", "folder-grid");
    for (const f of state.folders) grid.append(folderCard(f));
    wrap.append(grid);
  }
  root.append(wrap);
}
