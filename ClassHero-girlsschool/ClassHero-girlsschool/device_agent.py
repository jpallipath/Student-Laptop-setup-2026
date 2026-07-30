"""
ClassHero Device Agent  v1.0.0
================================
Silent background agent installed on student devices.
Reports IP addresses, MAC address and hardware details to the
ClassHero backend so administrators can see every device in
SchoolManager â†’ Settings â†’ Devices.

Behaviour
â”€â”€â”€â”€â”€â”€â”€â”€â”€
â€¢ Runs completely silently (no window, no tray icon, no popups)
â€¢ All output goes to %APPDATA%\\ClassHero\\agent.log
â€¢ On startup  â†’ registers the device  (POST /api/devices/register)
â€¢ Every 30 s  â†’ heartbeat             (POST /api/devices/heartbeat)
â€¢ Exponential back-off retry if the backend is temporarily unreachable
"""

import configparser
import os
import platform
import socket
import sys
import time
import uuid
import threading
import logging
import subprocess
import json
from pathlib import Path

# â”€â”€ Silence console the moment the module loads when frozen â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
_IS_FROZEN = getattr(sys, "frozen", False)

# â”€â”€ Log directory & file â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# Use ProgramData so the agent (running as SYSTEM) can write logs,
# and admins can read them at C:\ProgramData\ClassHero\agent.log
LOG_DIR  = Path(os.getenv("PROGRAMDATA", "C:\\ProgramData")) / "ClassHero"
LOG_DIR.mkdir(parents=True, exist_ok=True)
LOG_PATH = LOG_DIR / "agent.log"

# Rotate if log > 2 MB to avoid filling the disk
if LOG_PATH.exists() and LOG_PATH.stat().st_size > 2 * 1024 * 1024:
    LOG_PATH.rename(LOG_PATH.with_suffix(".log.bak"))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.FileHandler(LOG_PATH, encoding="utf-8")],
)
log = logging.getLogger("classhero-agent")


def _flush_log() -> None:
    try:
        _log_handle.flush()
        os.fsync(_log_handle.fileno())
    except Exception:
        pass

# Redirect stdout/stderr â†’ log file so nothing leaks to any console or dialog
# Always redirect stderr (pythonw.exe has no console so errors disappear otherwise)
_log_handle = open(LOG_PATH, "a", encoding="utf-8")
if _IS_FROZEN:
    sys.stdout = _log_handle
sys.stderr = _log_handle

# â”€â”€ Late imports (after stdout/stderr redirected) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
import requests   # noqa: E402
import psutil     # noqa: E402

# â”€â”€ Software identity â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
AGENT_NAME    = "Details"
AGENT_VERSION = "2.0.1"
AGENT_VENDOR  = "ClassHero"

_command_lock = threading.Lock()
_active_command_id = ""
_pending_command_result = None
_restart_after_report = False

# â”€â”€ Config path â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# When frozen by PyInstaller, _MEIPASS is the temp extraction folder.
if _IS_FROZEN:
    _BASE = Path(sys._MEIPASS)           # type: ignore[attr-defined]
else:
    _BASE = Path(__file__).parent

_EXE_DIR = Path(sys.executable).parent if _IS_FROZEN else _BASE
# Admin can place/edit agent_config.ini next to the .exe at any time.
CONFIG_PATH = _EXE_DIR / "agent_config.ini"


def load_config() -> configparser.ConfigParser:
    cfg = configparser.ConfigParser()
    if CONFIG_PATH.exists():
        # utf-8-sig strips the BOM that PowerShell 5 adds when writing UTF-8 files
        cfg.read(CONFIG_PATH, encoding="utf-8-sig")
        log.info("Config loaded: %s", CONFIG_PATH)
    else:
        cfg["agent"] = {
            "school_id":       "YOUR_SCHOOL_ID",
            "student_name":    "",
            "form_name":       "",
            "backend_urls":    "https://your-backend.up.railway.app",
            "heartbeat_every": "30",
        }
        with open(CONFIG_PATH, "w", encoding="utf-8") as f:
            cfg.write(f)
        log.warning("No config found â€” created starter config at %s", CONFIG_PATH)
    return cfg


