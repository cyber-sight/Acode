#!/usr/bin/env node

/**
 * Acode Dev Orchestrator
 *
 * Starts:
 *   1. HTTP static file server (serves www/) + WebSocket reload relay (same port)
 *   2. rspack --watch with DEV_MODE enabled
 *   3. cordova run android (after first successful compilation)
 *   4. File watcher on src/plugins/ for auto plugin reinstall
 *
 * The app loads boot.js from the APK assets; boot.js detects DEV_MODE and
 * fetches the latest main.js / main.css from the dev server over HTTP.
 * A WebSocket connection from the app receives "reload" messages on recompile.
 */

const { spawn, execSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const https = require("node:https");
const net = require("node:net");
const { WebSocketServer } = require("ws");
const os = require("node:os");

// ─── helpers ────────────────────────────────────────────────────────────────

const ROOT = path.resolve(__dirname, "../..");
const WWW = path.join(ROOT, "www");
const PLUGINS = path.join(ROOT, "src", "plugins");
const CORDOVA_BIN = path.join(
  ROOT,
  "node_modules",
  "cordova",
  "bin",
  "cordova",
);
const MIME = {
  ".html": "text/html",
  ".js": "application/javascript",
  ".mjs": "application/javascript",
  ".css": "text/css",
  ".json": "application/json",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
  ".map": "application/json",
};

function getCliValue(args, name) {
  const prefix = `--${name}=`;
  const match = args.find((arg) => arg.startsWith(prefix));
  return match ? match.slice(prefix.length) : null;
}

function isPrivateIPv4(address) {
  const parts = address.split(".").map(Number);
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part))) {
    return false;
  }

  const [first, second] = parts;
  return (
    first === 10 ||
    (first === 172 && second >= 16 && second <= 31) ||
    (first === 192 && second === 168)
  );
}

function getInterfaceAddresses() {
  const interfaces = os.networkInterfaces();
  const addresses = [];
  for (const [name, iface] of Object.entries(interfaces)) {
    if (!iface) continue;
    for (const addr of iface) {
      if (addr.family === "IPv4" && !addr.internal) {
        addresses.push({ name, address: addr.address });
      }
    }
  }
  return addresses;
}

function getDefaultRouteInterface() {
  if (process.platform !== "darwin") return null;

  try {
    const output = execSync("route -n get default", {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    const match = /^\s*interface:\s*(\S+)/m.exec(output);
    return match?.[1] || null;
  } catch (_e) {
    return null;
  }
}

function getLocalIP(preferredHost = null) {
  if (preferredHost) return preferredHost;

  const addresses = getInterfaceAddresses();
  const defaultInterface = getDefaultRouteInterface();

  if (defaultInterface) {
    const routeAddress = addresses.find(
      (entry) =>
        entry.name === defaultInterface && isPrivateIPv4(entry.address),
    );
    if (routeAddress) return routeAddress.address;
  }

  for (const entry of addresses) {
    if (isPrivateIPv4(entry.address)) {
      return entry.address;
    }
  }

  if (addresses.length) {
    return addresses[0].address;
  }

  return "127.0.0.1";
}

function logInterfaceAddresses(selectedHost) {
  const addresses = getInterfaceAddresses();
  if (!addresses.length) {
    log("warn", "No non-internal IPv4 addresses found");
    return;
  }

  log(
    "info",
    `Candidate IPs: ${addresses
      .map((entry) => `${entry.address} (${entry.name})`)
      .join(", ")}`,
  );
  if (!isPrivateIPv4(selectedHost)) {
    log(
      "warn",
      `${selectedHost} is not an RFC1918 private LAN address. If the phone cannot load assets, rerun with --host=<reachable-ip>.`,
    );
  }
}

function getFreePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.listen(0, () => {
      const port = server.address().port;
      server.close(() => resolve(port));
    });
    server.on("error", reject);
  });
}

