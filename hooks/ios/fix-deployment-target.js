#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");

const MIN_DEPLOYMENT_TARGET = "15.0";

function isLowerVersion(value, minimum) {
  const current = value.split(".").map((part) => Number(part));
  const target = minimum.split(".").map((part) => Number(part));
  const length = Math.max(current.length, target.length);

  for (let index = 0; index < length; index += 1) {
    const currentPart = current[index] || 0;
    const targetPart = target[index] || 0;

    if (currentPart < targetPart) return true;
    if (currentPart > targetPart) return false;
  }

  return false;
}

function patchFile(filePath, patcher) {
  if (!fs.existsSync(filePath)) return false;

  const before = fs.readFileSync(filePath, "utf8");
  const after = patcher(before);

  if (after === before) return false;

  fs.writeFileSync(filePath, after);
  return true;
}

function patchPbxproj(contents) {
  return contents.replace(
    /IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+);/g,
    (match, version) => {
      if (!isLowerVersion(version, MIN_DEPLOYMENT_TARGET)) return match;
      return `IPHONEOS_DEPLOYMENT_TARGET = ${MIN_DEPLOYMENT_TARGET};`;
    },
  );
}

function patchPodfile(contents) {
  return contents.replace(
    /^platform :ios, ['"][0-9.]+['"]$/m,
    `platform :ios, '${MIN_DEPLOYMENT_TARGET}'`,
  );
}

function main() {
  const projectRoot = process.cwd();
  const iosPath = path.join(projectRoot, "platforms", "ios");

  if (!fs.existsSync(iosPath)) {
    console.log("iOS deployment target hook: no iOS platform found, skipping.");
    return;
  }

  const files = [
    {
      path: path.join(iosPath, "Podfile"),
      patcher: patchPodfile,
    },
    {
      path: path.join(iosPath, "App.xcodeproj", "project.pbxproj"),
      patcher: patchPbxproj,
    },
    {
      path: path.join(iosPath, "Pods", "Pods.xcodeproj", "project.pbxproj"),
      patcher: patchPbxproj,
    },
  ];

  const changed = files
    .filter((entry) => patchFile(entry.path, entry.patcher))
    .map((entry) => path.relative(projectRoot, entry.path));

  if (changed.length) {
    console.log(
      `iOS deployment target hook: set generated targets to ${MIN_DEPLOYMENT_TARGET}: ${changed.join(", ")}`,
    );
  } else {
    console.log(`iOS deployment target hook: generated targets already >= ${MIN_DEPLOYMENT_TARGET}.`);
  }
}

main();
