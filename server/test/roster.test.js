import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { CARRIERS, allAccounts, loadableLinked, LOGISTIQUE } from "../src/roster.js";

const DART = fileURLToPath(new URL("../../lib/data/carriers.dart", import.meta.url));

test("roster matches lib/data/carriers.dart (the Flutter app) exactly", { skip: !existsSync(DART) && "Dart source not in this checkout" }, () => {
  const src = readFileSync(DART, "utf8").replaceAll("displayName: kLogistique", 'displayName: "SADM - Logistique"');
  const dartCarriers = [...src.matchAll(/Carrier\(\s*displayName: "([^"]+)",\s*group: "([^"]+)",\s*truck: "(\d+)"/g)]
    .map((m) => [m[1], m[2], m[3]].join("|"));
  const dartLinked = [...src.matchAll(/LinkedTruck\(displayName: "([^"]+)", truck: "(\d+)"\)/g)].map((m) => m[1] + "|" + m[2]);
  const jsCarriers = CARRIERS.map((c) => [c.displayName, c.group, c.truck].join("|"));
  const jsLinked = CARRIERS.flatMap((c) => (c.linkedTrucks ?? []).map((t) => t.displayName + "|" + t.truck));
  assert.deepEqual([...jsCarriers].sort(), [...dartCarriers].sort());
  assert.deepEqual([...jsLinked].sort(), [...dartLinked].sort());
  const dartBackend = [...src.matchAll(/displayName: "([^"]+)",\s*group: "[^"]+",\s*truck: "\d+",\s*backendUsername: "([^"]+)"/g)].map((m) => m[1] + ">" + m[2]);
  const jsBackend = CARRIERS.filter((c) => c.backendUsername).map((c) => c.displayName + ">" + c.backendUsername);
  assert.deepEqual(jsBackend.sort(), dartBackend.sort());
});

test("InterQL is trucks 3 and 4; Logistique only loads the Gooseneck trucks", () => {
  const iql = CARRIERS.find((c) => c.displayName === "InterQL");
  assert.equal(iql.backendUsername, "RIDEAU GOOSENECK");
  assert.deepEqual(iql.linkedTrucks.map((t) => t.truck), ["4"]);
  const log = CARRIERS.find((c) => c.displayName === LOGISTIQUE);
  assert.deepEqual(loadableLinked(log).map((t) => t.displayName), ["RIDEAU GOOSENECK", "OPEN GOOSENECK"]);
});

test("allAccounts has one entry per backend username", () => {
  const names = allAccounts().map((a) => a.username);
  assert.equal(new Set(names).size, names.length);
  assert.ok(names.includes("OPEN GOOSENECK") && names.includes("RIDEAU GOOSENECK") && names.includes("SADM - David"));
  assert.ok(!names.includes("InterQL") && !names.includes(LOGISTIQUE), "login names that are not backend accounts");
});
