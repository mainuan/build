#!/usr/bin/env python3
"""Boot a Mainuan ISO in QEMU and check the live session.

The ISO is booted through its own firmware path (UEFI with OVMF, or BIOS with
SeaBIOS) and its own GRUB menu. The menu is mirrored on the serial port; the
test edits the default entry there to add a serial console, waits for the
login prompt, logs in as the live user and runs read-only checks.

Only the Python standard library is used. Results are written to --out:
  report.json   machine readable results
  serial.log    complete serial console output
  live.png      screenshot of the graphical session (QMP screendump)
"""

import argparse
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

OVMF_CANDIDATES = [
    ("/usr/share/OVMF/OVMF_CODE_4M.fd", "/usr/share/OVMF/OVMF_VARS_4M.fd"),
    ("/usr/share/edk2/x64/OVMF_CODE.4m.fd", "/usr/share/edk2/x64/OVMF_VARS.4m.fd"),
    ("/usr/share/OVMF/OVMF_CODE.fd", "/usr/share/OVMF/OVMF_VARS.fd"),
]

# Shell checks run in the live session. Each prints one block between markers.
CHECKS = {
    "os_release": "cat /etc/os-release",
    "kernel": "uname -r",
    "cmdline": "cat /proc/cmdline",
    "system_state": "timeout 300 systemctl is-system-running --wait || true",
    "failed_units": "systemctl --failed --no-legend --plain || true",
    "graphical_target": "systemctl is-active graphical.target || true",
    "display_manager": "systemctl is-active display-manager.service || true",
    "sessions": "loginctl list-sessions --no-legend || true",
    "plasma_processes": "pgrep -a -x 'plasmashell|kwin_wayland|kwin_x11|sddm' || true",
    "session_type": "for s in $(loginctl list-sessions --no-legend | awk '{print $1}'); do "
                    "loginctl show-session \"$s\" -p Type -p Name -p Desktop; done || true",
    "mainuan_packages": "dpkg-query -W -f='${Package}\\t${Version}\\t${Status}\\n' "
                        "mainuan-welcome deb-manager-gui instalador-de-fontes system-upgrade "
                        "mainuan-gestao-drivers painel-de-controle mainuan-grub-editor "
                        "mainuan-flatpak-install-gui mainuan-install-appimage "
                        "mainuan-atualizador-recursos pkg-manager-gui calamares plasma-workspace "
                        "2>&1 || true",
    "default_apps": "cat /etc/xdg/mimeapps.list 2>/dev/null; "
                    "xdg-mime query default application/vnd.flatpak.ref 2>/dev/null || true",
    "network": "ip -brief address; resolvectl status 2>/dev/null | head -20 || true",
    "dns": "getent hosts archive.ubuntu.com || echo 'no DNS answer'",
    "apt_policy": "apt-cache policy 2>/dev/null | head -20",
    "journal_errors": "journalctl -b -p err --no-pager -o short-monotonic | tail -80",
    "kernel_warnings": "dmesg --level=err,warn 2>/dev/null | tail -40 || "
                       "sudo -n dmesg --level=err,warn | tail -40",
    "memory": "free -m",
    "cpu_flags": "grep -m1 -o -w -E 'avx2|avx|sse4_2' /proc/cpuinfo | sort -u | tr '\\n' ' '",
    "disk": "df -h / /cdrom 2>/dev/null",
}


def find_ovmf():
    for code, vars_ in OVMF_CANDIDATES:
        if os.path.exists(code) and os.path.exists(vars_):
            return code, vars_
    sys.exit("OVMF firmware not found")


class Qmp:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX)
        for _ in range(100):
            try:
                self.sock.connect(path)
                break
            except OSError:
                time.sleep(0.1)
        self.file = self.sock.makefile("rw")
        json.loads(self.file.readline())  # greeting
        self.command("qmp_capabilities")

    def command(self, name, **arguments):
        self.file.write(json.dumps({"execute": name, "arguments": arguments}) + "\n")
        self.file.flush()
        while True:
            reply = json.loads(self.file.readline())
            if "return" in reply or "error" in reply:
                return reply