function log(label, msg) {
  const reset = "\x1b[0m";
  const green = "\x1b[92m";
  const yellow = "\x1b[93m";
  const blue = "\x1b[94m";
  const colors = { info: blue, ok: green, warn: yellow };
  const c = colors[label] || reset;
  console.log(`  ${c}[${label}]${reset} ${msg}`);
}

function resolveSpawnCommand(command) {
  if (process.platform !== "win32") return command;
  const lower = command.toLowerCase();
  if (lower.endsWith(".cmd") || lower.endsWith(".exe")) return command;
  if (lower === "cordova" || lower === "npx" || lower === "npm") {
    return `${command}.cmd`;
  }
  return command;
}

function buildSpawnEnv(extra = {}) {
  const merged = { ...process.env, ...extra };
  const sanitized = {};

  for (const [key, value] of Object.entries(merged)) {
    if (!key || key.startsWith("=") || value === undefined) continue;
    sanitized[key] = String(value);
  }

  return sanitized;
}

function spawnAsync(command, args, options) {
  return new Promise((resolve, reject) => {
    const mergedOptions = {
      stdio: "inherit",
      ...options,
      env: options?.env ? buildSpawnEnv(options.env) : options?.env,
    };
    const useLocalCordova = command === "cordova" && fs.existsSync(CORDOVA_BIN);
    const proc = useLocalCordova
      ? spawn(process.execPath, [CORDOVA_BIN, ...args], mergedOptions)
      : spawn(resolveSpawnCommand(command), args, mergedOptions);
    proc.on("close", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`${command} exited with code ${code}`));
    });
    proc.on("error", reject);
  });
}

// ─── self-signed certificate ─────────────────────────────────────────────────

let _cachedCert = null;

function getDevCert() {
  if (_cachedCert) return _cachedCert;

  const certPath = path.join(ROOT, ".dev-cert.pem");
  const keyPath = path.join(ROOT, ".dev-key.pem");

  // Reuse existing cert if available
  if (fs.existsSync(certPath) && fs.existsSync(keyPath)) {
    _cachedCert = {
      cert: fs.readFileSync(certPath),
      key: fs.readFileSync(keyPath),
    };
    return _cachedCert;
  }

  // Generate via openssl (available on macOS, Linux, and Git Bash on Windows)
  try {
    execSync(
      `openssl req -x509 -newkey rsa:2048 -keyout "${keyPath}" -out "${certPath}" -days 365 -nodes -subj "/CN=acode-dev"`,
      { stdio: "pipe" },
    );
    _cachedCert = {
      cert: fs.readFileSync(certPath),
      key: fs.readFileSync(keyPath),
    };
    log("ok", "Generated self-signed dev certificate");
    return _cachedCert;
  } catch (_e) {
    // openssl not available
  }

  log("warn", "openssl not found — falling back to HTTP");
  return null;
}

// ─── HTTPS + WebSocket server ─────────────────────────────────────────────────

async function createServer(port, forceHttp = false, platformWww = null) {
  const tls = forceHttp ? null : getDevCert();
  let server;

  if (tls) {
    server = https.createServer(tls, (req, res) =>
      handleRequest(req, res, platformWww),
    );
  } else {
    if (forceHttp) {
      log("info", "Using HTTP dev server for this platform");
    } else {
      log("warn", "No TLS certificate — falling back to HTTP");
      log("warn", "Install openssl to enable HTTPS for your dev server");
    }
    const http = require("node:http");
    server = http.createServer((req, res) =>
      handleRequest(req, res, platformWww),
    );
  }

  const wss = new WebSocketServer({ server });

  wss.on("connection", (ws, req) => {
    log("info", `App connected via WebSocket from ${req.socket.remoteAddress}`);
    ws.on("error", () => {});
    ws.on("close", () => {
      log("info", "App WebSocket disconnected");
    });
  });

  return {
    server,
    wss,
    broadcast: (msg) => broadcast(wss, msg),
    isHttps: !!tls,
    protocol: tls ? "https" : "http",
  };
}

