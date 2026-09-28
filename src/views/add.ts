import { api } from "../bridge";
import { navigate } from "../store";
import { copyText, el, toast } from "../ui";

function fieldLabel(text: string): HTMLElement {
  return el("div", "field-label", text);
}

function renderExistingForm(body: HTMLElement) {
  const form = el("div", "form");

  form.append(fieldLabel("Local directory"));
  const dirRow = el("div", "field-row");
  const dirInput = el("input", "text-input") as HTMLInputElement;
  dirInput.placeholder = "Choose or type a directory…";
  const browse = el("button", "btn ghost", "Browse…") as HTMLButtonElement;
  browse.onclick = async () => {
    const d = await api.pickFolder();
    if (d) dirInput.value = d;
  };
  dirRow.append(dirInput, browse);
  form.append(dirRow);

  form.append(fieldLabel("Share key from the other device"));
  const keyInput = el("input", "text-input mono") as HTMLInputElement;
  keyInput.placeholder = "Paste the key you received (optional — empty generates a new one)";
  form.append(keyInput);

  const err = el("div", "form-error");
  const submit = el("button", "btn primary", "Add Folder") as HTMLButtonElement;
  submit.onclick = async () => {
    const dir = dirInput.value.trim();
    if (!dir) {
      err.textContent = "Pick a directory first.";
      return;
    }
    submit.disabled = true;
    try {
      await api.addFolder(dir, keyInput.value.trim() || undefined);
      toast("Folder added");
      navigate({ name: "overview" });
    } catch (e) {
      err.textContent = String(e);
      submit.disabled = false;
    }
  };
  form.append(err, submit);
  body.append(form);
}

function renderCreateForm(body: HTMLElement) {
  const form = el("div", "form");

  form.append(fieldLabel("New directory to sync"));
  const dirRow = el("div", "field-row");
  const dirInput = el("input", "text-input") as HTMLInputElement;
  dirInput.placeholder = "Choose or type a directory…";
  const browse = el("button", "btn ghost", "Browse…") as HTMLButtonElement;
  browse.onclick = async () => {
    const d = await api.pickFolder();
    if (d) dirInput.value = d;
  };
  dirRow.append(dirInput, browse);
  form.append(dirRow);

  form.append(fieldLabel("Keys (generated via the daemon, optional preview)"));
  const genRow = el("div", "field-row");
  const genBtn = el("button", "btn ghost", "Generate keys") as HTMLButtonElement;
  genRow.append(genBtn);
  form.append(genRow);

  const rwRow = el("div", "field-row");
  const rwInput = el("input", "text-input mono") as HTMLInputElement;
  rwInput.readOnly = true;
  rwInput.placeholder = "Read & write key";
  const rwCopy = el("button", "btn ghost", "Copy") as HTMLButtonElement;
  rwCopy.onclick = async () => {
    if (rwInput.value) toast((await copyText(rwInput.value)) ? "Key copied" : "Copy failed");
  };
  rwRow.append(rwInput, rwCopy);
  rwRow.style.display = "none";
  form.append(rwRow);

  const roRow = el("div", "field-row");
  const roInput = el("input", "text-input mono") as HTMLInputElement;
  roInput.readOnly = true;
  roInput.placeholder = "Read-only key";
  const roCopy = el("button", "btn ghost", "Copy") as HTMLButtonElement;
  roCopy.onclick = async () => {
    if (roInput.value) toast((await copyText(roInput.value)) ? "Key copied" : "Copy failed");
  };
  roRow.append(roInput, roCopy);
  roRow.style.display = "none";
  form.append(roRow);

  const err = el("div", "form-error");
  genBtn.onclick = async () => {
    genBtn.disabled = true;
    try {
      const s = await api.generateSecret();
      rwInput.value = s.secret;
      roInput.value = s.read_only ?? "";
      rwRow.style.display = "";
      roRow.style.display = s.read_only ? "" : "none";
    } catch (e) {
      err.textContent = String(e);
    } finally {
      genBtn.disabled = false;
    }
  };

  const submit = el("button", "btn primary", "Create & Add") as HTMLButtonElement;
  submit.onclick = async () => {
    const dir = dirInput.value.trim();
    if (!dir) {
      err.textContent = "Pick a directory first.";
      return;
    }
    submit.disabled = true;
    try {
      await api.addFolder(dir, rwInput.value.trim() || undefined);
      toast("Folder created");
      navigate({ name: "overview" });
    } catch (e) {
      err.textContent = String(e);
      submit.disabled = false;
    }
  };
  form.append(err, submit);
  body.append(form);
}

export function renderAdd(root: HTMLElement) {
  const wrap = el("div", "view narrow");
  wrap.append(el("h1", "view-title", "Add Folder"));

  const tabs = el("div", "tabs");
  const tabExisting = el("button", "tab active", "Add existing") as HTMLButtonElement;
  const tabCreate = el("button", "tab", "Create new") as HTMLButtonElement;
  tabs.append(tabExisting, tabCreate);
  wrap.append(tabs);

  const body = el("div", "tab-body");
  wrap.append(body);

  const showTab = (mode: "existing" | "create") => {
    tabExisting.classList.toggle("active", mode === "existing");
    tabCreate.classList.toggle("active", mode === "create");
    body.innerHTML = "";
    if (mode === "existing") renderExistingForm(body);
    else renderCreateForm(body);
  };
  tabExisting.onclick = () => showTab("existing");
  tabCreate.onclick = () => showTab("create");
  showTab("existing");

  root.append(wrap);
}
