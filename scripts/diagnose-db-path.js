#!/usr/bin/env node
// diagnose-db-path.js — show the exact LevelDB paths the CLI would create
//
// Usage:  node scripts/diagnose-db-path.js
// Env:    LIVESYNC_VAULT_PATH  path to vault directory

"use strict";

const path = require("node:path");
const fs = require("node:fs");

const VAULT = process.env.LIVESYNC_VAULT_PATH;
if (!VAULT) {
    console.error("Error: LIVESYNC_VAULT_PATH is not set");
    process.exit(1);
}

const SETTINGS_PATH = path.join(VAULT, ".livesync", "settings.json");
if (!fs.existsSync(SETTINGS_PATH)) {
    console.error(`Error: settings not found at ${SETTINGS_PATH}`);
    process.exit(1);
}

const settings = JSON.parse(fs.readFileSync(SETTINGS_PATH, "utf8"));

// ── Reproduce deriveSystemVaultName logic ─────────────────────────────────
function hash32(str) {
    // djb2 variant used by livesync-commonlib
    let h = 5381;
    for (let i = 0; i < str.length; i++) {
        h = ((h << 5) + h) ^ str.charCodeAt(i);
        h = h >>> 0; // keep 32-bit unsigned
    }
    return h.toString(16).padStart(8, "0");
}

// Normalise separators the same way the plugin does
const normalised = VAULT.replace(/\\/g, "/");
const leaf = path.basename(normalised);
const vaultHash = hash32(normalised);
const baseName = `${leaf}-${vaultHash}`;

const suffixFromSettings = settings.additionalSuffixOfDatabaseName || "";
const SUFFIX_DB_NAME = "-livesync-v2";

// The raw name passed to PouchDB
const rawName = `${baseName}${suffixFromSettings}${SUFFIX_DB_NAME}`;

// After the NodeDatabaseService safeName fix
const safeName = rawName.replace(/[/\\]/g, "-");

// Prefix (after the .livesync/ fix)
const prefix = path.join(VAULT, ".livesync") + path.sep;

console.log("=== LiveSync DB path diagnosis ===");
console.log();
console.log("Vault:", VAULT);
console.log("Vault leaf:", leaf);
console.log("Vault hash:", vaultHash);
console.log("additionalSuffixOfDatabaseName:", JSON.stringify(suffixFromSettings));
console.log();
console.log("Raw DB name  :", rawName);
console.log("Safe DB name :", safeName);
console.log();
console.log("Prefix (fixed):", prefix);
console.log();
console.log("Final LevelDB directory:");
console.log(" ", path.join(prefix, safeName));
console.log();

// ── Problem detection ────────────────────────────────────────────────────
let problems = 0;

if (/[/\\]/.test(suffixFromSettings)) {
    console.error("!!! PROBLEM: additionalSuffixOfDatabaseName contains path separators.");
    console.error("    Raw path would have been:", path.join(prefix, rawName));
    console.error("    LevelDB would fail because intermediate directories do not exist.");
    console.error("    Fix: run scripts/sanitize-settings.sh — it will reset to \"headless-app\".");
    problems++;
}

if (settings.useIndexedDBAdapter === true) {
    console.error("!!! PROBLEM: useIndexedDBAdapter is true (browser-only, incompatible with Node.js).");
    console.error("    Fix: run scripts/sanitize-settings.sh — it will patch to false.");
    problems++;
}

if (!settings.isConfigured) {
    console.warn("!!! WARNING: isConfigured is not true — have you applied the setup URI?");
    problems++;
}

if (problems === 0) {
    console.log("No problems detected.");
}
