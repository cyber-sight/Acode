#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");

function findProjectFile(iosPath) {
  if (!fs.existsSync(iosPath)) return null;
  const projectDir = fs.readdirSync(iosPath).find((entry) => entry.endsWith(".xcodeproj"));
  return projectDir ? path.join(iosPath, projectDir, "project.pbxproj") : null;
}

function quotePbx(value) {
  return `"${value.replace(/"/g, "\\\"")}"`;
}

function main() {
  const projectRoot = process.cwd();
  const buildRoot = path.join(projectRoot, "third_party", "ish", "build");
  const sdkBuilds = {
    "iphoneos*": path.join(buildRoot, "ReleaseLinux-iphoneos"),
    "iphonesimulator*": path.join(buildRoot, "ReleaseLinux-iphonesimulator"),
  };
  const libNames = [
    "libiSHLinux.a",
    "liblinux-acode.a",
    path.join("meson", "liblinux_user.a"),
    path.join("meson", "libish_emu.a"),
    path.join("meson", "libfakefs.a"),
  ];

  const libsBySdk = Object.fromEntries(
    Object.entries(sdkBuilds).map(([sdk, buildDir]) => [
      sdk,
      libNames.map((name) => path.join(buildDir, name)),
    ]),
  );

  const missing = Object.values(libsBySdk).flat().filter((lib) => !fs.existsSync(lib));
  if (missing.length) {
    throw new Error(`iSH hook: native iSH archive(s) missing: ${missing.join(", ")}`);
  }

  const pbxprojPath = findProjectFile(path.join(projectRoot, "platforms", "ios"));
  if (!pbxprojPath || !fs.existsSync(pbxprojPath)) {
    console.log("iSH hook: no iOS Xcode project found, skipping.");
    return;
  }

  const commonFlags = [
    "-Wl,-ld_classic",
    "-sectalign",
    "__DATA",
    "__percpu_first",
    "1000",
    "-sectalign",
    "__DATA",
    "__tracepoints",
    "20",
  ];

  let pbxproj = fs.readFileSync(pbxprojPath, "utf8");
  pbxproj = pbxproj.replace(/OTHER_LDFLAGS = \(([\s\S]*?)\);/g, (match, body) => {
    const additions = commonFlags
      .filter((flag) => !body.includes(flag))
      .map((flag) => `\n\t\t\t\t\t${quotePbx(flag)},`)
      .join("");
    return additions ? match.replace(/\n\s*\);$/, `${additions}\n\t\t\t\t);`) : match;
  });

  for (const [sdk, libs] of Object.entries(libsBySdk)) {
    const key = `OTHER_LDFLAGS[sdk=${sdk}]`;
    const quotedKey = quotePbx(key);
    const flags = [
      "$(inherited)",
      "-ObjC",
      ...commonFlags,
      ...libs.flatMap((lib) => ["-force_load", lib]),
      "-lsqlite3",
      "-lm",
    ];
    const value = `(\n${flags.map((flag) => `\t\t\t\t\t${quotePbx(flag)},`).join("\n")}\n\t\t\t\t)`;
    const setting = `${quotedKey} = ${value};`;
    const escapedKey = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const re = new RegExp(`"?${escapedKey}"? = \\([\\s\\S]*?\\);`, "g");

    if (re.test(pbxproj)) {
      pbxproj = pbxproj.replace(re, setting);
      continue;
    }

    pbxproj = pbxproj.replace(/(OTHER_LDFLAGS = \([\s\S]*?\);\n)/g, `$1\t\t\t\t${setting}\n`);
  }

  fs.writeFileSync(pbxprojPath, pbxproj);
  console.log("iSH hook: linked iSH native archives.");
}

main();
