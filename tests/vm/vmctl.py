#!/usr/bin/env python3
"""Drive a libvirt test VM for graphical checks (Calamares, apps).

  vmctl.py <domain> shot <file.png>            screenshot (virsh screenshot)
  vmctl.py <domain> click <x> <y> [W H]        left click at screen pixel x,y
  vmctl.py <domain> dclick <x> <y> [W H]       double click
  vmctl.py <domain> type <text>                type text (US keymap keys)
  vmctl.py <domain> typebr <text>              type text for the guest's ABNT2 layout
  vmctl.py <domain> key <combo> [combo...]     e.g. ret, tab, ctrl-alt-t, meta_l
  vmctl.py <domain> scroll <x> <y> <n> [W H]   mouse wheel at x,y: n notches down (negative: up)

Clicks need the absolute pointer of a usb-tablet (virt-install adds one).
W H is the current guest resolution (default 1280 800).
Only domains named mainuan-test* are accepted.
"""
import json
import subprocess
import sys
import time

CONNECT = "qemu:///system"
ABS_MAX = 0x7FFF

SHIFTED = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
    "(": "9", ")": "0", "_": "minus", "+": "equal", "{": "bracket_left", "}": "bracket_right",
    ":": "semicolon", '"': "apostrophe", "<": "comma", ">": "dot", "?": "slash", "|": "backslash",
    "~": "grave_accent",
}
# Brazilian ABNT2 layout (the Mainuan default): keys that differ from US.
ABNT2 = {
    "/": ["ro"], "?": ["shift", "ro"], "\\": ["less"], "|": ["shift", "less"],
    ";": ["slash"], ":": ["shift", "slash"], "'": ["grave_accent"], '"': ["shift", "grave_accent"],
    "[": ["bracket_right"], "]": ["backslash"], "{": ["shift", "bracket_right"], "}": ["shift", "backslash"],
    "~": ["apostrophe"], "^": ["shift", "apostrophe"], "`": ["shift", "bracket_left"],
}

PLAIN = {
    " ": "spc", "-": "minus", "=": "equal", "[": "bracket_left", "]": "bracket_right",
    ";": "semicolon", "'": "apostrophe", ",": "comma", ".": "dot", "/": "slash",
    "\\": "backslash", "`": "grave_accent", "\n": "ret",
}


def qmp(domain, command, arguments=None):
    payload = {"execute": command}
    if arguments is not None:
        payload["arguments"] = arguments
    result = subprocess.run(["virsh", "-c", CONNECT, "qemu-monitor-command", domain, json.dumps(payload)],
                            capture_output=True, text=True, check=True)
    return json.loads(result.stdout)


def key_event(key, down):
    return {"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": key}}}


def send_keys(domain, keys):
    events = [key_event(k, True) for k in keys] + [key_event(k, False) for k in reversed(keys)]
    qmp(domain, "input-send-event", {"events": events})
    time.sleep(0.05)


def type_text(domain, text, layout="us"):
    for char in text:
        if layout == "br" and char in ABNT2:
            send_keys(domain, ABNT2[char])
        elif char.isalpha() and char.isupper():
            send_keys(domain, ["shift", char.lower()])
        elif char.isalnum():
            send_keys(domain, [char])
        elif char in SHIFTED:
            send_keys(domain, ["shift", SHIFTED[char]])
        elif char in PLAIN:
            send_keys(domain, [PLAIN[char]])
        else:
            raise SystemExit(f"cannot type {char!r}")


def click(domain, x, y, width, height, count=1):
    ax, ay = int(x * ABS_MAX / width), int(y * ABS_MAX / height)
    move = [{"type": "abs", "data": {"axis": "x", "value": ax}},
            {"type": "abs", "data": {"axis": "y", "value": ay}}]
    qmp(domain, "input-send-event", {"events": move})
    time.sleep(0.1)
    for _ in range(count):
        for down in (True, False):
            qmp(domain, "input-send-event",
                {"events": [{"type": "btn", "data": {"down": down, "button": "left"}}]})
            time.sleep(0.05)
        time.sleep(0.1)


def scroll(domain, x, y, notches, width, height):
    ax, ay = int(x * ABS_MAX / width), int(y * ABS_MAX / height)
    qmp(domain, "input-send-event", {"events": [{"type": "abs", "data": {"axis": "x", "value": ax}},
                                                {"type": "abs", "data": {"axis": "y", "value": ay}}]})
    button = "wheel-down" if notches > 0 else "wheel-up"
    for _ in range(abs(notches)):
        for down in (True, False):
            qmp(domain, "input-send-event", {"events": [{"type": "btn", "data": {"down": down, "button": button}}]})
        time.sleep(0.05)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    domain, action, args = sys.argv[1], sys.argv[2], sys.argv[3:]
    if not domain.startswith("mainuan-test"):
        sys.exit("only mainuan-test* domains")
    if action == "shot":
        subprocess.run(["virsh", "-c", CONNECT, "screenshot", domain, args[0]],
                       check=True, capture_output=True)
    elif action in ("click", "dclick"):
        width, height = (int(args[2]), int(args[3])) if len(args) >= 4 else (1280, 800)
        click(domain, int(args[0]), int(args[1]), width, height, 2 if action == "dclick" else 1)
    elif action == "scroll":
        width, height = (int(args[3]), int(args[4])) if len(args) >= 5 else (1280, 800)
        scroll(domain, int(args[0]), int(args[1]), int(args[2]), width, height)
    elif action == "type":
        type_text(domain, " ".join(args))
    elif action == "typebr":
        type_text(domain, " ".join(args), layout="br")
    elif action == "key":
        for combo in args:
            send_keys(domain, combo.split("-"))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
