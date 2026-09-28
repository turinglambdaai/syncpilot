import { api } from "../bridge";
import { state, navigate } from "../store";
import { basename, copyText, el, fmtSpeed, timeAgo, toast } from "../ui";
import { folderStateClass, peerStateClass } from "./overview";

function actionBtn(
  label: string,
  onClick: () => Promise<void>,
  kind = "ghost",
): HTMLButtonElement {
  const b = el("button", `btn ${kind}`, label) as HTMLButtonElement;
  b.onclick = async () => {
    b.disabled = true;
    try {
      await onClick();
    } catch (e) {
      toast(String(e), "err");
    } finally {
      b.disabled = false;
    }
  };
  return b;
}

export function renderFolderView(root: HTMLElement, id: string) {
  const f = state.folders.find((x) => x.id === id);
  const wrap = el("div", "view");
  if (!f) {
    const p = el("div", "card empty-state");
    p.append(el("div", "empty-title", "Folder not found"));
    p.append(el("p", "empty-sub", "It may have just been removed."));
    root.append(p);
    return;
  }

  const head = el("div", "folder-head");
  head.append(actionBtn("← Back", async () => navigate({ name: "overview" })));
  const title = el("div", "folder-title");
  const nameRow = el("div", "folder-title-row");
  nameRow.append(el("h1", "view-title", basename(f.path) || f.path));
  nameRow.append(el("span", `status-dot ${folderStateClass(f)}`));
  title.append(nameRow);
  title.append(el("div", "folder-path", f.path));
  head.append(title);
  head.append(el("span", "spacer"));
  if (f.ispaused) head.append(el("span", "badge", "Paused"));
  wrap.append(head);

  const actions = el("div", "folder-actions");
  actions.append(
    actionBtn("Open Folder", async () => {
      await api.openPath(f.path);
    }),
    // No pause/resume: rslsync 3.x has no folder-pause action.
    actionBtn("Copy Share Key", async () => {
      const ok = await copyText(f.secret);
      toast(ok ? "Share key copied" : "Copy failed", ok ? "ok" : "err");
    }),
  );
  // Two-step confirm: window.confirm is unavailable inside the WebView.
  let armed = false;
  const removeBtn = el("button", "btn ghost danger", "Remove") as HTMLButtonElement;
  removeBtn.onclick = async () => {
    if (!armed) {
      armed = true;
      removeBtn.textContent = "Really remove?";
      removeBtn.classList.add("armed");
      setTimeout(() => {
        armed = false;
        removeBtn.textContent = "Remove";
        removeBtn.classList.remove("armed");
      }, 3000);
      return;
    }
    removeBtn.disabled = true;
    try {
      await api.removeFolder(f.id);
      toast("Folder removed from syncing");
      navigate({ name: "overview" });
    } catch (e) {
      toast(String(e), "err");
      removeBtn.disabled = false;
    }
  };
  actions.append(removeBtn);
  wrap.append(actions);

  const keyCard = el("div", "card key-card");
  keyCard.append(el("div", "card-title", "Share key (read & write)"));
  keyCard.append(el("code", "key-value", f.secret || "—"));
  keyCard.append(
    el(
      "div",
      "card-note",
      `Added ${timeAgo(f.date_added)} · anyone with this key can sync this folder.`,
    ),
  );
  wrap.append(keyCard);

  wrap.append(el("h2", "section-title", `Peers (${f.peers.length})`));
  if (f.peers.length === 0) {
    const empty = el("div", "card empty-state");
    empty.append(
      el("p", "empty-sub", "No peers yet. Share the key above with another device to connect."),
    );
    wrap.append(empty);
  } else {
    const list = el("div", "card peer-list");
    for (const p of f.peers) {
      const row = el("div", "peer-row");
      row.append(el("span", `status-dot ${peerStateClass(p)}`));
      row.append(el("span", "peer-name", p.name || p.id.slice(0, 8) || "unknown"));
      row.append(el("span", "peer-state", p.syncstate ?? p.status ?? ""));

      if ((p.syncstate ?? "") === "syncing" && p.percent_downloaded != null) {
        const bar = el("div", "progress");
        const fill = el("div", "progress-fill");
        fill.style.width = `${Math.min(100, Math.max(0, Math.round(p.percent_downloaded)))}%`;
        bar.append(fill);
        row.append(bar);
      }

      row.append(el("span", "spacer"));
      if ((p.syncstate ?? "") === "syncing") {
        row.append(
          el(
            "span",
            "peer-speed",
            `↓ ${fmtSpeed(p.download ?? 0)} · ↑ ${fmtSpeed(p.upload ?? 0)}`,
          ),
        );
      }
      if (p.connection) row.append(el("span", "badge subtle", p.connection));
      list.append(row);
    }
    wrap.append(list);
  }

  root.append(wrap);
}