# â”€â”€ System information â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

def get_mac_address() -> str:
    raw = uuid.getnode()
    return ":".join(f"{(raw >> (8 * i)) & 0xFF:02x}" for i in reversed(range(6)))


def get_local_ip() -> str:
    """Return the best LAN IPv4 address.

    Preference order (highest first):
      1. 10.x.x.x   — corporate / school LAN (most likely the right one)
      2. 172.16-31.x — private range
      3. 192.168.x.x — home/small-office LAN
      4. Default-route IP via UDP trick (fallback — may be VPN tunnel)
      5. 127.0.0.1   — last resort

    100.64-127.x.x (Carrier-grade NAT / VPN tunnel range) is intentionally
    ranked lower than real private ranges so VPN adapters don't win.
    """
    def _rank(ip: str) -> int:
        if ip.startswith("10."):
            return 0
        if ip.startswith("172.") and 16 <= int(ip.split(".")[1]) <= 31:
            return 1
        if ip.startswith("192.168."):
            return 2
        if ip.startswith("100."):
            return 4   # CGNAT / VPN tunnel — deprioritise
        return 3

    candidates = []
    try:
        for _iface, addrs in psutil.net_if_addrs().items():
            for addr in addrs:
                if addr.family == socket.AF_INET and not addr.address.startswith("127."):
                    candidates.append(addr.address)
    except Exception:
        pass

    if candidates:
        candidates.sort(key=_rank)
        return candidates[0]

    # Fallback: UDP trick (returns whichever interface has the default route)
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
    except Exception:
        return "127.0.0.1"


def get_public_ip() -> str:
    for url in [
        "https://api.ipify.org?format=json",
        "https://api4.my-ip.io/ip.json",
    ]:
        try:
            r = requests.get(url, timeout=5)
            if r.ok:
                data = r.json()
                return data.get("ip") or data.get("IP") or ""
        except Exception:
            continue
    return ""


def is_vpn_detected(public_ip: str) -> bool:
    """Detect if a VPN is currently ACTIVE (not just installed).

    Only flags True when VPN is actually running:
      1. A known VPN process is running (openvpn, wireguard, nordvpn, etc.)
      2. A TUN/WireGuard interface has an IP assigned (tunnel is up)

    Deliberately ignores TAP adapter presence - that causes false positives
    on machines where OpenVPN is installed but not active.
    """
    VPN_PROCESS_NAMES = {"openvpn", "openvpn-gui", "wireguard", "wg", "nordvpn",
                         "expressvpn", "surfshark", "cyberghost", "windscribe",
                         "protonvpn", "tunnelblick", "vpnui", "vpnclient"}
    try:
        for proc in psutil.process_iter(["name"]):
            name = (proc.info.get("name") or "").lower().replace(".exe", "")
            if name in VPN_PROCESS_NAMES:
                log.info("VPN detected: process '%s' is running", proc.info["name"])
                return True
    except Exception as e:
        log.debug("VPN process check error: %s", e)

    try:
        import socket as _socket
        for iface, addrs in psutil.net_if_addrs().items():
            iface_lower = iface.lower()
            if any(k in iface_lower for k in ("tun", "wg", "nordlynx", "proton")):
                for addr in addrs:
                    if addr.family == _socket.AF_INET and not addr.address.startswith("127."):
                        log.info("VPN detected: interface '%s' has IP %s", iface, addr.address)
                        return True
    except Exception as e:
        log.debug("VPN interface check error: %s", e)

    return False


