#!/usr/bin/env node
"use strict";

const childProcess = require("child_process");
const fs = require("fs");
const path = require("path");

function removeNmsshFromPodsJson(podsJsonPath) {
  if (!fs.existsSync(podsJsonPath)) {
    return false;
  }

  const pods = JSON.parse(fs.readFileSync(podsJsonPath, "utf8"));
  if (!pods.libraries || !pods.libraries.NMSSH) {
    return false;
  }

  delete pods.libraries.NMSSH;
  fs.writeFileSync(podsJsonPath, `${JSON.stringify(pods, null, 4)}\n`);
  return true;
}

function removeNmsshFromPodfile(podfilePath) {
  if (!fs.existsSync(podfilePath)) {
    return false;
  }

  const before = fs.readFileSync(podfilePath, "utf8");
  const after = before.replace(/\n\s*pod ['"]NMSSH['"]\s*\n/g, "\n");
  if (after === before) {
    return false;
  }

  fs.writeFileSync(podfilePath, after);
  return true;
}

function main() {
  const projectRoot = process.cwd();
  const iosRoot = path.join(projectRoot, "platforms/ios");
  const podsJsonPath = path.join(iosRoot, "pods.json");
  const podfilePath = path.join(iosRoot, "Podfile");

  if (!fs.existsSync(iosRoot)) {
    console.log("SFTP NMSSH hook: no iOS platform found, skipping.");
    return;
  }

  const changedPodsJson = removeNmsshFromPodsJson(podsJsonPath);
  const changedPodfile = removeNmsshFromPodfile(podfilePath);

  if (!changedPodsJson && !changedPodfile) {
    console.log("SFTP NMSSH hook: NMSSH pod already removed.");
    return;
  }

  const result = childProcess.spawnSync("pod", ["install"], {
    cwd: iosRoot,
    encoding: "utf8",
    stdio: "pipe",
  });

  if (result.status !== 0) {
    process.stdout.write(result.stdout || "");
    process.stderr.write(result.stderr || "");
    throw new Error("SFTP NMSSH hook: pod install failed after removing NMSSH.");
  }

  console.log("SFTP NMSSH hook: removed NMSSH pod and regenerated Pods project.");
}

main();
