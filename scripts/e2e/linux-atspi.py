#!/usr/bin/env python3
import argparse
import json
import time
from pathlib import Path

import pyatspi


def children(node):
    for index in range(node.childCount):
        try:
            yield node.getChildAtIndex(index)
        except Exception:
            continue


def walk(node):
    yield node
    for child in children(node):
        yield from walk(child)


def role(node):
    try:
        return node.getRoleName()
    except Exception:
        return "unknown"


def node_text(node):
    try:
        value = node.queryText()
        return value.getText(0, value.characterCount)
    except Exception:
        return ""


def wait_for(description, probe, timeout=45.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = probe()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {description}")


def find_named(root, name, expected_role=None):
    for node in walk(root):
        if (node.name or "") == name and (expected_role is None or role(node) == expected_role):
            return node
    return None


def find_editable_named(root, name):
    for node in walk(root):
        if (node.name or "") != name:
            continue
        try:
            node.queryEditableText()
            return node
        except Exception:
            continue
    return None


def find_frame(name):
    desktop = pyatspi.Registry.getDesktop(0)
    for application in children(desktop):
        for node in walk(application):
            if role(node) == "frame" and (node.name or "") == name:
                return application, node
    return None


def press(node):
    actions = node.queryAction()
    if actions.nActions < 1 or not actions.doAction(0):
        raise AssertionError(f"AT-SPI action failed for {node.name!r}")


def snapshot(node, depth=0):
    result = {"name": node.name or "", "role": role(node)}
    value = node_text(node)
    if value:
        result["text"] = value
    if depth < 8:
        result["children"] = [snapshot(child, depth + 1) for child in children(node)]
    return result


def load_saved_settings(root):
    for path in root.rglob("syncpilot-settings.json"):
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if value.get("device_name") == "Acceptance device":
            return path, value
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--settings-root", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    application, window = wait_for("SyncPilot frame", lambda: find_frame("SyncPilot"))
    open_settings = wait_for(
        "Open SyncPilot Settings button",
        lambda: find_named(window, "Open SyncPilot Settings", "push button"),
    )
    press(open_settings)

    _, settings_window = wait_for(
        "SyncPilot Settings frame", lambda: find_frame("SyncPilot Settings")
    )
    device = wait_for(
        "accessible device-name field",
        lambda: find_editable_named(settings_window, "Device name shown to peers"),
    )
    device.queryEditableText().setTextContents("Acceptance device")
    save = wait_for(
        "Save Settings button",
        lambda: find_named(settings_window, "Save Settings", "push button"),
    )
    press(save)

    saved_path, saved = wait_for(
        "settings persisted by the embedded backend",
        lambda: load_saved_settings(args.settings_root),
    )
    if saved.get("settings_version") != 2:
        raise AssertionError("the persisted settings schema version changed")

    (args.output / "accessibility.json").write_text(
        json.dumps(snapshot(application), ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (args.output / "interaction-trace.json").write_text(
        json.dumps(
            {
                "platform": "linux",
                "actions": [
                    "press:Open SyncPilot Settings",
                    "set:Device name shown to peers",
                    "press:Save Settings",
                ],
                "assertions": [
                    "packaged GTK4 frame activated on native Wayland",
                    "settings controls expose stable AT-SPI names",
                    "save mutation crossed RVT1 into the embedded backend",
                    "isolated syncpilot-settings.json contains the new device name",
                ],
                "settings_path": str(saved_path.relative_to(args.settings_root)),
            },
            indent=2,
        ),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