def get_wifi_name() -> str:
    """Return the currently connected WiFi SSID (Windows only). Empty string on failure."""
    if platform.system() != "Windows":
        return ""
    try:
        import subprocess
        out = subprocess.check_output(
            ["netsh", "wlan", "show", "interfaces"],
            text=True,
            creationflags=0x08000000,   # CREATE_NO_WINDOW
            stderr=subprocess.DEVNULL,
        )
        for line in out.splitlines():
            stripped = line.strip()
            # Match "SSID" but NOT "BSSID"
            if stripped.startswith("SSID") and ":" in stripped and "BSSID" not in stripped:
                parts = stripped.split(":", 1)
                if len(parts) == 2:
                    return parts[1].strip()
    except Exception as e:
        log.debug("WiFi name detection failed: %s", e)
    return ""


def get_username() -> str:
    """Return the current OS login username."""
    try:
        return os.getenv("USERNAME") or os.getenv("USER") or os.getlogin()
    except Exception:
        return ""


def get_device_type() -> str:
    if platform.system() == "Windows":
        try:
            import subprocess
            out = subprocess.check_output(
                ["wmic", "computersystem", "get", "PCSystemType"],
                text=True,
                creationflags=0x08000000,   # CREATE_NO_WINDOW â€” no flash
            )
            lines = [l.strip() for l in out.splitlines() if l.strip().isdigit()]
            if lines:
                return {1: "Desktop", 2: "Laptop", 8: "Tablet"}.get(int(lines[0]), "Desktop")
        except Exception:
            pass
    return "Computer"


def collect_device_info(cfg: configparser.ConfigParser) -> dict:
    uname = platform.uname()
    try:
        ram_gb = str(round(psutil.virtual_memory().total / (1024 ** 3), 1))
    except Exception:
        ram_gb = ""

    return {
        "school_id":         cfg.get("agent", "school_id", fallback="unknown"),
        "device_name":       socket.gethostname(),
        "device_type":       get_device_type(),
        "device_os":         uname.system,
        "device_os_version": f"{uname.release} {uname.version}".strip(),
        "cpu_info":          platform.processor() or uname.processor,
        "ram_gb":            ram_gb,
        "mac_address":       get_mac_address(),
        "device_ip":         get_local_ip(),
        "public_ip":         get_public_ip(),
        "is_vpn":            False,   # filled in main() after public_ip is known
        "wifi_name":         get_wifi_name(),
        "username":          get_username(),        "student_name":      cfg.get("agent", "student_name", fallback=""),        "form_name":         cfg.get("agent", "form_name", fallback=""),
        "agent_version":     AGENT_VERSION,
    }


# â”€â”€ Backend communication â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

def _configured_backends(cfg: configparser.ConfigParser) -> list[str]:
    urls: list[str] = []

    multi_raw = cfg.get("agent", "backend_urls", fallback="")
    if multi_raw:
        normalized = multi_raw.replace("\n", ",")
        for item in normalized.split(","):
            url = item.strip().rstrip("/")
            if url and url not in urls:
                urls.append(url)

    legacy_url = cfg.get("agent", "backend_url", fallback="").strip().rstrip("/")
    if legacy_url and legacy_url not in urls:
        urls.append(legacy_url)

    return [url for url in urls if url and "your-backend" not in url]


def _urls(cfg: configparser.ConfigParser, path: str) -> list[str]:
    return [base + path for base in _configured_backends(cfg)]


def register(cfg: configparser.ConfigParser, info: dict) -> bool:
    success = False
    for endpoint in _urls(cfg, "/api/devices/register"):
        try:
            r = requests.post(endpoint, json=info, timeout=15)
            if r.ok and r.json().get("success"):
                log.info("%s registered via %s (id=%s)", AGENT_NAME, endpoint, r.json().get("device_id"))
                success = True
            else:
                log.warning("Register response from %s: %s", endpoint, r.text[:200])
        except Exception as e:
            log.error("Register error via %s: %s", endpoint, e)
    return success


