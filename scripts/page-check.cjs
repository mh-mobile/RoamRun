// view's page against a made-up server: run by scripts/page-check.sh. Each check opens the page anew, with a
// WebSocket that records what the page sends and lets a check say what the server sends, a VideoDecoder that
// records what it is given, and Playwright's clock. Checks look at what is sent and at the page's state, not at
// its wording. With a name (or part of one) as the argument, only those checks run.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { chromium } = require("playwright");

const PAGE = fs.readFileSync(path.join(__dirname, "../Rust/roamrunctl/src/view.html"), "utf8");
const URL = "http://localhost:8099/";

// In the page before its script: the fakes, and what a check uses to play the server.
const FAKES = () => {
  window.__sockets = [];
  class FakeSocket {
    constructor(url) {
      this.url = url; this.readyState = 0; this.sent = [];
      window.__sockets.push(this);
      setTimeout(() => { if (this.readyState === 0) { this.readyState = 1; this.onopen && this.onopen(); } }, 0);
    }
    send(data) { this.sent.push(data); }
    close() { this.readyState = 3; }
  }
  Object.assign(FakeSocket, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 });
  window.WebSocket = FakeSocket;
  window.__decoders = [];
  class FakeDecoder {
    constructor({ output, error }) { this.output = output; this.error = error; this.state = "unconfigured"; this.decoded = []; window.__decoders.push(this); }
    configure(config) { this.state = "configured"; this.config = config; }
    decode(chunk) { this.decoded.push({ type: chunk.type, timestamp: chunk.timestamp }); }
    close() { this.state = "closed"; }
    static isConfigSupported() { return Promise.resolve({ supported: true }); }
  }
  window.VideoDecoder = FakeDecoder;
  window.EncodedVideoChunk = class { constructor(init) { Object.assign(this, init); } };
  const socket = (i) => window.__sockets[i ?? window.__sockets.length - 1];
  window.__says = (message, i) => socket(i).onmessage({ data: JSON.stringify(message) });
  // A frame as view sends it: a flag (1: key), the server's ms (8 bytes), the access unit.
  window.__frame = (key, ms, i) => {
    const data = new ArrayBuffer(9 + 4), view = new DataView(data);
    view.setUint8(0, key ? 1 : 0);
    view.setBigUint64(1, BigInt(ms));
    // As a browser gives it: a Blob unless the page asked for ArrayBuffers.
    const s = socket(i);
    s.onmessage({ data: s.binaryType === "arraybuffer" ? data : new Blob([data]) });
  };
  window.__closes = (code, i) => { const s = socket(i); s.readyState = 3; s.onclose && s.onclose({ code }); };
  window.__sent = (i) => socket(i).sent.map((m) => JSON.parse(m));
  // The decoder's picture for the chunk with this timestamp (µs).
  window.__decoded = (timestamp) => {
    const frame = document.createElement("canvas");
    Object.assign(frame, { width: 10, height: 10, timestamp, displayWidth: 10, displayHeight: 10, close() {} });
    window.__decoders[window.__decoders.length - 1].output(frame);
  };
};

const PICTURE = { type: "picture", codec: "hvc1.1.6.L120.90", width: 400, height: 800, crop: [390, 844] };
// The server's hello and picture, and a key frame decoded: the device's screen shown, on the socket given (the last).
const shown = (page, i) => page.evaluate(([picture, i]) => { __says({ type: "hello" }, i); __says(picture, i); __frame(true, 20, i); __decoded(20000); }, [PICTURE, i]);