function resolveServedFilePath(relative, platformWww) {
  const sourcePath = path.join(WWW, relative);
  if (sourcePath.startsWith(WWW + path.sep) && fs.existsSync(sourcePath)) {
    return sourcePath;
  }

  if (platformWww) {
    const platformPath = path.join(platformWww, relative);
    if (
      platformPath.startsWith(platformWww + path.sep) &&
      fs.existsSync(platformPath)
    ) {
      return platformPath;
    }
  }

  return sourcePath;
}

function handleRequest(req, res, platformWww = null) {
  let urlPath = req.url.split("?")[0];
  if (urlPath === "/") urlPath = "/index.html";
  const relative = path.normalize(urlPath).replace(/^\/+/, "");
  const filePath = resolveServedFilePath(relative, platformWww);
  const isWwwFile = filePath.startsWith(WWW + path.sep) || filePath === WWW;
  const isPlatformFile =
    platformWww &&
    (filePath.startsWith(platformWww + path.sep) || filePath === platformWww);

  if (!isWwwFile && !isPlatformFile) {
    res.writeHead(403);
    res.end("Forbidden");
    return;
  }

  const ext = path.extname(filePath).toLowerCase();
  const contentType = MIME[ext] || "application/octet-stream";

  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404);
      res.end("Not found");
      return;
    }
    res.writeHead(200, {
      "Content-Type": contentType,
      "Access-Control-Allow-Origin": "*",
      "Cache-Control": "no-cache, no-store, must-revalidate",
    });
    res.end(data);
  });
}

function broadcast(wss, message) {
  if (typeof message !== "string") {
    message = JSON.stringify(message);
  }
  log(
    "info",
    `Broadcasting "${message}" to ${wss.clients.size} WebSocket client(s)`,
  );
  for (const client of wss.clients) {
    if (client.readyState === 1) {
      client.send(message);
    }
  }
}

// ─── cordova helpers ─────────────────────────────────────────────────────────

function ensureCordovaFiles(platform) {
  // Copy cordova.js and any other platform_www files into www/
  // so the dev server can serve them when the app redirects to it.
  const platformWww = path.join(ROOT, "platforms", platform, "platform_www");

  if (!fs.existsSync(platformWww)) {
    log(
      "warn",
      `${platform} platform_www not found — skipping cordova file copy`,
    );
    return;
  }

  const files = fs.readdirSync(platformWww);
  for (const file of files) {
    const src = path.join(platformWww, file);
    const dest = path.join(WWW, file);
    if (fs.statSync(src).isFile()) {
      // Don't overwrite index.html
      if (file === "index.html") continue;
      fs.copyFileSync(src, dest);
    }
  }
  log("ok", `Copied ${platform} cordova platform files to www/`);
}

async function launchApp(target, platform, emulator) {
  if (target) {
    log("info", `Launching app on ${target}...`);
  } else {
    log("info", "Launching app...");
  }

  return new Promise((resolve, reject) => {
    const args = ["run", platform];
    if (emulator) args.push("--emulator");
    if (target) args.push("--target", target);
    const useLocalCordova = fs.existsSync(CORDOVA_BIN);
    const proc = useLocalCordova
      ? spawn(process.execPath, [CORDOVA_BIN, ...args], {
          cwd: ROOT,
          stdio: "inherit",
        })
      : spawn(resolveSpawnCommand("cordova"), args, {
          cwd: ROOT,
          stdio: "inherit",
        });

    proc.on("close", (code) => {
      if (code === 0) resolve();
      else
        reject(new Error(`cordova run ${platform} exited with code ${code}`));
    });

    proc.on("error", reject);
  });
}

// ─── rspack watcher ──────────────────────────────────────────────────────────