def heartbeat(cfg: configparser.ConfigParser, mac: str) -> None:
    pub_ip  = get_public_ip()
    payload = {
        "mac_address": mac,
        "device_ip":   get_local_ip(),
        "public_ip":   pub_ip,
        "is_vpn":      is_vpn_detected(pub_ip),
        "wifi_name":    get_wifi_name(),
        "username":     get_username(),
        "student_name": cfg.get("agent", "student_name", fallback=""),
        "form_name":    cfg.get("agent", "form_name", fallback=""),
    }

    global _pending_command_result
    sent_command_result = False
    had_command_result = False
    with _command_lock:
        if _pending_command_result:
            payload["command_result"] = _pending_command_result
            _pending_command_result = None
            sent_command_result = True
            had_command_result = True

    successful_heartbeats = 0
    first_command = None

    for endpoint in _urls(cfg, "/api/devices/heartbeat"):
        try:
            r = requests.post(endpoint, json=payload, timeout=10)
            if not r.ok:
                log.warning("Heartbeat response from %s: %s", endpoint, r.text[:200])
                continue

            successful_heartbeats += 1
            data = r.json() if r.headers.get("Content-Type", "").startswith("application/json") else {}
            command = data.get("command") if isinstance(data, dict) else None
            if first_command is None and isinstance(command, dict):
                first_command = command
        except Exception as e:
            log.error("Heartbeat error via %s: %s", endpoint, e)

    if successful_heartbeats == 0 and had_command_result:
        with _command_lock:
            if _pending_command_result is None:
                _pending_command_result = payload.get("command_result")

    if successful_heartbeats == 0:
        return

    if isinstance(first_command, dict):
        _start_command_if_needed(first_command)

    global _restart_after_report
    if sent_command_result and _restart_after_report:
        log.info("Applying upgraded agent process (self re-exec)")
        _restart_after_report = False
        os.execv(sys.executable, [sys.executable] + sys.argv)


def _queue_command_result(command_id: str, status: str, message: str) -> None:
    global _pending_command_result
    with _command_lock:
        _pending_command_result = {
            "command_id": command_id,
            "status": status,
            "message": message[:400],
        }


