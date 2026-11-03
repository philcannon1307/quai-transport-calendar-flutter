// Crewdle build contract shim for a Flutter app.
// The runner has no Dart SDK, so we provision Flutter (git clone), run the unit
// tests as a gate, compile Flutter Web, and copy build/web into dist/.
//
// NOTE: do NOT pipe commands through `tail` here. A pipe makes the shell report
// tail's exit status, which silently turned a failed web compile into "OK" and
// cost a build cycle. Capture output in JS instead.
const { execSync } = require("node:child_process");
const fs = require("node:fs");
const FL = "/tmp/flutter-sdk";
const ENV = { ...process.env, PATH: FL + "/bin:" + process.env.PATH, FLUTTER_SUPPRESS_ANALYTICS: "true", CI: "true", HOME: "/tmp" };

function lastLines(s, n) {
  return String(s || "").trimEnd().split("\n").slice(-n).join("\n");
}

function stage(label, cmd, ms, tailLines) {
  const t0 = Date.now();
  console.log("[flutter] >>> " + label);
  try {
    const out = execSync(cmd, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: ms, maxBuffer: 1 << 28, env: ENV });
    console.log("[flutter] <<< " + label + " OK " + ((Date.now() - t0) / 1000).toFixed(1) + "s");
    const t = lastLines(out, tailLines || 6);
    if (t) console.log(t);
    return out;
  } catch (e) {
    console.log("[flutter] <<< " + label + " FAILED " + ((Date.now() - t0) / 1000).toFixed(1) + "s");
    console.error("----- stdout (last 120 lines) -----");
    console.error(lastLines(e.stdout, 120));
    console.error("----- stderr (last 120 lines) -----");
    console.error(lastLines(e.stderr, 120));
    throw new Error(label + " failed");
  }
}

const t0 = Date.now();
if (!fs.existsSync(FL + "/bin/flutter")) {
  stage("provision flutter stable", "rm -rf " + FL + " && git clone --depth 1 -b stable https://github.com/flutter/flutter.git " + FL, 420000, 2);
}
stage("flutter --version", "flutter --version", 420000, 3);
stage("pub get", "flutter pub get", 420000, 8);
// Static analysis first: it names every error at once, instead of one per build.
// Fatal on errors by design: analyze names every compile error at once in ~20s,
// where `build web` spends ~70s and reports one. Warnings/infos stay non-fatal.
stage("analyze", "flutter analyze --no-fatal-infos --no-fatal-warnings", 420000, 80);
// Tests gate the build: a red test must not deploy.
stage("flutter test (gate)", "flutter test --reporter compact", 600000, 40);
stage("build web --release", "flutter build web --release", 900000, 30);

if (!fs.existsSync("build/web/index.html")) {
  console.error("[flutter] build/web contents: " + (fs.existsSync("build/web") ? fs.readdirSync("build/web").join(", ") : "(no build/web)"));
  throw new Error("flutter build web produced no index.html");
}
fs.rmSync("dist", { recursive: true, force: true });
fs.mkdirSync("dist", { recursive: true });
execSync("cp -r build/web/. dist/", { encoding: "utf8" });
if (!fs.existsSync("dist/index.html") || !fs.existsSync("dist/main.dart.js")) {
  console.error("[flutter] dist contents: " + fs.readdirSync("dist").join(", "));
  throw new Error("dist/ missing Flutter web output");
}
console.log("[flutter] dist ready in " + ((Date.now() - t0) / 1000).toFixed(1) + "s total");