function startRspackWatch(host, port, proto, onCompiled) {
  log("info", "Starting rspack --watch...");

  const env = buildSpawnEnv({
    DEV_MODE: "true",
    DEV_HOST: host,
    DEV_PORT: String(port),
    DEV_PROTO: proto,
  });
  const rspackBin = path.join(
    ROOT,
    "node_modules",
    "@rspack",
    "cli",
    "bin",
    "rspack.js",
  );

  const useLocalRspack = fs.existsSync(rspackBin);
  if (!useLocalRspack) {
    log("warn", "Local rspack CLI not found, falling back to npx rspack");
  }

  const proc = useLocalRspack
    ? spawn(process.execPath, [rspackBin, "--watch", "--mode", "development"], {
        cwd: ROOT,
        env,
        stdio: "pipe",
      })
    : spawn(
        resolveSpawnCommand("npx"),
        ["rspack", "--watch", "--mode", "development"],
        {
          cwd: ROOT,
          env,
          stdio: "pipe",
        },
      );

  let firstCompile = true;

  proc.stdout.on("data", (chunk) => {
    const text = chunk.toString();
    process.stdout.write(text);
    if (text.includes("compiled successfully") || text.includes("compiled")) {
      if (firstCompile) {
        firstCompile = false;
      }
      onCompiled();
    }
  });

  proc.stderr.on("data", (chunk) => {
    process.stderr.write(chunk);
  });

  proc.on("error", (err) => {
    log("warn", `rspack error: ${err.message}`);
    log("warn", "rspack watcher failed to start; exiting dev mode");
    process.exit(1);
  });

  proc.on("close", (code) => {
    if (code !== 0 && code !== null) {
      log("warn", `rspack exited with code ${code}`);
    }
  });

  return proc;
}

// ─── plugin watcher ──────────────────────────────────────────────────────────

let pluginUpdateTimer = null;
const pluginUpdates = new Set();
let pluginPlatform = "android";

function startPluginWatcher(platform) {
  pluginPlatform = platform;
  let chokidar;
  try {
    chokidar = require("chokidar");
  } catch (_e) {
    log("warn", "chokidar not installed — plugin auto-update disabled");
    return;
  }

  if (!fs.existsSync(PLUGINS)) {
    log("warn", "src/plugins/ not found — plugin watcher skipped");
    return;
  }

  const watcher = chokidar.watch(path.join(PLUGINS, "**", "*"), {
    ignored: /(^|[\/\\])\../, // dotfiles
    persistent: true,
    ignoreInitial: true,
    awaitWriteFinish: { stabilityThreshold: 500, pollInterval: 100 },
  });

  watcher.on("change", (filePath) => schedulePluginUpdate(filePath));
  watcher.on("add", (filePath) => schedulePluginUpdate(filePath));
  watcher.on("unlink", (filePath) => schedulePluginUpdate(filePath));

  log("info", "Watching src/plugins/ for changes...");
}

function schedulePluginUpdate(filePath) {
  // Extract top-level plugin dir name from path
  const relative = path.relative(PLUGINS, filePath);
  const pluginDir = relative.split(path.sep)[0];
  if (!pluginDir || pluginDir === "tsconfig.tsbuildinfo") return;

  pluginUpdates.add(pluginDir);

  if (pluginUpdateTimer) clearTimeout(pluginUpdateTimer);
  pluginUpdateTimer = setTimeout(applyPluginUpdates, 2000);
}