def _execute_install_command(command: dict) -> None:
    command_id = (command.get("command_id") or "").strip()
    payload = command.get("payload") or {}
    package_id = (payload.get("package_id") or "").strip()
    mode = (payload.get("mode") or "install").strip().lower()
    source = (payload.get("source") or "winget").strip().lower()

    if not command_id:
        return

    if source == "web_shortcut":
        shortcut_url = (payload.get("shortcut_url") or payload.get("url") or "").strip()
        shortcut_name = (payload.get("shortcut_name") or "Web Shortcut").strip()
        if not shortcut_url:
            _queue_command_result(command_id, "failed", "Missing shortcut_url")
            return
        try:
            desktop_public = Path(os.getenv("PUBLIC", r"C:\Users\Public")) / "Desktop"
            desktop_user = Path(os.getenv("USERPROFILE", str(Path.home()))) / "Desktop"
            target = desktop_public / f"{shortcut_name}.url"
            content = "[InternetShortcut]\nURL={0}\n".format(shortcut_url)
            try:
                target.write_text(content, encoding="utf-8")
            except Exception:
                target = desktop_user / f"{shortcut_name}.url"
                target.write_text(content, encoding="utf-8")
            _queue_command_result(command_id, "success", f"Shortcut created: {shortcut_name}")
        except Exception as e:
            _queue_command_result(command_id, "failed", str(e))
        return

    if source == "url":
        install_url = (payload.get("url") or "").strip()
        if not install_url:
            _queue_command_result(command_id, "failed", "Missing url")
            return
        try:
            output_file = (payload.get("output_file") or "installer.bin").strip()
            silent_args = (payload.get("silent_args") or "/quiet /norestart").strip()
            download_path = Path(os.getenv("TEMP", str(Path.cwd()))) / output_file
            resp = requests.get(install_url, timeout=60)
            if not resp.ok:
                _queue_command_result(command_id, "failed", f"Download failed: HTTP {resp.status_code}")
                return
            download_path.write_bytes(resp.content)
            result = subprocess.run(
                [str(download_path), *silent_args.split()],
                capture_output=True,
                text=True,
                creationflags=0x08000000,
                timeout=1800,
            )
            output = ((result.stdout or "") + "\n" + (result.stderr or "")).strip()
            if result.returncode == 0:
                _queue_command_result(command_id, "success", "URL installer completed")
            else:
                msg = output[-350:] if output else f"installer exit code {result.returncode}"
                _queue_command_result(command_id, "failed", msg)
        except Exception as e:
            _queue_command_result(command_id, "failed", str(e))
        return

    if source != "winget":
        _queue_command_result(command_id, "failed", f"Unsupported source: {source}")
        return

    if mode not in ("install", "upgrade"):
        mode = "install"

    if mode == "upgrade" and not package_id:
        args = [
            "winget",
            "upgrade",
            "--all",
            "--silent",
            "--accept-package-agreements",
            "--accept-source-agreements",
        ]
        log_label = "upgrade all"
        success_message = "upgrade ok: all"
    else:
        if not package_id:
            _queue_command_result(command_id, "failed", "Missing package_id")
            return
        args = [
            "winget",
            mode,
            "--id", package_id,
            "--silent",
            "--accept-package-agreements",
            "--accept-source-agreements",
        ]
        log_label = f"{mode} {package_id}"
        success_message = f"{mode} ok: {package_id}"

    try:
        log.info("Executing command %s: %s", command_id, log_label)
        result = subprocess.run(
            args,
            capture_output=True,
            text=True,
            creationflags=0x08000000,
            timeout=1800,
        )
        output = ((result.stdout or "") + "\n" + (result.stderr or "")).strip()
        if result.returncode == 0:
            _queue_command_result(command_id, "success", success_message)
            log.info("Command %s succeeded", command_id)
        else:
            msg = output[-350:] if output else f"winget exit code {result.returncode}"
            _queue_command_result(command_id, "failed", msg)
            log.warning("Command %s failed: %s", command_id, msg)
    except Exception as e:
        _queue_command_result(command_id, "failed", str(e))
        log.error("Command %s error: %s", command_id, e)


def _execute_upgrade_agent_command(command: dict) -> None:
    command_id = (command.get("command_id") or "").strip()
    payload = command.get("payload") or {}
    download_url = (payload.get("download_url") or "").strip()
    download_urls = payload.get("download_urls") or []
    target_version = (payload.get("target_version") or "").strip()

    if not command_id:
        return
    candidate_urls: list[str] = []
    if download_url:
        candidate_urls.append(download_url)
    if isinstance(download_urls, list):
        for item in download_urls:
            url = (str(item) if item is not None else "").strip()
            if url and url not in candidate_urls:
                candidate_urls.append(url)

    if not candidate_urls:
        _queue_command_result(command_id, "failed", "Missing download_url")
        return

    try:
        log.info("Executing agent upgrade command %s -> %s", command_id, target_version or "latest")

        new_code = ""
        errors: list[str] = []
        for candidate in candidate_urls:
            try:
                response = requests.get(candidate, timeout=45)
                if not response.ok:
                    errors.append(f"{candidate}: HTTP {response.status_code}")
                    continue
                candidate_code = response.text
                if "AGENT_VERSION" not in candidate_code:
                    errors.append(f"{candidate}: invalid agent script")
                    continue
                new_code = candidate_code
                log.info("Upgrade script downloaded from %s", candidate)
                break
            except Exception as e:
                errors.append(f"{candidate}: {e}")

        if not new_code:
            summary = "; ".join(errors[-3:]) if errors else "Unknown download error"
            _queue_command_result(command_id, "failed", f"Download failed: {summary}")
            return

        if _IS_FROZEN:
            _queue_command_result(command_id, "failed", "Upgrade not supported in frozen executable mode")
            return

        script_path = Path(__file__).resolve()
        backup_path = script_path.with_suffix(".py.bak")
        try:
            backup_path.write_text(script_path.read_text(encoding="utf-8"), encoding="utf-8")
        except Exception:
            pass

        script_path.write_text(new_code, encoding="utf-8")

        msg = f"Agent upgraded to {target_version}" if target_version else "Agent upgraded"
        _queue_command_result(command_id, "success", msg)
        global _restart_after_report
        _restart_after_report = True
    except Exception as e:
        _queue_command_result(command_id, "failed", str(e))
        log.error("Upgrade command %s error: %s", command_id, e)


