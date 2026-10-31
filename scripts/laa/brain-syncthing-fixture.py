#!/usr/bin/env python3
"""Exercise Brain's retention assumptions with two isolated Syncthing peers.

Requires an installed `syncthing` binary. This creates disposable identities,
loopback-only listeners and synthetic notes under the specified work directory;
it never reads the production vault or connects to its Syncthing instance.
"""

import argparse
import ctypes
import hashlib
import json
import os
import pathlib
import socket
import stat
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ET


WORK_DIR = pathlib.Path("/Users/laa/work/laa-brain-app-20261101")
REPO_DIR = pathlib.Path(__file__).resolve().parents[2]
FOLDER_ID = "brain-fixture"
DEADLINE_SECONDS = 35


def free_ports(count):
    # Keep all sockets reserved until the entire set has been allocated.
    sockets = []
    try:
        for _ in range(count):
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.bind(("127.0.0.1", 0))
            sockets.append(s)
        return [s.getsockname()[1] for s in sockets]
    finally:
        for s in sockets:
            s.close()


def set_text(parent, tag, value):
    element = parent.find(tag)
    if element is None:
        element = ET.SubElement(parent, tag)
    element.text = str(value)
    return element


def replace_all(parent, tag, value):
    for element in parent.findall(tag):
        parent.remove(element)
    set_text(parent, tag, value)


