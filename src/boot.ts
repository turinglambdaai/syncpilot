import { api } from "./bridge";
import { el, toast } from "./ui";

/**
 * Boot page: the only thing this app's own frontend does is hand the window
 * over to the official Resilio Web UI served through the auth-injecting
 * proxy. Everything visible after this page is the official interface.
 */

const statusEl = document.getElementById("boot-status")!;
const detailEl = document.getElementById("boot-detail")!;
const actionsEl = document.getElementById("boot-actions")!;

function reset() {
  detailEl.textContent = "";
  actionsEl.replaceChildren();
}

function setStatus(text: string, detail?: string) {
  statusEl.textContent = text;
  if (detail != null) detailEl.textContent = detail;
}

function button(label: string, cls = "btn primary"): HTMLButtonElement {
  return el("button", cls, label) as HTMLButtonElement;
}

async function handOff() {
  setStatus("Starting the Resilio Sync daemon…");
  try {
    const handoff = await api.guiUrl();
    setStatus(
      `Handing over to the official interface (rslsync ${handoff.version ?? "?"})…`,
    );
    window.location.replace(handoff.url);
    // The navigation happens asynchronously; keep the page quiet until it does.
    return;
  } catch (e) {
    const message = String(e);
    if (/binary not found/i.test(message)) {
      renderInstallCard();
    } else {
      renderRetryCard();
    }
  }
}

function renderRetryCard() {
  reset();
  setStatus("The daemon is not ready yet.");
  const retry = button("Retry");
  retry.onclick = () => {
    retry.disabled = true;
    void handOff();
  };
  actionsEl.append(retry);
  actionsEl.append(settingsButton());
  setTimeout(() => void handOff(), 3000);
}

function renderInstallCard() {
  reset();
  setStatus("Resilio Sync is not installed yet.");
  detailEl.textContent =
    "SyncPilot runs the official rslsync binary. " +
    "Download it now from Resilio's CDN (checksum verified) into ~/.local/bin, " +
    "or point SyncPilot at an existing binary in Settings.";
  const install = button("Download Resilio Sync (~25 MB)");
  const hint = el("div", "card-note", "");
  install.onclick = async () => {
    install.disabled = true;
    install.textContent = "Downloading…";
    try {
      const path = await api.installRslsync();
      toast(`Installed: ${path}`);
      await handOff();
    } catch (err) {
      install.disabled = false;
      install.textContent = "Download failed — retry";
      hint.textContent = `${err} — you can also install rslsync yourself and set its path in Settings.`;
    }
  };
  actionsEl.append(install, settingsButton(), hint);
}

function settingsButton(): HTMLButtonElement {
  const b = button("Open SyncPilot Settings", "btn ghost");
  b.onclick = () => void api.openSettings().catch(() => {});
  return b;
}

void handOff();