def _start_command_if_needed(command: dict) -> None:
    global _active_command_id
    command_id = (command.get("command_id") or "").strip()
    command_type = (command.get("type") or "").strip()

    if not command_id or command_type not in ("install_software", "upgrade_agent"):
        return

    with _command_lock:
        if _active_command_id == command_id:
            return
        if _active_command_id:
            log.info("Ignoring command %s (command %s already running)", command_id, _active_command_id)
            return
        _active_command_id = command_id

    def _runner():
        global _active_command_id
        try:
            if command_type == "upgrade_agent":
                _execute_upgrade_agent_command(command)
            else:
                _execute_install_command(command)
        finally:
            with _command_lock:
                _active_command_id = ""

    threading.Thread(target=_runner, daemon=True, name=f"classhero-cmd-{command_id}").start()


def heartbeat_loop(cfg: configparser.ConfigParser, mac: str, interval: int) -> None:
    """Daemon thread â€” sends heartbeat every `interval` seconds, forever."""
    while True:
        time.sleep(interval)
        try:
            heartbeat(cfg, mac)
        except Exception as e:
            log.error("Unexpected heartbeat error: %s", e)


# â”€â”€ Entry point â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

def main() -> None:
    log.info("=" * 60)
    log.info("%s v%s  |  %s", AGENT_NAME, AGENT_VERSION, AGENT_VENDOR)
    log.info("Log: %s", LOG_PATH)
    log.info("=" * 60)

    cfg = load_config()

    school_id = cfg.get("agent", "school_id", fallback="")
    backends = _configured_backends(cfg)

    if not school_id or school_id == "YOUR_SCHOOL_ID":
        log.error("school_id not configured in agent_config.ini â€” agent cannot start.")
        _flush_log()
        sys.exit(1)

    if not backends:
        log.error("backend_urls/backend_url not configured in agent_config.ini — agent cannot start.")
        _flush_log()
        sys.exit(1)

    log.info("School : %s | Backends: %s", school_id, ", ".join(backends))

    info = collect_device_info(cfg)
    log.info("Device : %s | %s | %s | MAC=%s",
             info["device_name"], info["device_os"],
             info["device_type"], info["mac_address"])
    # VPN check (uses public IP collected above)
    info["is_vpn"] = is_vpn_detected(info["public_ip"])
    log.info("IPs    : local=%s  public=%s  vpn=%s",
             info["device_ip"], info["public_ip"], info["is_vpn"])

    # Register with exponential back-off â€” keeps retrying even if backend is
    # down at boot (e.g. network not yet available)
    attempt = 0
    while True:
        attempt += 1
        if register(cfg, info):
            break
        wait = min(120, 10 * attempt)
        log.warning("Registration attempt %d failed â€” retry in %d s", attempt, wait)
        time.sleep(wait)

    interval = cfg.getint("agent", "heartbeat_every", fallback=30)
    t = threading.Thread(
        target=heartbeat_loop,
        args=(cfg, info["mac_address"], interval),
        daemon=True,
        name="classhero-heartbeat",
    )
    t.start()
    log.info("Heartbeat thread started (every %d s) â€” running silently.", interval)

    # Main thread must stay alive; daemon thread stops when this exits.
    try:
        while True:
            time.sleep(60)
    except KeyboardInterrupt:
        log.info("%s stopped by user.", AGENT_NAME)


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        import traceback
        log.error("FATAL unhandled exception:\n%s", traceback.format_exc())
        _flush_log()
        raise
