#!/usr/bin/env node
// render-logo.mjs — Resources/logo.svg → Resources/logo.png + Resources/Flash.icns
//
//   npm i --no-save playwright-core   (once; no browser download needed)
//   node tools/render-logo.mjs        (or: make icon)
//
// Why a browser: the icon is an SVG built on gradients and Gaussian-blur
// filters, and Chromium renders those faithfully; `sips` and Quick Look
// don't. Every icon size is rendered natively from the vector (no
// downscaling from 1024), and the .icns is written directly, so this runs
// on any OS, CI included.
//
// Browser: $CHROMIUM_PATH, else Google Chrome on macOS, else Playwright's
// bundled Chromium.

import { chromium } from "playwright-core";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const svg = readFileSync(join(root, "Resources/logo.svg"), "utf8");

const candidates = [
  process.env.CHROMIUM_PATH,
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/Applications/Chromium.app/Contents/MacOS/Chromium",
  "/opt/pw-browsers/chromium-1194/chrome-linux/chrome",
].filter(Boolean);
const executablePath = candidates.find((p) => existsSync(p));

// icns chunk type → pixel size. PNG payloads in every slot, the layout
// iconutil produces for Retina iconsets.
const ICNS = [
  ["icp4", 16], ["icp5", 32], ["ic11", 32], ["ic12", 64],
  ["ic07", 128], ["ic13", 256], ["ic08", 256], ["ic14", 512],
  ["ic09", 512], ["ic10", 1024],
];

const browser = await chromium.launch({ executablePath });
const page = await browser.newPage();

async function render(size) {
  await page.setViewportSize({ width: size, height: size });
  await page.setContent(
    `<html><body style="margin:0;background:transparent">
       <div style="width:${size}px;height:${size}px">${svg.replace("<svg ", `<svg style="width:${size}px;height:${size}px;display:block" `)}</div>
     </body></html>`,
  );
  // omitBackground keeps the corners transparent (a plain screenshot fills them).
  return page.screenshot({ omitBackground: true, clip: { x: 0, y: 0, width: size, height: size } });
}

const pngs = new Map();
for (const size of new Set(ICNS.map(([, s]) => s))) {
  pngs.set(size, await render(size));
}
await browser.close();

writeFileSync(join(root, "Resources/logo.png"), pngs.get(1024));

// icns: 'icns' + total length, then (type, length incl. 8-byte header, data).
const chunks = ICNS.map(([type, size]) => {
  const data = pngs.get(size);
  const header = Buffer.alloc(8);
  header.write(type, 0, "ascii");
  header.writeUInt32BE(data.length + 8, 4);
  return Buffer.concat([header, data]);
});
const body = Buffer.concat(chunks);
const head = Buffer.alloc(8);
head.write("icns", 0, "ascii");
head.writeUInt32BE(body.length + 8, 4);
writeFileSync(join(root, "Resources/Flash.icns"), Buffer.concat([head, body]));

console.log(`wrote Resources/logo.png and Resources/Flash.icns (${ICNS.length} sizes) via ${executablePath ?? "bundled chromium"}`);
