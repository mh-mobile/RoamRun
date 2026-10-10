#!/usr/bin/env python3
"""Mechanics check on one Mac. The offer goes out under a test service type (never the real
one): the record is seen by mDNSResponder, a stranger is refused, the "device" is carried to a
fake far Mac, and the goodbye goes out. The device's line is made from a fake record of the
device's real type, `_remotepairing._tcp`, which this LAN sees while the check runs.
Then device control against a fake far Mac's wire (port 41830 on 127.0.0.1): asked which device
it is, it answers with that record, announces the offer it then gets, shows the code, and ends
on what that Mac says it kept.

    cargo build && python3 scripts/local-check.py target/debug/roamrunctl $(ipconfig getifaddr en0)
"""
import base64, json, socket, subprocess, sys, threading, time, uuid

BIN, LAN = sys.argv[1], sys.argv[2]
FAR_PORT, SERVICE = 53050, "_rrtest._tcp"
IDENT = str(uuid.uuid4()).upper()
DEV_IDENT = str(uuid.uuid4()).upper()
failures = []

def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name, detail, flush=True)
    if not ok: failures.append(name)

def pack(prefix, d):
    s = json.dumps(d, sort_keys=True, separators=(",", ":")).encode()
    return prefix + base64.urlsafe_b64encode(s).decode().rstrip("=")

def probe(args, seconds=4):
    p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    time.sleep(seconds); p.kill()
    return p.communicate()[0]

# fake far Mac: echoes each connection (the first is the reachability probe)
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); srv.bind(("127.0.0.1", FAR_PORT)); srv.listen(2)
def far():
    while True:
        c, _ = srv.accept(); c.sendall(b"hello-from-far " + c.recv(100)); c.close()
threading.Thread(target=far, daemon=True).start()