async function applyPluginUpdates() {
  if (pluginUpdates.size === 0) return;

  for (const dir of pluginUpdates) {
    const pluginPath = path.join(PLUGINS, dir);
    const pluginXml = path.join(pluginPath, "plugin.xml");

    if (!fs.existsSync(pluginXml)) {
      log("warn", `No plugin.xml in ${dir} — skipping`);
      continue;
    }

    const xml = fs.readFileSync(pluginXml, "utf8");
    const idMatch = /<plugin[^>]*\sid=["']([^"']+)["']/.exec(xml);
    const pluginId = idMatch?.[1];
    if (!pluginId) {
      log("warn", `Could not find plugin id in ${dir}/plugin.xml`);
      continue;
    }

    log("info", `Updating plugin: ${pluginId}`);

    try {
      await spawnAsync("cordova", ["plugin", "remove", pluginId], {
        cwd: ROOT,
      });
    } catch (_e) {
      // Plugin might not be installed yet — that's OK
    }

    try {
      await spawnAsync("cordova", ["plugin", "add", `./src/plugins/${dir}`], {
        cwd: ROOT,
      });
      log("ok", `Plugin ${pluginId} reinstalled`);
    } catch (err) {
      log("warn", `Failed to reinstall plugin ${pluginId}: ${err.message}`);
      continue;
    }
  }

  pluginUpdates.clear();

  // Restart the app after plugin changes (native changes need full restart)
  try {
    const configXml = fs.readFileSync(path.join(ROOT, "config.xml"), "utf8");
    const pkgMatch = /id="([^"]+)"/.exec(configXml);
    const pkg = pkgMatch?.[1];
    if (pkg) {
      log("info", "Restarting app after plugin update...");
      // Need to rebuild APK since native plugin code changed
      await spawnAsync("cordova", ["build", pluginPlatform], {
        cwd: ROOT,
      });
      if (pluginPlatform === "android") {
        await spawnAsync("adb", ["uninstall", pkg], { stdio: "ignore" });
      }
      await spawnAsync("cordova", ["run", pluginPlatform], {
        cwd: ROOT,
      });
    }
  } catch (err) {
    log("warn", `Could not rebuild after plugin update: ${err.message}`);
  }
}

// ─── main ────────────────────────────────────────────────────────────────────

async function main() {
  const args = process.argv.slice(2);
  const platform =
    args.find((a) => /^(android|ios|browser)$/i.test(a)) || "android";
  const target =
    args.find((a) => a.startsWith("--target="))?.split("=")[1] || null;
  const emulator = args.includes("--emulator") || args.includes("-e");
  const hostOverride = getCliValue(args, "host") || process.env.ACODE_DEV_HOST;

  console.log("\n  ⚡ Acode Dev Mode\n");

  const host = getLocalIP(hostOverride);
  const port = 61908 || (await getFreePort());

  logInterfaceAddresses(host);
  log("info", `Local IP:   ${host}`);
  log("info", `Port:       ${port}`);

  // 1. Ensure cordova files are in www/ for the dev server
  ensureCordovaFiles(platform);

  // 2. Start HTTPS (or HTTP fallback) + WebSocket server
  const forceHttp = platform === "ios" || args.includes("--http");
  const platformWww = path.join(ROOT, "platforms", platform, "www");
  const { server, broadcast, protocol } = await createServer(
    port,
    forceHttp,
    fs.existsSync(platformWww) ? platformWww : null,
  );
  const origin = `${protocol}://${host}:${port}`;
  log("info", `Dev Origin: ${origin}`);
  server.listen(port, "0.0.0.0", () => {
    log("ok", "Dev server started");
  });

  // 3. Start rspack --watch
  let appLaunched = false;

  startRspackWatch(host, port, protocol, () => {
    broadcast("reload");

    if (!appLaunched) {
      appLaunched = true;
      setTimeout(async () => {
        try {
          await launchApp(target, platform, emulator);
        } catch (err) {
          log("warn", `Launch failed: ${err.message}`);
        }
      }, 3000); // give APK install time
    }
  });

  // 4. Start plugin file watcher
  startPluginWatcher(platform);

  // Graceful shutdown
  process.on("SIGINT", () => {
    log("info", "Shutting down...");
    server.close();
    process.exit(0);
  });

  process.on("SIGTERM", () => {
    server.close();
    process.exit(0);
  });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
