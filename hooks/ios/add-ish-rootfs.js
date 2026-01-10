#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");

function copyDir(src, dest) {
  if (!fs.existsSync(src)) return;
  fs.mkdirSync(dest, { recursive: true });
  for (const entry of fs.readdirSync(src)) {
    const srcPath = path.join(src, entry);
    const destPath = path.join(dest, entry);
    const stat = fs.statSync(srcPath);
    if (stat.isDirectory()) {
      copyDir(srcPath, destPath);
    } else {
      fs.copyFileSync(srcPath, destPath);
    }
  }
}

function main() {
  const projectRoot = process.cwd();
  const iosPath = path.join(projectRoot, "platforms", "ios");
  if (!fs.existsSync(iosPath)) {
    console.log("iSH rootfs hook: no iOS platform found, skipping.");
    return;
  }

  const appDir = fs.readdirSync(iosPath).find((name) => name.endsWith(".xcodeproj"));
  if (!appDir) {
    console.log("iSH rootfs hook: no Xcode project found, skipping.");
    return;
  }

  const appName = appDir.replace(/\.xcodeproj$/, "");
  const srcRootfs = path.join(projectRoot, "src", "ios", "ish-rootfs");
  const destRootfs = path.join(iosPath, appName, "ish-rootfs");

  if (!fs.existsSync(srcRootfs)) {
    console.log("iSH rootfs hook: src/ios/ish-rootfs not found, skipping.");
    return;
  }

  copyDir(srcRootfs, destRootfs);
  console.log("iSH rootfs hook: copied rootfs to", destRootfs);
}

main();