# a fake device announcement at this Mac's own address (its host record carries en0)
fake_device = subprocess.Popen(["dns-sd", "-R", "fakephone", "_remotepairing._tcp", "local.", "49152",
                                f"identifier={DEV_IDENT}", "authTag=ZmFrZQ", "flags=1", "ver=2", "minVer=1"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
procs = [fake_device]
try:
    browser = subprocess.Popen(["dns-sd", "-B", SERVICE, "local."], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    offer = pack("rr-xcode-offer-v1:", {"v": 1, "port": FAR_PORT, "txt": {
        "identifier": IDENT, "authTag": "dGVzdA", "model": "Mac16,1", "name": "Fake Offer Name", "flags": "1", "ver": "2", "minVer": "1"}})
    procs.append(browser)
    proc = subprocess.Popen([BIN, "pair", "introduce", "--mac", "fake-mac.tail.ts.net", "--to", "fake-iphone", "--offer", offer,
                             "--service", SERVICE, "--far-ip", "127.0.0.1", "--device-ip", LAN, "--deadline", "60", "--as", "Fake iPhone"],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    procs.append(proc)
    time.sleep(5)

    out = probe(["dns-sd", "-L", IDENT, SERVICE, "local."])
    txt = out.strip().splitlines()[-1] if out.strip() else ""
    check("dns-sd -L shows the record", f"rr-intro-{IDENT[:8].lower()}.roamrun.local.:{FAR_PORT}" in out, txt)
    check("TXT has 7 keys, name replaced", all(k in txt for k in ["identifier=", "authTag=", "model=", "name=fake-mac", "flags=", "ver=", "minVer="]) and "Fake\\ Offer" not in txt)
    out = probe(["dns-sd", "-G", "v4", f"rr-intro-{IDENT[:8].lower()}.roamrun.local"])
    check("dns-sd -G gives the en0 address", LAN in out, out.strip().splitlines()[-1] if out.strip() else "")

    # Taken and closed at once, nothing carried: a relay that isn't listening fails the connect instead.
    s = socket.socket(); s.settimeout(3); s.bind(("127.0.0.1", 0)); s.connect((LAN, FAR_PORT))
    try:
        s.sendall(b"x"); got = s.recv(100)
    except ConnectionError:
        got = b""
    check("stranger from 127.0.0.1 refused", got == b"", f"got {got!r}")
    s.close()
    s = socket.socket(); s.settimeout(5); s.bind((LAN, 0)); s.connect((LAN, FAR_PORT)); s.sendall(b"ping")
    got = s.recv(100); s.close()
    check("device relayed to the fake far Mac", got == b"hello-from-far ping", repr(got))

    try:
        stdout, stderr = proc.communicate(timeout=20)
    except subprocess.TimeoutExpired:
        proc.kill(); stdout, stderr = proc.communicate()
        check("binary exits after the carried connection", False)
    else:
        check("binary exits after the carried connection", True, f"exit {proc.returncode}")
    print(stderr, end="", flush=True)
    line = stdout.strip()
    check("the stranger's refusal is said", "refused connection from 127.0.0.1" in stderr)
    check("exit 0 with a device line", proc.returncode == 0 and line.startswith("rr-device-v1:"), line[:60])
    if line.startswith("rr-device-v1:"):
        b = line[len("rr-device-v1:"):]
        d = json.loads(base64.urlsafe_b64decode(b + "=" * (-len(b) % 4)))
        check("device line content", d == {"v": 1, "name": "Fake iPhone", "peer": "fake-iphone", "port": 49152,
              "txt": {"identifier": DEV_IDENT, "authTag": "ZmFrZQ", "flags": "1", "ver": "2", "minVer": "1"}}, json.dumps(d))

    time.sleep(4); browser.kill(); seen = browser.communicate()[0]
    check("dns-sd -B saw Add", any("Add" in l and IDENT in l for l in seen.splitlines()))
    check("dns-sd -B saw Rmv (goodbye)", any("Rmv" in l and IDENT in l for l in seen.splitlines()))

    # --- device control: a fake far Mac's wire, which asks for the device before it offers
    print("-- device control", flush=True)
    CONTROL_IDENT, ATTEMPT = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
    control_offer = pack("rr-xcode-offer-v1:", {"v": 1, "port": FAR_PORT, "txt": {
        "identifier": CONTROL_IDENT, "authTag": "dGVzdA", "model": "Mac16,1", "name": "Fake Offer Name", "flags": "1", "ver": "2", "minVer": "1"}})
    said, connected, carried = [], threading.Event(), threading.Event()
    wire = socket.socket(); wire.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); wire.bind(("127.0.0.1", 41830)); wire.listen(1)
    def far_wire():
        c, _ = wire.accept(); f = c.makefile("rw", newline="\n")
        def tell(words): f.write("rr-pair-v1 " + words + "\n"); f.flush()
        said.append(f.readline().strip()); tell("device?")
        said.append(f.readline().strip()); tell("offer " + control_offer); tell("attempt " + ATTEMPT)
        connected.wait(30); tell("code 456640"); carried.wait(30); time.sleep(1); tell("result done on")
        said.append(f.readline().strip()); c.close()
    threading.Thread(target=far_wire, daemon=True).start()
    proc = subprocess.Popen([BIN, "pair", "introduce", "--mac", "fake-mac.tail.ts.net", "--to", "fake-iphone",
                             "--service", SERVICE, "--far-ip", "127.0.0.1", "--device-ip", LAN, "--deadline", "60"],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    procs.append(proc)
    time.sleep(12)
    check("asked for the offer, then answered which device it is", len(said) >= 2 and said[0] == "rr-pair-v1 offer?" and said[1].startswith("rr-pair-v1 device rr-device-v1:"), repr(said[:1]))
    if len(said) >= 2 and "rr-device-v1:" in said[1]:
        b = said[1].split("rr-device-v1:")[1]
        d = json.loads(base64.urlsafe_b64decode(b + "=" * (-len(b) % 4)))
        check("the device named by its Tailscale name, with its own announcement", d.get("name") == "fake-iphone" and d.get("peer") == "fake-iphone"
              and d.get("txt", {}).get("identifier") == DEV_IDENT, json.dumps(d))
    out = probe(["dns-sd", "-L", CONTROL_IDENT, SERVICE, "local."])
    check("the offer that came by wire is announced", f"rr-intro-{CONTROL_IDENT[:8].lower()}.roamrun.local." in out)
    # The code comes while the device is connected, as it does with a real one.
    s = socket.socket(); s.settimeout(5); s.bind((LAN, 0)); s.connect((LAN, FAR_PORT)); connected.set(); time.sleep(2)
    s.sendall(b"ping"); got = s.recv(100); s.close()
    check("device relayed to the fake far Mac", got == b"hello-from-far ping", repr(got))
    carried.set()
    try:
        stdout, stderr = proc.communicate(timeout=20)
    except subprocess.TimeoutExpired:
        proc.kill(); stdout, stderr = proc.communicate()
    print(stderr, end="", flush=True)
    check("the code is shown", "Code to type on the device: 456640" in stderr)
    check("exit 0 on what the far Mac kept, and no line on stdout", proc.returncode == 0 and stdout.strip() == "" and "switched on there" in stderr, f"exit {proc.returncode}")
    check("nothing said to the far Mac after its result", len(said) == 3 and said[2] == "", repr(said[2:]))
finally:
    # Whatever went wrong, nothing stays announced.
    for p in procs:
        if p.poll() is None: p.kill()
sys.exit(1 if failures else 0)
