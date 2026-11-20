// Capture docs/demo/video.html frame by frame with headless Chrome (DevTools protocol,
// no npm packages), then hand the frames to encode.swift to make an MP4 with a chime.
//   node docs/demo/record.mjs            -> docs/images/demo.mp4
// Needs: Google Chrome, Node 22+, Xcode command line tools (swift).
import { spawn, execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const out = join(here, "..", "images", "demo.mp4");
const FPS = 30, W = 1280, H = 720, SCALE = 1.5;   // 1920x1080 output
const chrome = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

const work = mkdtempSync(join(tmpdir(), "nudge-video-"));
const frames = join(work, "frames"); mkdirSync(frames);
const proc = spawn(chrome, ["--headless=new", "--disable-gpu", "--hide-scrollbars", "--no-first-run",
  `--user-data-dir=${join(work, "profile")}`, "--remote-debugging-port=0",
  pathToFileURL(join(here, "video.html")).href], { stdio: ["ignore", "ignore", "pipe"] });

const wsBrowser = await new Promise((res, rej) => {
  let buf = ""; proc.stderr.on("data", d => { buf += d; const m = buf.match(/ws:\/\/[^\s]+/); if (m) res(m[0]); });
  proc.on("exit", () => rej(new Error("chrome exited")));
});
const port = new URL(wsBrowser).port;
let page;
for (let i = 0; i < 50 && !page; i++) {
  const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  page = list.find(t => t.type === "page" && t.url.includes("video.html"));
  if (!page) await new Promise(r => setTimeout(r, 100));
}
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener("open", r, { once: true }));
let id = 0; const pending = new Map();
ws.addEventListener("message", e => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } });
const send = (method, params = {}) => new Promise((res, rej) => {
  const i = ++id; pending.set(i, m => m.error ? rej(new Error(`${method}: ${m.error.message}`)) : res(m.result));
  ws.send(JSON.stringify({ id: i, method, params }));
});

await send("Emulation.setDeviceMetricsOverride", { width: W, height: H, deviceScaleFactor: SCALE, mobile: false });
await send("Runtime.evaluate", { expression: "document.fonts.ready", awaitPromise: true });
const { result } = await send("Runtime.evaluate", { expression: "JSON.stringify(window.DEMO)", returnByValue: true });
const { DURATION, CHIME_AT } = JSON.parse(result.value);

const total = Math.round(DURATION * FPS);
for (let f = 0; f < total; f++) {
  await send("Runtime.evaluate", { expression: `render(${(f / FPS).toFixed(4)})` });
  const shot = await send("Page.captureScreenshot", { format: "png" });
  writeFileSync(join(frames, `f${String(f).padStart(5, "0")}.png`), Buffer.from(shot.data, "base64"));
  if (f % 60 === 0) process.stdout.write(`\rframe ${f}/${total}`);
}
process.stdout.write(`\rcaptured ${total} frames\n`);
ws.close(); proc.kill();

execFileSync("swift", [join(here, "encode.swift"), frames, String(FPS), String(CHIME_AT), out], { stdio: "inherit" });
rmSync(work, { recursive: true, force: true });
console.log(`wrote ${out}`);
