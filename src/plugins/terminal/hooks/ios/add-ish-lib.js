#!/usr/bin/env bun
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
  const guestArch = process.env.ISH_GUEST_ARCH || "arm64";
  if (guestArch !== "arm64") {
    throw new Error(`iSH hook: the supported iOS runtime requires arm64 (got: ${guestArch})`);
  }
  const sourceDir = process.env.ISH_SOURCE_DIR || path.join(projectRoot, "third_party", "ish-arm64");
  const buildRoot = process.env.ISH_OUTPUT_DIR || path.join(sourceDir, "build");
  const sdkBuilds = {
    "iphoneos*": path.join(buildRoot, `Release-${guestArch}-iphoneos`),
    "iphonesimulator*": path.join(buildRoot, `Release-${guestArch}-iphonesimulator`),
  };
  const libNames = [
    "libarchive.a",
    path.join("meson", "libish.a"),
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

  const commonFlags = [];

  let pbxproj = fs.readFileSync(pbxprojPath, "utf8");
  for (const obsoleteFlag of ["-Wl,-ld_classic", "-sectalign", "__DATA", "__percpu_first", "1000", "__tracepoints", "20"]) {
    const escaped = obsoleteFlag.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    pbxproj = pbxproj.replace(new RegExp(`\\n\\s*\"?${escaped}\"?,`, "g"), "");
  }
  const headerSearchPath = quotePbx(sourceDir);
  pbxproj = pbxproj.replace(/HEADER_SEARCH_PATHS = \(([^;]*?)\);/g, (match, body) => {
    if (body.includes(sourceDir)) return match;
    return match.replace(/\n\s*\);$/, `\n\t\t\t\t\t${headerSearchPath},\n\t\t\t\t);`);
  });
  pbxproj = pbxproj.replace(/HEADER_SEARCH_PATHS = ([^;(][^;]*);/g, (match, value) => {
    if (value.includes(sourceDir)) return match;
    return `HEADER_SEARCH_PATHS = (${value.trim()}, ${headerSearchPath});`;
  });
  if (!/HEADER_SEARCH_PATHS\s*=/.test(pbxproj)) {
    const appBundleMarker = 'PRODUCT_BUNDLE_IDENTIFIER = "com.foxdebug.acodeios";';
    pbxproj = pbxproj.replaceAll(
      appBundleMarker,
      `HEADER_SEARCH_PATHS = ("$(inherited)", ${headerSearchPath});\n\t\t\t\t${appBundleMarker}`,
    );
  }
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
      "-lresolv",
      "-lsqlite3",
      "-lbz2",
      "-liconv",
      "-llzma",
      "-lz",
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
  console.log(`iSH hook: linked supported userspace iSH ${guestArch} archives from ${buildRoot}.`);
}

main();
