#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");

function findXcodeProj(platformsPath) {
  if (!fs.existsSync(platformsPath)) return null;
  const entries = fs.readdirSync(platformsPath).filter((name) => name.endsWith(".xcodeproj"));
  if (!entries.length) return null;
  return path.join(platformsPath, entries[0], "project.pbxproj");
}

function main() {
  const projectRoot = process.cwd();
  const iosPath = path.join(projectRoot, "platforms", "ios");
  const pbxprojPath = findXcodeProj(iosPath);
  if (!pbxprojPath) {
    console.log("iSH hook: no iOS Xcode project found, skipping.");
    return;
  }

  let xcode;
  try {
    xcode = require("xcode");
  } catch (err) {
    console.log("iSH hook: npm package 'xcode' not installed. Skipping auto-link.\n" +
      "Install dev dependency or link libiSH manually in Xcode.");
    return;
  }

  const libPath = path.join(projectRoot, "third_party", "ish", "build", "Release-iphoneos", "libiSHLinux.a");
  if (!fs.existsSync(libPath)) {
    console.log("iSH hook: libiSHLinux.a not found at", libPath);
    console.log("Build iSH first (scripts/build-ish.sh) or adjust hook path.");
    return;
  }

  const project = xcode.project(pbxprojPath);
  project.parseSync();

  const target = project.getFirstTarget().uuid;
  project.addFile(libPath, "Frameworks", target);
  project.addFramework(libPath, { customFramework: true, embed: false });

  fs.writeFileSync(pbxprojPath, project.writeSync());
  console.log("iSH hook: linked libiSHLinux.a");
}

main();