const checks = {
  async "says hello with no token, then decodes from a key frame on and acknowledges each frame"(page) {
    assert.deepEqual(await page.evaluate(() => __sent()), [{ type: "hello", token: "" }]);
    await page.evaluate((picture) => { __says({ type: "hello", feedback: true, sound: true }); __says(picture); __frame(false, 10); __frame(true, 20); __frame(false, 30); }, PICTURE);
    const decoder = await page.evaluate(() => ({ config: __decoders.at(-1).config, decoded: __decoders.at(-1).decoded }));
    assert.equal(decoder.config.codec, PICTURE.codec);
    assert.deepEqual(decoder.decoded, [{ type: "key", timestamp: 20000 }, { type: "delta", timestamp: 30000 }]);
    // The delta before the key frame is acknowledged at once; a decoded one once it is.
    assert.deepEqual(await page.evaluate(() => __sent().filter((m) => m.type === "ack")), [{ type: "ack", t: 10 }]);
    await page.evaluate(() => __decoded(20000));
    assert.deepEqual(await page.evaluate(() => __sent().filter((m) => m.type === "ack").map((m) => m.t)), [10, 20]);
    assert.match(await page.getAttribute("#state", "class"), /\blive\b/);
  },

  async "connects again when the server says nothing for 5 s, and not while it speaks each second"(page) {
    for (let i = 0; i < 10; i++) { await page.evaluate(() => __says({ type: "counts" })); await page.clock.runFor(1000); }
    assert.equal(await page.evaluate(() => __sockets.length), 1);
    await page.clock.runFor(7000);
    assert.equal(await page.evaluate(() => __sockets.length), 2);
    assert.equal(await page.evaluate(() => __sockets[0].readyState), 3);
  },

  async "asks for the token when one is needed, keeps it for the session, and forgets one refused"(page) {
    await page.evaluate(() => __closes(1008));
    assert.equal(await page.isVisible("#ask"), true);
    await page.clock.runFor(20000);
    assert.equal(await page.evaluate(() => __sockets.length), 1);
    await page.fill("#tokenInput", "abc");
    await page.press("#tokenInput", "Enter");
    await page.clock.runFor(10);
    assert.deepEqual(await page.evaluate(() => __sent()), [{ type: "hello", token: "abc" }]);
    assert.equal(await page.evaluate(() => sessionStorage.getItem("roamrunctl-token")), "abc");
    await page.evaluate(() => __closes(1008));
    assert.equal(await page.isVisible("#ask"), true);
    assert.equal(await page.inputValue("#tokenInput"), "");
    assert.equal(await page.evaluate(() => sessionStorage.getItem("roamrunctl-token")), null);
  },

  async "gives up with a reason when the decoder fails before any picture, and connects no more"(page) {
    await page.evaluate((picture) => { __says({ type: "hello" }); __says(picture); for (let i = 0; i < 3; i++) __decoders.at(-1).error(new Error("bad")); }, PICTURE);
    assert.match(await page.getAttribute("#state", "class"), /\bdown\b/);
    assert.equal(await page.isVisible("#veil"), true);
    await page.clock.runFor(30000);
    assert.equal(await page.evaluate(() => __sockets.length), 1);
    assert.equal(await page.evaluate(() => __sockets[0].readyState), 3);
  },

  async "asks for a key frame when the decoder fails after a picture"(page) {
    await page.evaluate((picture) => { __says({ type: "hello" }); __says(picture); __frame(true, 20); __decoded(20000); __decoders.at(-1).error(new Error("bad")); }, PICTURE);
    assert.ok((await page.evaluate(() => __sent())).some((m) => m.type === "keyframe"));
    assert.equal(await page.evaluate(() => __sockets.length), 1);
  },

  async "a click taps, a press held taps long, a drag swipes, all in the device's terms"(page) {
    await shown(page);
    const box = await page.locator("#screen").boundingBox();
    const at = (x, y) => [box.x + x * box.width, box.y + y * box.height];
    await page.mouse.move(...at(0.5, 0.25)); await page.mouse.down(); await page.mouse.up();
    await page.mouse.move(...at(0.25, 0.5)); await page.mouse.down(); await page.clock.runFor(800); await page.mouse.up();
    await page.mouse.move(...at(0.5, 0.75)); await page.mouse.down(); await page.mouse.move(...at(0.5, 0.25), { steps: 5 }); await page.clock.runFor(300); await page.mouse.up();
    const inputs = (await page.evaluate(() => __sent())).filter((m) => ["tap", "swipe"].includes(m.type));
    assert.equal(inputs.length, 3, JSON.stringify(inputs));
    const near = (a, b) => Math.abs(a - b) < 0.02;
    assert.ok(inputs[0].type === "tap" && near(inputs[0].x, 0.5) && near(inputs[0].y, 0.25), JSON.stringify(inputs[0]));
    assert.ok(inputs[1].type === "swipe" && near(inputs[1].x1, inputs[1].x2) && near(inputs[1].y1, inputs[1].y2) && inputs[1].ms >= 500, JSON.stringify(inputs[1]));
    assert.ok(inputs[2].type === "swipe" && near(inputs[2].y1, 0.75) && near(inputs[2].y2, 0.25), JSON.stringify(inputs[2]));
  },

  async "keys outside a US keyboard go as one paste, before an input that follows"(page) {
    await shown(page);
    await page.evaluate(() => { for (const key of ["ä", "é"]) document.body.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true })); });
    await page.locator("#screen").click();
    const inputs = (await page.evaluate(() => __sent())).filter((m) => !["hello", "ack"].includes(m.type));
    assert.deepEqual(inputs.slice(0, 2).map((m) => [m.type, m.text]), [["paste", "äé"], ["tap", undefined]]);
  },

  async "no point is sent before this connection's first picture: after a reconnect the older one is shown"(page) {
    await shown(page);
    await page.evaluate(() => __closes(1006));
    await page.clock.runFor(2000);
    assert.equal(await page.evaluate(() => __sockets.length), 2);
    await page.locator("#screen").click({ force: true });
    assert.deepEqual((await page.evaluate(() => __sent())).filter((m) => m.type !== "hello"), []);
    await shown(page);
    await page.locator("#screen").click();
    assert.deepEqual((await page.evaluate(() => __sent())).filter((m) => m.type !== "hello" && m.type !== "ack").map((m) => m.type), ["tap"]);
  },

  async "after a reconnect, a frame the last connection's decoder still gives doesn't count as the screen now"(page) {
    await shown(page);
    await page.evaluate(() => __frame(true, 30));   // given to the decoder, not yet decoded
    await page.evaluate(() => __closes(1006));
    await page.clock.runFor(2000);
    await page.evaluate(() => __decoded(30000));
    await page.locator("#screen").click({ force: true });
    assert.deepEqual((await page.evaluate(() => __sent())).filter((m) => m.type !== "hello"), []);
  },

  async "while the stream starts again, no point is sent until a frame of it is decoded"(page) {
    await shown(page);
    await page.evaluate(() => __says({ type: "status", text: "the stream stopped (no frames for 8 s): starting it again" }));
    await page.locator("#screen").click({ force: true });
    const points = async () => (await page.evaluate(() => __sent())).filter((m) => m.type === "tap").length;
    assert.equal(await points(), 0);
    await page.evaluate(() => { __frame(true, 40); __decoded(40000); });
    await page.locator("#screen").click();
    assert.equal(await points(), 1);
  },

  async "a press begun on a picture that went sends nothing when it lifts"(page) {
    await shown(page);
    const box = await page.locator("#screen").boundingBox();
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    await page.evaluate(() => __closes(1006));
    await page.clock.runFor(2000);
    await shown(page);
    await page.mouse.up();
    assert.deepEqual((await page.evaluate(() => __sent())).filter((m) => ["tap", "swipe", "pinch"].includes(m.type)), []);
  },

  async "Type: a composition goes once chosen, and the Return that chooses it isn't sent"(page) {
    await page.click("#keyboard");
    await page.evaluate(() => {
      const typing = document.getElementById("typing");
      const key = (init) => typing.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true, ...init }));
      typing.dispatchEvent(new CompositionEvent("compositionstart"));
      typing.value = " 日本";
      key({ isComposing: true, keyCode: 229 });                 // Chrome: during the composition
      typing.dispatchEvent(new CompositionEvent("compositionend"));
      key({ isComposing: false, keyCode: 229 });                // Safari: after compositionend
      key({ keyCode: 13 });                                     // a Return of its own
    });
    const inputs = (await page.evaluate(() => __sent())).filter((m) => m.type !== "hello");
    assert.deepEqual(inputs.map((m) => [m.type, m.text]), [["paste", "日本"], ["type", "\n"]]);
  },

  async "what the server says of the device shows: inputs that failed, no sound, an agent's tap, the device gone"(page) {
    await page.evaluate((picture) => { __says({ type: "hello", sound: "decoded on macOS only" }); __says(picture); }, PICTURE);
    assert.equal(await page.isDisabled("#sound"), true);
    await page.evaluate(() => __says({ type: "error", what: "tap", error: "the device didn't take it" }));
    assert.equal(await page.isVisible("#toast"), true);
    await page.evaluate(() => __says({ type: "agent", what: "tap", points: [[0.5, 0.5]] }));
    assert.equal(await page.locator(".press").count(), 1);
    await page.evaluate(() => __says({ type: "status", text: "the connection to the device is gone (x): start view again, with the device connected" }));
    assert.match(await page.getAttribute("#state", "class"), /\bdown\b/);
  },
};

(async () => {
  const only = process.argv[2];
  const browser = await chromium.launch();
  let failed = 0, ran = 0;
  for (const [name, check] of Object.entries(checks)) {
    if (only && !name.includes(only)) continue;
    ran++;
    const context = await browser.newContext();
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    await page.clock.install();
    await page.addInitScript(FAKES);
    await page.route(URL, (route) => route.fulfill({ status: 200, contentType: "text/html; charset=utf-8", body: PAGE }));
    try {
      await page.goto(URL);
      await page.clock.runFor(10);
      await check(page);
      assert.deepEqual(errors, [], "errors in the page");
      console.log(`ok    ${name}`);
    } catch (e) {
      failed++;
      console.log(`FAIL  ${name}\n      ${String(e.message).split("\n").join("\n      ")}`);
    }
    await context.close();
  }
  await browser.close();
  if (!ran) { console.log(`no check is named with “${only}”`); process.exit(1); }
  console.log(failed ? `${failed} failed` : `all ${ran} passed`);
  process.exit(failed ? 1 : 0);
})();