class Peer:
    def __init__(self, root, name, sync_port, gui_port):
        self.root = root / name
        self.home = self.root / "home"
        self.notes = self.root / "notes"
        self.home.mkdir(parents=True)
        self.notes.mkdir()
        self.sync_port = sync_port
        self.gui_port = gui_port
        self.process = None
        subprocess.run(
            ["syncthing", "generate", "--home", str(self.home), "--no-port-probing"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=20,
        )
        self.tree = ET.parse(self.home / "config.xml")
        self.config = self.tree.getroot()
        self.device_id = self.config.find("device").attrib["id"]
        self.api_key = self.config.find("gui/apikey").text

    def configure(self, other, *, versioning):
        # Never start a generated default folder, use only this fixture's paths.
        for folder in self.config.findall("folder"):
            self.config.remove(folder)
        folder = ET.SubElement(
            self.config,
            "folder",
            id=FOLDER_ID,
            label="Disposable synthetic notes",
            path=str(self.notes),
            type="sendreceive",
            rescanIntervalS="86400",
            fsWatcherEnabled="false",
            ignorePerms="false",
            autoNormalize="true",
        )
        set_text(folder, "filesystemType", "basic")
        for peer in (self, other):
            ET.SubElement(folder, "device", id=peer.device_id, introducedBy="")
        set_text(folder, "maxConflicts", "-1")
        if versioning:
            version = ET.SubElement(folder, "versioning", type="simple")
            set_text(version, "cleanupIntervalS", "3600")
            set_text(version, "fsPath", "")
            set_text(version, "fsType", "basic")
            ET.SubElement(version, "param", key="cleanoutDays", val="0")
            ET.SubElement(version, "param", key="keep", val="30")

        remote = ET.SubElement(self.config, "device", id=other.device_id, name="fixture-peer")
        set_text(remote, "address", f"tcp://127.0.0.1:{other.sync_port}")
        set_text(remote, "autoAcceptFolders", "false")
        gui = self.config.find("gui")
        gui.set("enabled", "true")
        gui.set("tls", "false")
        set_text(gui, "address", f"127.0.0.1:{self.gui_port}")
        options = self.config.find("options")
        replace_all(options, "listenAddress", f"tcp://127.0.0.1:{self.sync_port}")
        for name in (
            "globalAnnounceEnabled",
            "localAnnounceEnabled",
            "relaysEnabled",
            "natEnabled",
            "startBrowser",
            "crashReportingEnabled",
        ):
            set_text(options, name, "false")
        set_text(options, "urAccepted", "-1")
        set_text(options, "autoUpgradeIntervalH", "0")
        set_text(options, "reconnectionIntervalS", "1")
        self.tree.write(self.home / "config.xml", encoding="utf-8", xml_declaration=True)

    def start(self):
        # Ignore inherited Syncthing overrides, which could point at real data.
        env = {k: v for k, v in os.environ.items() if not k.startswith("ST")}
        self.process = subprocess.Popen(
            [
                "syncthing", "serve", "--home", str(self.home), "--no-browser",
                "--no-restart", "--no-port-probing", "--no-upgrade", "--log-file=-",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
        )

    def stop(self):
        if self.process is None or self.process.poll() is not None:
            return
        self.process.terminate()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=10)

    def api(self, endpoint, *, params=None, post=False):
        url = f"http://127.0.0.1:{self.gui_port}/rest/{endpoint}"
        if params:
            url += "?" + urllib.parse.urlencode(params)
        request = urllib.request.Request(
            url,
            data=b"" if post else None,
            headers={"X-API-Key": self.api_key},
            method="POST" if post else "GET",
        )
        with urllib.request.urlopen(request, timeout=3) as response:
            body = response.read()
            return json.loads(body) if body else None

    def scan(self):
        self.api("db/scan", params={"folder": FOLDER_ID}, post=True)


def wait_for(description, predicate, peers=()):
    deadline = time.monotonic() + DEADLINE_SECONDS
    while time.monotonic() < deadline:
        for peer in peers:
            if peer.process is not None and peer.process.poll() is not None:
                raise RuntimeError(f"fixture peer exited while waiting for {description}")
        try:
            if predicate():
                return
        except (ConnectionError, OSError, urllib.error.URLError, json.JSONDecodeError):
            pass
        time.sleep(0.2)
    raise RuntimeError(f"timed out waiting for {description}")


def file_is(path, value):
    try:
        return path.read_bytes() == value
    except (FileNotFoundError, OSError):
        return False


def ordinary_file_contents(directory):
    """Read synthetic notes, conflict copies and version archives, not indexes."""
    found = []
    for path in directory.rglob("*"):
        if path.is_file() and ".stfolder" not in path.parts:
            try:
                found.append(path.read_bytes())
            except OSError:
                pass
    return found


def send(source, destination, name, value):
    (source.notes / name).write_bytes(value)
    source.scan()
    wait_for("synthetic note to arrive", lambda: file_is(destination.notes / name, value), (source, destination))
    wait_for("both folders to become idle", lambda: all(
        p.api("db/status", params={"folder": FOLDER_ID})["state"] == "idle"
        for p in (source, destination)
    ), (source, destination))


def assert_settings(phone, mac):
    for peer, expected_type in ((phone, ""), (mac, "simple")):
        cfg = peer.api("config/folders/" + FOLDER_ID)
        assert cfg["fsWatcherEnabled"] is False
        assert cfg["maxConflicts"] == -1
        assert cfg["versioning"]["type"] == expected_type
        if expected_type:
            assert cfg["versioning"]["params"]["keep"] == "30"
            assert cfg["versioning"]["params"]["cleanoutDays"] == "0"


def exchange_files(a, b):
    # Darwin's RENAME_SWAP; this is a local Mac experiment, not an iOS proof.
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renameatx_np
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(-2, os.fsencode(a), -2, os.fsencode(b), 0x00000002) != 0:
        number = ctypes.get_errno()
        raise OSError(number, os.strerror(number))


def journal_record(path, content):
    with path.open("xb") as output:
        output.write(content)
        output.flush()
        os.fsync(output.fileno())


def build_swift_fixture(root):
    binary = root / "brain-save-fixture"
    subprocess.run([
        "swiftc", "-parse-as-library", "-D", "LAA_BUILD", "-D", "DEBUG",
        str(REPO_DIR / "Conduit/LAA/Brain/LAABrainSaveJournal.swift"),
        str(REPO_DIR / "Conduit/LAA/Brain/LAABrainSaveCoordinator.swift"),
        str(REPO_DIR / "scripts/laa/brain-save-fixture.swift"), "-o", str(binary),
    ], check=True, timeout=90)
    subprocess.run([str(binary), "selftest", str(root / "swift-selftest")], check=True, timeout=30)
    return binary


def run_fixture(root, *, retention):
    swift_fixture = build_swift_fixture(root)
    sync_a, gui_a, sync_b, gui_b = free_ports(4)
    phone = Peer(root, "phone-model", sync_a, gui_a)
    mac = Peer(root, "mac-model", sync_b, gui_b)
    phone.configure(mac, versioning=False)
    mac.configure(phone, versioning=True)
    try:
        phone.start()
        mac.start()
        wait_for("both APIs", lambda: phone.api("system/status") and mac.api("system/status"), (phone, mac))
        assert_settings(phone, mac)
        wait_for("loopback peer connection", lambda: phone.api("system/connections")["connections"].get(
            mac.device_id, {}).get("connected") is True, (phone, mac))

        send(mac, phone, "remote-archive.md", b"MAC_BASE")
        send(phone, mac, "remote-archive.md", b"PHONE_CHANGE")
        wait_for("Mac to archive replaced remote version", lambda: b"MAC_BASE" in
                 ordinary_file_contents(mac.notes / ".stversions"), (phone, mac))
        print("PASS: remote replacement on the Mac archives its previous file")

        send(mac, phone, "mac-local.md", b"LOCAL_OLD")
        send(mac, phone, "mac-local.md", b"LOCAL_NEW")
        assert b"LOCAL_OLD" not in ordinary_file_contents(mac.notes)
        assert b"LOCAL_OLD" not in ordinary_file_contents(phone.notes)
        print("OBSERVED: a Mac-local replacement can remove a previously synced version from both peers")

        send(mac, phone, "offline.md", b"OFFLINE_BASE")
        phone.api("system/pause", params={"device": mac.device_id}, post=True)
        wait_for("peer disconnection", lambda: not phone.api("system/connections")["connections"].get(
            mac.device_id, {}).get("connected", False), (phone, mac))
        before_phone = phone.api("db/file", params={"folder": FOLDER_ID, "file": "offline.md"})["local"]["sequence"]
        before_mac = mac.api("db/file", params={"folder": FOLDER_ID, "file": "offline.md"})["local"]["sequence"]
        (phone.notes / "offline.md").write_bytes(b"OFFLINE_PHONE_VERSION")
        (mac.notes / "offline.md").write_bytes(b"OFFLINE_MAC_VERSION")
        phone.scan()
        mac.scan()
        wait_for("offline edits to be indexed independently", lambda: all(
            p.api("db/file", params={"folder": FOLDER_ID, "file": "offline.md"})["local"]["sequence"] > before
            for p, before in ((phone, before_phone), (mac, before_mac))
        ), (phone, mac))
        phone.api("system/resume", params={"device": mac.device_id}, post=True)
        wait_for("peer reconnection", lambda: phone.api("system/connections")["connections"].get(
            mac.device_id, {}).get("connected", False), (phone, mac))
        wait_for("offline conflict versions", lambda: all(
            b"OFFLINE_PHONE_VERSION" in ordinary_file_contents(p.notes)
            and b"OFFLINE_MAC_VERSION" in ordinary_file_contents(p.notes)
            and any(".sync-conflict-" in path.name for path in p.notes.rglob("*"))
            for p in (phone, mac)
        ), (phone, mac))
        print("PASS: independently indexed offline edits produce a conflict copy on both peers")

        send(mac, phone, "compare-gap.md", b"EDIT_BASE")
        start = (phone.notes / "compare-gap.md").read_bytes()
        app_draft = b"APP_DRAFT"
        journal = root / "protected-journal-model"
        journal.mkdir()
        (journal / "start").write_bytes(start)
        (journal / "draft").write_bytes(app_draft)
        assert hashlib.sha256((phone.notes / "compare-gap.md").read_bytes()).digest() == hashlib.sha256(start).digest()
        (phone.notes / "compare-gap.md").write_bytes(b"INTERVENING_PHONE_WRITE")
        replacement = phone.notes / "replacement.tmp"
        replacement.write_bytes(app_draft)
        os.replace(replacement, phone.notes / "compare-gap.md")
        phone.scan()
        wait_for("app draft to reach the Mac", lambda: file_is(mac.notes / "compare-gap.md", app_draft), (phone, mac))
        wait_for("base to be archived on the Mac", lambda: start in
                 ordinary_file_contents(mac.notes / ".stversions"), (phone, mac))
        retained = ordinary_file_contents(phone.notes) + ordinary_file_contents(mac.notes) + ordinary_file_contents(journal)
        assert start in retained and app_draft in retained
        assert b"INTERVENING_PHONE_WRITE" not in retained
        print("OBSERVED: a phone-local write between hash comparison and replacement is absent from both peers and the app journal")

        send(mac, phone, "swap-candidate.md", b"SWAP_BASE")
        original = phone.notes / "swap-candidate.md"
        # Syncthing v2.1.6 ignores this reserved prefix regardless of suffix:
        # https://docs.syncthing.net/users/syncing.html#temporary-files
        staged = phone.notes / (".syncthing.laa-brain-" + uuid.uuid4().hex)
        journal_record(journal / "swap-start", b"SWAP_BASE")
        journal_record(journal / "swap-draft", b"SWAP_DRAFT")
        staged.write_bytes(b"SWAP_DRAFT")
        phone.scan()
        assert hashlib.sha256(original.read_bytes()).digest() == hashlib.sha256(b"SWAP_BASE").digest()
        original.write_bytes(b"SWAP_INTERVENING")
        exchange_files(original, staged)
        assert file_is(original, b"SWAP_DRAFT") and file_is(staged, b"SWAP_INTERVENING")
        journal_record(journal / "swap-displaced", staged.read_bytes())
        staged.unlink()
        phone.scan()
        wait_for("swapped draft to reach the Mac", lambda: file_is(mac.notes / "swap-candidate.md", b"SWAP_DRAFT"), (phone, mac))
        assert b"SWAP_INTERVENING" in ordinary_file_contents(journal)
        assert not (mac.notes / staged.name).exists()
        print("PASS: two-peer fixture retains the intervening file in the journal after atomic exchange")

        # A swap preserves the displaced inode's old mtime. Syncthing deletes
        # stale files with its temporary prefix while scanning; it does not just
        # ignore them. Reproduce a scan after exchange and before journal copy.
        original.write_bytes(b"OLD_INTERVENING")
        old = time.time() - 3 * 24 * 60 * 60
        os.utime(original, (old, old))
        staged.write_bytes(b"OLD_DRAFT")
        journal_record(journal / "old-draft", b"OLD_DRAFT")
        exchange_files(original, staged)
        assert file_is(staged, b"OLD_INTERVENING")
        phone.scan()
        wait_for("Syncthing stale temporary cleanup", lambda: not staged.exists(), (phone, mac))
        assert b"OLD_INTERVENING" not in ordinary_file_contents(phone.notes) + ordinary_file_contents(mac.notes) + ordinary_file_contents(journal)
        print("OBSERVED: Syncthing can delete an old displaced file before the journal captures it")

        # Alternative experiment only: this app-private model is on the same
        # Mac filesystem but outside the synchronized folder. The real iOS app
        # container and File Provider may be on different volumes or disallow it.
        candidate_dir = journal / "swap-staging"
        candidate_dir.mkdir()
        alternative = candidate_dir / ("stage-" + uuid.uuid4().hex)
        original.write_bytes(b"PRIVATE_OLD_INTERVENING")
        os.utime(original, (old, old))
        alternative.write_bytes(b"PRIVATE_DRAFT")
        exchange_files(original, alternative)
        phone.scan()
        wait_for("private-staging draft to sync", lambda: file_is(mac.notes / "swap-candidate.md", b"PRIVATE_DRAFT"), (phone, mac))
        assert file_is(alternative, b"PRIVATE_OLD_INTERVENING")
        journal_record(journal / "private-displaced", alternative.read_bytes())
        alternative.unlink()
        assert b"PRIVATE_OLD_INTERVENING" in ordinary_file_contents(journal)
        print("PASS: app-private staging on the same Mac filesystem survives the scan and can be journaled")

        # A non-cooperating writer may already hold the displaced inode open.
        # Copying and removing it immediately cannot preserve its later writes.
        original.write_bytes(b"HELD_BASE")
        staged.write_bytes(b"HELD_DRAFT")
        fd = os.open(original, os.O_WRONLY)
        try:
            exchange_files(original, staged)
            (journal / "held-captured").write_bytes(staged.read_bytes())
            staged.unlink()
            os.ftruncate(fd, 0)
            os.write(fd, b"HELD_WRITER_LATER")
        finally:
            os.close(fd)
        retained = ordinary_file_contents(phone.notes) + ordinary_file_contents(mac.notes) + ordinary_file_contents(journal)
        assert b"HELD_WRITER_LATER" not in retained
        print("OBSERVED: copying and removing a swapped-out file cannot preserve later writes through an already-open descriptor")

        # Exercise the real Swift coordinator, not the Python exchange model.
        # Its debug hook inserts the intermediate writer after the hash check.
        name = "swift-exchange-metadata.md"
        send(mac, phone, name, b"SWIFT_BASE")
        phone_note = phone.notes / name
        os.chmod(phone_note, 0o640)
        subprocess.run(["xattr", "-w", "com.laa.fixture", "synthetic-xattr", str(phone_note)], check=True)
        before = phone_note.stat()
        before_xattr = subprocess.check_output(["xattr", "-p", "com.laa.fixture", str(phone_note)])
        swift_journal = root / "swift-private-journal"
        result = subprocess.run([
            str(swift_fixture), "race", str(phone.notes), str(swift_journal), name,
            "SWIFT_DRAFT", "SWIFT_INTERVENING",
        ], check=True, timeout=30, text=True, capture_output=True)
        assert json.loads(result.stdout)["outcome"] == "intervening"
        after = phone_note.stat()
        after_xattr_result = subprocess.run(["xattr", "-p", "com.laa.fixture", str(phone_note)], capture_output=True)
        after_xattr = after_xattr_result.stdout if after_xattr_result.returncode == 0 else None
        phone.scan()
        wait_for("Swift exchange to sync to Mac", lambda: file_is(mac.notes / name, b"SWIFT_DRAFT"), (phone, mac))
        # This verifies filesystem reads on both peers. It is not an Obsidian
        # app read and does not substitute for the requested Obsidian test.
        assert phone_note.read_text() == (mac.notes / name).read_text() == "SWIFT_DRAFT"
        versions = [json.loads(path.read_text()) for path in (swift_journal / "versions").rglob("*.json")]
        assert {item["kind"] for item in versions} >= {"original", "draft", "displaced"}
        assert any(item["kind"] == "displaced" and item["bytes"] == "U1dJRlRfSU5URVJWRU5JTkc=" for item in versions)
        print("PASS: real Swift coordinator retains its intervening version and syncs its draft")
        print("METADATA (Mac APFS fixture): birthtime preserved={}, mode {:04o}->{:04o}, xattr preserved={}; Mac mode={:04o}".format(
            before.st_birthtime == after.st_birthtime, stat.S_IMODE(before.st_mode), stat.S_IMODE(after.st_mode),
            before_xattr == after_xattr, stat.S_IMODE((mac.notes / name).stat().st_mode)))

        # Simulate a provider/filesystem that does not preserve the metadata.
        # All three changes occur on the stage before the real Swift swap.
        name = "swift-changed-metadata.md"
        send(mac, phone, name, b"METADATA_BASE")
        phone_note = phone.notes / name
        os.chmod(phone_note, 0o640)
        subprocess.run(["xattr", "-w", "com.laa.fixture", "original-xattr", str(phone_note)], check=True)
        before = phone_note.stat()
        subprocess.run([
            str(swift_fixture), "race", str(phone.notes), str(swift_journal), name,
            "METADATA_DRAFT", "METADATA_INTERVENING", "change-metadata",
        ], check=True, timeout=30, text=True, capture_output=True)
        after = phone_note.stat()
        assert before.st_birthtime != after.st_birthtime
        assert stat.S_IMODE(before.st_mode) == 0o640 and stat.S_IMODE(after.st_mode) == 0o600
        assert subprocess.check_output(["xattr", "-p", "com.laa.fixture", str(phone_note)]).strip() == b"changed-xattr"
        phone.scan()
        wait_for("changed-metadata note to sync", lambda: file_is(mac.notes / name, b"METADATA_DRAFT"), (phone, mac))
        assert phone_note.read_text() == (mac.notes / name).read_text() == "METADATA_DRAFT"
        print("PASS: changed creation time, xattr and permissions do not prevent two-peer sync or filesystem reads")

        # An old path can disappear while its non-UTF-8 version remains in the
        # app journal. Restore a distinct file and compare exact bytes on both peers.
        old_name = "swift-deleted-recovery.md"
        send(mac, phone, old_name, b"RECOVERY_ORIGINAL")
        recovered = subprocess.run([
            str(swift_fixture), "recover-binary", str(phone.notes), str(swift_journal), old_name,
        ], check=True, timeout=30, text=True, capture_output=True)
        recovered_name = json.loads(recovered.stdout)["path"]
        binary = b"\xff\xfe\x80\x00"
        assert not (phone.notes / old_name).exists()
        assert file_is(phone.notes / recovered_name, binary)
        phone.scan()
        wait_for("byte-exact recovery to sync", lambda: file_is(mac.notes / recovered_name, binary), (phone, mac))
        wait_for("old path to remain deleted", lambda: not (mac.notes / old_name).exists(), (phone, mac))
        print("PASS: deleted-path binary history restores as a distinct byte-exact file on both peers")
        print("PENDING: actual Obsidian reading and the iOS simulator/device remain separate checks")

        if retention:
            send(mac, phone, "retention.md", b"RETAIN_00")
            for number in range(1, 32):
                # Simple version names have one-second timestamps.
                time.sleep(1.05)
                send(phone, mac, "retention.md", f"RETAIN_{number:02d}".encode())
            archives = ordinary_file_contents(mac.notes / ".stversions")
            assert b"RETAIN_00" not in archives
            assert all(f"RETAIN_{number:02d}".encode() in archives for number in range(1, 31))
            assert len([content for content in archives if content.startswith(b"RETAIN_")]) == 30
            print("PASS: simple keep=30 retains the most recent 30 remotely replaced versions, not the 31st")
    finally:
        phone.stop()
        mac.stop()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--retention", action="store_true", help="also perform 31 sequential remote replacements")
    parser.add_argument("--keep", action="store_true", help="keep the disposable folders for a subsequent Obsidian app check")
    args = parser.parse_args()
    WORK_DIR.mkdir(parents=True, exist_ok=True)
    if args.keep:
        directory = tempfile.mkdtemp(prefix="brain-syncthing-fixture-", dir=WORK_DIR)
        try:
            run_fixture(pathlib.Path(directory), retention=args.retention)
        finally:
            print("Synthetic fixture retained for Obsidian inspection:", directory)
    else:
        with tempfile.TemporaryDirectory(prefix="brain-syncthing-fixture-", dir=WORK_DIR) as directory:
            run_fixture(pathlib.Path(directory), retention=args.retention)


if __name__ == "__main__":
    main()
