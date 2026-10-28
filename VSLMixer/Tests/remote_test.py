"""Tests the phone-control server and page against the running app.

Needs VSL Mixer running.  It changes the live board while it runs, so it
first saves a snapshot to a file, pulls every master to -inf (with output N
cabled to input N, raised sends could otherwise make a feedback loop), and
puts everything back at the end.  If a run dies partway, the next run
restores the saved snapshot before doing anything else.

    python3 -m venv .venv && .venv/bin/pip install websockets playwright
    .venv/bin/python VSLMixer/Tests/remote_test.py [--ui] [--shots DIR]

--ui also drives the phone page in headless Chrome (installed Google Chrome)
with phone-sized touch screens; --shots saves screenshots of each screen.
"""

import json
import os
import sys
import time
from websockets.sync.client import connect

HTTP = "http://127.0.0.1:8080"
WS = "ws://127.0.0.1:8081/"
SESSION = os.path.expanduser(
    "~/Library/Containers/com.jefftk.vslmixer/Data/Library/Application Support/VSL Mixer/session.json")

SNAPSHOT = os.path.join(os.environ.get("TMPDIR", "/tmp"), "vslmixer-remote-test-snapshot.json")

failures = 0


def check(what, ok, detail=""):
    global failures
    print(("  ok    " if ok else "FAIL    ") + what + (f"  ({detail})" if detail and not ok else ""))
    if not ok:
        failures += 1


class Phone:
    """A WebSocket client speaking the page's protocol."""

    def __init__(self, **hello):
        self._conn = connect(WS)
        self.ws = self._conn.__enter__()
        self.state = None
        self.denied = False
        self.meters = 0
        self.send(t="hello", **hello)
        self.wait_state()

    def send(self, **msg):
        self.ws.send(json.dumps(msg))

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            try:
                msg = json.loads(self.ws.recv(timeout=max(0.01, end - time.time())))
            except TimeoutError:
                break
            if msg["t"] == "state":
                self.state = msg
            elif msg["t"] == "m":
                self.meters += 1
            elif msg["t"] == "denied":
                self.denied = True

    def wait_state(self):
        end = time.time() + 3
        while self.state is None and time.time() < end:
            self.pump(0.1)

    def close(self):
        self._conn.__exit__(None, None, None)


def passcode():
    with open(SESSION) as f:
        return json.load(f)["remoteCode"]


def snapshot(board):
    board.pump(0.2)
    s = board.state
    return {"mixes": [(m["sends"][:], m["master"], m["pans"][:]) for m in s["mixes"]],
            "inputs": [(i["muted"], dict(i["fx"])) for i in s["inputs"]]}


def restore(board, snap):
    for m, (sends, master, pans) in enumerate(snap["mixes"]):
        for c, pos in enumerate(sends):
            board.send(t="send", mix=m, ch=c, pos=pos)
            board.send(t="pan", mix=m, ch=c, pan=pans[c])
        board.send(t="master", mix=m, pos=master)
    for c, (muted, fx) in enumerate(snap["inputs"]):
        board.send(t="mute", ch=c, on=muted)
        board.send(t="channel", ch=c, set=fx)
    board.pump(1.0)