class Serial:
    def __init__(self, path, log_path):
        self.sock = socket.socket(socket.AF_UNIX)
        for _ in range(100):
            try:
                self.sock.connect(path)
                break
            except OSError:
                time.sleep(0.1)
        self.sock.settimeout(0.5)
        self.buffer = ""
        self.log = open(log_path, "w", encoding="utf-8", errors="replace")  # noqa: SIM115 - closed at exit

    def read(self):
        try:
            data = self.sock.recv(65536)
        except TimeoutError:
            return ""
        if not data:
            raise EOFError("serial closed (QEMU exited)")
        text = data.decode("utf-8", "replace")
        self.log.write(text)
        self.log.flush()
        self.buffer += text
        return text

    def wait_for(self, pattern, timeout):
        regex = re.compile(pattern)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            match = regex.search(self.buffer)
            if match:
                self.buffer = self.buffer[match.end():]
                return match
            self.read()
        raise TimeoutError(f"timeout waiting for {pattern!r}")

    def send(self, text):
        self.sock.sendall(text.encode())


def run_check(serial, name, command, timeout=360):
    begin, end = f"@@BEGIN-{name}@@", f"@@END-{name}@@"
    # The markers are built at run time so the echoed command never matches.
    serial.send(f"B=@@BEGIN-; E=@@END-; echo \"$B{name}@@\"; {{ {command} ; }} 2>&1; "
                f"echo \"$E{name}@@\"\n")
    serial.wait_for(re.escape(begin) + r"\r?\n", timeout)
    match = serial.wait_for(r"(?s)(.*?)" + re.escape(end), timeout)
    return match.group(1).replace("\r", "").strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("iso")
    parser.add_argument("--firmware", choices=["uefi", "bios"], default="uefi")
    parser.add_argument("--memory", default="6144")
    parser.add_argument("--cpus", default="4")
    parser.add_argument("--user", default="mainuan")
    parser.add_argument("--out", default="live-smoke")
    parser.add_argument("--boot-timeout", type=int, default=900)
    parser.add_argument("--no-kvm", action="store_true")
    parser.add_argument("--cpu-model", default="",
                        help="QEMU CPU model, e.g. Nehalem (no AVX) to check the x86-64 baseline")
    args = parser.parse_args()

    os.makedirs(args.out, exist_ok=True)
    work = tempfile.mkdtemp(prefix="mainuan-smoke-")
    qmp_path, serial_path = os.path.join(work, "qmp"), os.path.join(work, "serial")

    command = [
        "qemu-system-x86_64", "-machine", "q35", "-m", args.memory, "-smp", args.cpus,
        "-display", "none", "-vga", "virtio",
        "-device", "qemu-xhci", "-device", "usb-tablet",
        "-netdev", "user,id=net0", "-device", "virtio-net-pci,netdev=net0",
        "-drive", f"file={os.path.abspath(args.iso)},media=cdrom,readonly=on,if=none,id=cd0",
        "-device", "ide-cd,drive=cd0,bootindex=0",
        "-chardev", f"socket,id=ser0,path={serial_path},server=on,wait=off",
        "-serial", "chardev:ser0",
        "-qmp", f"unix:{qmp_path},server=on,wait=off",
    ]
    if not args.no_kvm and os.access("/dev/kvm", os.R_OK | os.W_OK):
        command += ["-enable-kvm", "-cpu", args.cpu_model or "host"]
    else:
        command += ["-cpu", args.cpu_model or "max"]
    if args.firmware == "uefi":
        code, vars_template = find_ovmf()
        vars_copy = os.path.join(work, "OVMF_VARS.fd")
        shutil.copyfile(vars_template, vars_copy)
        command += ["-drive", f"if=pflash,format=raw,readonly=on,file={code}",
                    "-drive", f"if=pflash,format=raw,file={vars_copy}"]

    report = {"iso": os.path.basename(args.iso), "firmware": args.firmware,
              "cpu_model": args.cpu_model or "host",
              "kvm": "-enable-kvm" in command, "steps": {}, "checks": {}}
    started = time.monotonic()
    qemu = subprocess.Popen(command)
    qmp = None
    try:
        qmp = Qmp(qmp_path)
        serial = Serial(serial_path, os.path.join(args.out, "serial.log"))

        # 1. GRUB menu on the serial port, default entry edited in place.
        serial.wait_for(r"Mainuan", 120)
        report["steps"]["grub_menu_seconds"] = round(time.monotonic() - started, 1)
        time.sleep(1)
        serial.send("e")
        time.sleep(1)
        serial.send("\x05")  # Ctrl-E: end of the first line (linux ...)
        serial.send(" console=tty0 console=ttyS0,115200")
        time.sleep(0.5)
        serial.send("\x18")  # Ctrl-X: boot
        serial.wait_for(r"Linux version", 120)
        report["steps"]["kernel_seconds"] = round(time.monotonic() - started, 1)

        # 2. Login on the serial console as the live user (no password).
        serial.wait_for(r"login:\s*$", args.boot_timeout)
        report["steps"]["login_prompt_seconds"] = round(time.monotonic() - started, 1)
        serial.send(args.user + "\n")
        match = serial.wait_for(r"(Password:|\$ $)", 60)
        if match.group(1).startswith("Password"):
            serial.send("\n")
            serial.wait_for(r"\$ $", 60)
        serial.send("export TERM=dumb PAGER=cat SYSTEMD_PAGER=cat LC_ALL=C.UTF-8; stty -echo cols 250\n")
        time.sleep(1)

        for name, check in CHECKS.items():
            report["checks"][name] = run_check(serial, name, check)

        # 3. Screenshot of the graphical session.
        reply = qmp.command("screendump", filename=os.path.abspath(os.path.join(args.out, "live.png")),
                            format="png")
        report["steps"]["screendump"] = "ok" if "return" in reply else reply.get("error")
        report["steps"]["total_seconds"] = round(time.monotonic() - started, 1)

        serial.send("sudo -n poweroff\n")
        try:
            qemu.wait(timeout=180)
            report["steps"]["poweroff"] = "ok"
        except subprocess.TimeoutExpired:
            report["steps"]["poweroff"] = "timeout"
    except (TimeoutError, EOFError) as error:
        report["error"] = str(error)
        if qmp is not None and qemu.poll() is None:
            qmp.command("screendump", filename=os.path.abspath(os.path.join(args.out, "failure.png")),
                        format="png")
    finally:
        if qemu.poll() is None:
            qemu.kill()
            qemu.wait()
        shutil.rmtree(work, ignore_errors=True)

    checks = report["checks"]
    verdict = {
        "booted": "login_prompt_seconds" in report["steps"],
        "system_running": checks.get("system_state", "").splitlines()[-1:] in (["running"], ["degraded"]),
        "no_failed_units": checks.get("failed_units", "x") == "",
        "graphical": checks.get("graphical_target", "").strip() == "active",
        "plasma": "plasmashell" in checks.get("plasma_processes", ""),
        "wayland": "Type=wayland" in checks.get("session_type", ""),
        "mainuan_os_release": 'NAME="Mainuan"' in checks.get("os_release", ""),
        "poweroff": report["steps"].get("poweroff") == "ok",
    }
    report["verdict"] = verdict
    with open(os.path.join(args.out, "report.json"), "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, ensure_ascii=False)
    for key, value in verdict.items():
        print(f"{'PASS' if value else 'FAIL'}  {key}")
    required = ("booted", "system_running", "graphical", "plasma", "mainuan_os_release")
    return 0 if all(verdict[key] for key in required) else 1


if __name__ == "__main__":
    sys.exit(main())