def protocol_tests(code):
    print("Protocol")
    viewer = Phone(role="viewer")
    s = viewer.state
    check("viewer gets state", s is not None and s["t"] == "state")
    check("8 inputs, 8 mixes", len(s["inputs"]) == 8 and len(s["mixes"]) == 8)
    check("viewer sees no processing", not s["board"] and "fx" not in s["inputs"][0])
    check("taper starts with off point", s["taper"][0][1] == -20)
    viewer.pump(0.5)
    check("viewer gets no meters", viewer.meters == 0, viewer.meters)

    aux = Phone(role="aux", mix=2)
    aux.send(t="send", mix=2, ch=3, pos=0.5)
    aux.pump(0.3)
    check("aux can move its own send", abs(aux.state["mixes"][2]["sends"][3] - 0.5) < 1e-3,
          aux.state["mixes"][2]["sends"][3])
    before = aux.state["mixes"][3]["sends"][3]
    muted_before = aux.state["inputs"][3]["muted"]
    aux.send(t="send", mix=3, ch=3, pos=0.9)
    aux.send(t="send", mix=0, ch=3, pos=0.9)
    aux.send(t="mute", ch=3, on=True)
    aux.send(t="channel", ch=3, set={"midDb": 6})
    aux.pump(0.3)
    check("aux can't touch another aux", aux.state["mixes"][3]["sends"][3] == before)
    check("aux can't touch main", aux.state["mixes"][0]["sends"][3] != 0.9)
    check("aux can't mute", aux.state["inputs"][3]["muted"] == muted_before)
    aux.send(t="master", mix=2, pos=0.6)
    aux.pump(0.3)
    check("aux can move its master", abs(aux.state["mixes"][2]["master"] - 0.6) < 1e-3)
    aux.pump(1.0)
    check("aux gets ~15 meter updates a second", 10 <= aux.meters <= 40, aux.meters)
    aux.send(t="send", mix=2, ch=3, pos=7)       # out of range
    aux.send(t="send", mix=2, ch=99, pos=0.5)    # no such channel
    aux.send(t="bogus")
    aux.ws.send("not json")
    aux.pump(0.3)
    check("positions are clamped to 0…1", aux.state["mixes"][2]["sends"][3] == 1.0)

    aux.send(t="pan", mix=2, ch=3, pan=-0.4)
    aux.send(t="pan", mix=2, ch=4, pan=-5)
    aux.send(t="pan", mix=4, ch=3, pan=0.7)
    aux.pump(0.3)
    pans = aux.state["mixes"][2]["pans"]
    check("aux can pan its own mix", abs(pans[3] + 0.4) < 1e-3, pans)
    check("pans are clamped to −1…1", pans[4] == -1, pans)
    check("aux can't pan another aux", aux.state["mixes"][4]["pans"][3] != 0.7)

    uses = [m["use"] for m in aux.state["mixes"]]
    stereo = [m["stereo"] for m in aux.state["mixes"]]
    want = ["none" if m % 2 and stereo[m - 1] else "main" if m == 0 and stereo[0] else "aux"
            for m in range(8)]
    check("mix uses follow the linked pairs", uses == want, (uses, stereo))
    check("only even mixes are stereo", not any(stereo[1::2]), stereo)
    if uses[1] == "none":   # Main drives outs 1 and 2, so there's no Aux 2
        ghost = Phone(role="aux", mix=1)
        before = ghost.state["mixes"][1]["sends"][3]
        ghost.send(t="send", mix=1, ch=3, pos=0.123)
        ghost.pump(0.3)
        check("unused Aux 2 can't be taken", ghost.state["mixes"][1]["sends"][3] == before)
        ghost.close()

    wrong = Phone(role="board", code="nope")
    check("wrong passcode is denied", wrong.denied and not wrong.state["board"])
    wrong.close()

    board = Phone(role="board", code=code)
    check("passcode unlocks the board", board.state["board"] and "fx" in board.state["inputs"][0])
    board.send(t="mute", ch=5, on=True)
    board.send(t="channel", ch=5, set={"midDb": 99, "midHz": 1200, "ratio": 4, "nonsense": 3})
    board.send(t="send", mix=0, ch=5, pos=0.4)
    board.pump(0.3)
    fx = board.state["inputs"][5]["fx"]
    check("board can mute", board.state["inputs"][5]["muted"] is True)
    check("processing values are clamped", fx["midDb"] == 18 and fx["midHz"] == 1200 and fx["ratio"] == 4, fx)
    check("board can move main", abs(board.state["mixes"][0]["sends"][5] - 0.4) < 1e-3)
    viewer.pump(0.3)
    check("other phones see changes", viewer.state["inputs"][5]["muted"] is True
          and abs(viewer.state["mixes"][0]["sends"][5] - 0.4) < 1e-3)
    board.send(t="reset", ch=5, what="eq")
    board.send(t="reset", ch=5, what="comp")
    board.pump(0.3)
    fx = board.state["inputs"][5]["fx"]
    check("reset flattens EQ and compressor", fx["midDb"] == 0 and fx["ratio"] == 1 and fx["hpfHz"] == 20, fx)
    time.sleep(0.8)   # the app saves half a second after a change
    with open(SESSION) as f:
        saved = json.load(f)
    check("phone changes reach the saved session", saved["channels"][5]["muted"] is True
          and abs(saved["mixes"][0]["sends"][5] - 0.4) < 1e-3)

    for p in (viewer, aux, board):
        p.close()


def ui_tests(code, shots):
    from playwright.sync_api import sync_playwright
    print("Phone page")
    devices = [("pixel", 412, 915), ("iphone", 390, 844), ("small", 375, 667)]
    with sync_playwright() as pw:
        browser = pw.chromium.launch(channel="chrome")
        for name, w, h in devices:
            ctx = browser.new_context(viewport={"width": w, "height": h}, device_scale_factor=3,
                                      is_mobile=True, has_touch=True)
            page = ctx.new_page()
            errors = []
            page.on("pageerror", lambda e: errors.append(str(e)))
            page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)

            def shot(label):
                if shots:
                    page.screenshot(path=os.path.join(shots, f"{name}-{label}.png"))

            viewer = Phone(role="viewer")
            uses = [m["use"] for m in viewer.state["mixes"]]
            viewer.close()
            shown = [m for m, u in enumerate(uses) if u != "none"]
            page.goto(HTTP + "/")
            page.wait_for_selector(".mixbtn")
            auxes = uses.count("aux")
            check(f"{name}: landing lists {auxes} auxes", page.locator(".mixbtn").count() == auxes)
            shot("landing")

            page.goto(HTTP + "/#aux/3")
            page.wait_for_selector(".row .fader")
            page.wait_for_timeout(400)
            check(f"{name}: aux page has 8 inputs + master",
                  page.locator(".list .row").count() == 8 and page.locator(".master").count() == 1)
            fits = page.evaluate("document.documentElement.scrollWidth <= window.innerWidth")
            check(f"{name}: no sideways scrolling", fits)
            shot("aux")

            # Drag the first fader right and check the mixer heard it.
            spy = Phone(role="aux", mix=2)
            start = spy.state["mixes"][2]["sends"][0]
            box = page.locator(".list .row .fader").first.bounding_box()
            x0, y0 = box["x"] + 30, box["y"] + box["height"] / 2
            page.mouse.move(x0, y0)
            page.mouse.down()
            for i in range(1, 11):
                page.mouse.move(x0 + i * box["width"] * 0.03, y0)
                page.wait_for_timeout(16)
            page.mouse.up()
            spy.pump(0.5)
            moved = spy.state["mixes"][2]["sends"][0]
            check(f"{name}: dragging a fader moves the send", moved > start + 0.15, f"{start} -> {moved}")
            # A tap on the track mustn't jump the level.
            page.mouse.click(box["x"] + box["width"] - 10, y0)
            spy.pump(0.4)
            check(f"{name}: a tap doesn't jump the fader", abs(spy.state["mixes"][2]["sends"][0] - moved) < 1e-3)
            # Steps are whole dB.
            spy.send(t="send", mix=2, ch=1, pos=0)
            spy.pump(0.3)
            page.wait_for_timeout(200)
            page.locator(".list .row").nth(1).locator(".step").last.click()
            page.locator(".list .row").nth(1).locator(".step").last.click()
            spy.pump(0.4)
            db = page.locator(".list .row").nth(1).locator(".db").inner_text()
            check(f"{name}: + + from −∞ steps to −19 dB", db == "−19.0 dB", db)
            spy.close()

            page.goto(HTTP + "/#board")
            page.wait_for_selector(".passcode input")
            shot("passcode")
            page.fill(".passcode input", "0000" if code != "0000" else "1111")
            page.click(".primary")
            page.wait_for_selector(".error")
            check(f"{name}: wrong passcode shows an error", page.locator(".error").count() == 1)
            page.fill(".passcode input", code)
            page.click(".primary")
            page.wait_for_selector(".chips .chip")
            page.wait_for_timeout(300)
            check(f"{name}: board shows {len(shown)} outputs", page.locator(".chip").count() == len(shown))
            check(f"{name}: board rows have mute buttons", page.locator(".list .mutebtn").count() == 8)
            shot("board")
            # Main is stereo while outs 1+2 are linked (the default): each row gets a pan.
            spy = Phone(role="board", code=code)
            if spy.state["mixes"][0]["stereo"]:
                check(f"{name}: stereo main has a pan per input", page.locator(".list .panrow").count() == 8)
                fits = page.evaluate("document.documentElement.scrollWidth <= window.innerWidth")
                check(f"{name}: pans fit without sideways scrolling", fits)
                box = page.locator(".list .pan").first.bounding_box()
                x0, y0 = box["x"] + box["width"] / 2, box["y"] + box["height"] / 2
                page.mouse.move(x0, y0)
                page.mouse.down()
                for i in range(1, 11):
                    page.mouse.move(x0 - i * box["width"] * 0.03, y0)
                    page.wait_for_timeout(16)
                page.mouse.up()
                spy.pump(0.5)
                pan = spy.state["mixes"][0]["pans"][0]
                check(f"{name}: dragging a pan left pans left", pan < -0.3, pan)
                shot("board-pan")
                page.locator(".list .panval").first.click()
                spy.pump(0.4)
                check(f"{name}: tapping the readout centers it", spy.state["mixes"][0]["pans"][0] == 0)
            spy.close()
            page.locator(".chip").nth(3).click()
            page.wait_for_timeout(300)
            check(f"{name}: picking an output changes the URL", page.url.endswith(f"#board/mix/{shown[3]}"))
            shot("board-aux3")

            page.locator(".list a.name").first.click()
            page.wait_for_selector("canvas.graph")
            page.wait_for_timeout(300)
            shot("eq")
            board = Phone(role="board", code=code)
            canvas = page.locator("canvas.graph").bounding_box()
            # Drag the mid point (green, starts at the center line) upward.
            fx = board.state["inputs"][0]["fx"]
            import math
            mx = canvas["x"] + canvas["width"] * math.log(fx["midHz"] / 20) / math.log(1000)
            my = canvas["y"] + canvas["height"] / 2 - fx["midDb"] / 18 * canvas["height"] / 2
            page.mouse.move(mx, my)
            page.mouse.down()
            for i in range(1, 9):
                page.mouse.move(mx, my - i * 8)
                page.wait_for_timeout(16)
            page.mouse.up()
            board.pump(0.5)
            check(f"{name}: dragging the EQ point raises the mid", board.state["inputs"][0]["fx"]["midDb"] > fx["midDb"] + 3,
                  board.state["inputs"][0]["fx"]["midDb"])
            shot("eq-dragged")
            page.click(".reset")
            board.pump(0.4)
            check(f"{name}: reset flattens", board.state["inputs"][0]["fx"]["midDb"] == 0)

            page.locator(".tabs a").nth(1).click()
            page.wait_for_selector(".stats")
            page.wait_for_timeout(300)
            canvas = page.locator("canvas.graph").bounding_box()
            fx = board.state["inputs"][0]["fx"]
            side = canvas["width"]
            ex, ey = canvas["x"] + side - 2, canvas["y"] + (12 - fx["makeupDb"]) / 72 * side
            page.mouse.move(ex, ey)
            page.mouse.down()
            for i in range(1, 9):
                page.mouse.move(ex, ey + i * 6)
                page.wait_for_timeout(16)
            page.mouse.up()
            board.pump(0.5)
            check(f"{name}: dragging the end point sets a ratio", board.state["inputs"][0]["fx"]["ratio"] > 1.5,
                  board.state["inputs"][0]["fx"]["ratio"])
            shot("comp")
            page.click(".reset")
            board.pump(0.3)
            board.close()

            check(f"{name}: no script errors", not errors, errors[:3])
            ctx.close()
        browser.close()


def main():
    code = passcode()
    board = Phone(role="board", code=code)
    if os.path.exists(SNAPSHOT):
        print("Restoring the board from an earlier run that didn't finish")
        with open(SNAPSHOT) as f:
            restore(board, json.load(f))
    snap = snapshot(board)
    with open(SNAPSHOT, "w") as f:
        json.dump(snap, f)
    snap = json.loads(json.dumps(snap))   # same shape as what restore reads back
    for m in range(7):
        board.send(t="master", mix=m, pos=0)   # silence every output while testing
    board.pump(0.3)
    board.close()   # an idle connection would back up with meters during the long UI run
    try:
        protocol_tests(code)
        if "--ui" in sys.argv:
            shots = sys.argv[sys.argv.index("--shots") + 1] if "--shots" in sys.argv else None
            if shots:
                os.makedirs(shots, exist_ok=True)
            ui_tests(code, shots)
    finally:
        board = Phone(role="board", code=code)
        restore(board, snap)
        # The app works through the restore one message at a time.
        for _ in range(25):
            after = json.loads(json.dumps(snapshot(board)))
            ok = after == snap
            if ok:
                break
        check("board restored to how it was", ok)
        board.close()
        if ok:
            os.remove(SNAPSHOT)
    print("\n%d FAILED" % failures if failures else "\nall passed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
