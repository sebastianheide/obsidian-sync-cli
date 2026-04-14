#!/usr/bin/env node
/**
 * livesync-file-watcher.js — watches vault for file changes and auto-pushes to CouchDB
 *
 * Usage:  node livesync-file-watcher.js
 * Env:    LIVESYNC_VAULT_PATH         path to vault directory
 *         LIVESYNC_PUSH_DEBOUNCE_MS   per-file debounce window in ms (default: 1000)
 *
 * Watches the vault filesystem with chokidar. When a file is written or deleted
 * it runs livesync-push.sh automatically. Suppresses pushes during livesync-pull.sh
 * to avoid an inbound→outbound sync loop.
 *
 * Stop with Ctrl-C or SIGTERM.
 */

"use strict";

const path = require("path");
const fs = require("fs");
const { spawn } = require("child_process");
const chokidar = require("chokidar");

// ── Config ────────────────────────────────────────────────────────────────────

const VAULT = process.env.LIVESYNC_VAULT_PATH;
if (!VAULT) {
    console.error("[livesync-file-watcher] Error: LIVESYNC_VAULT_PATH is not set");
    process.exit(1);
}

const PUSH_SCRIPT = path.join(__dirname, "livesync-push.sh");
const SUPPRESS_FILE = path.join(VAULT, ".livesync", "push-suppressed");
const DEBOUNCE_MS = parseInt(process.env.LIVESYNC_PUSH_DEBOUNCE_MS ?? "1000", 10);

// ── Helpers ───────────────────────────────────────────────────────────────────

function log(msg) {
    process.stderr.write(`[livesync-file-watcher] ${new Date().toISOString()} ${msg}\n`);
}

/**
 * Returns true while livesync-pull.sh is running its mirror step.
 * Pull creates this file before mirror and removes it (with a 3 s tail) after.
 */
function isPullSuppressing() {
    try {
        fs.accessSync(SUPPRESS_FILE);
        return true;
    } catch {
        return false;
    }
}

// ── Push queue ────────────────────────────────────────────────────────────────

// Per-file debounce: path → { timer, isDelete }
const pending = new Map();

function scheduleChange(vaultRelPath, isDelete) {
    const existing = pending.get(vaultRelPath);
    if (existing) {
        clearTimeout(existing.timer);
    }
    const timer = setTimeout(() => {
        pending.delete(vaultRelPath);
        executePush(vaultRelPath, isDelete);
    }, DEBOUNCE_MS);
    pending.set(vaultRelPath, { timer, isDelete });
}

// serialise pushes: never run two push processes concurrently
let pushRunning = false;
const pushQueue = [];

function executePush(vaultRelPath, isDelete) {
    pushQueue.push({ vaultRelPath, isDelete });
    drainQueue();
}

function drainQueue() {
    if (pushRunning || pushQueue.length === 0) return;
    const { vaultRelPath, isDelete } = pushQueue.shift();

    if (isPullSuppressing()) {
        log(`pull in progress — suppressing push for: ${vaultRelPath}`);
        drainQueue();
        return;
    }

    pushRunning = true;
    const args = isDelete
        ? ["--delete", vaultRelPath]
        : [vaultRelPath];

    log(`${isDelete ? "delete" : "push"}  ${vaultRelPath}`);

    const proc = spawn("bash", [PUSH_SCRIPT, ...args], {
        stdio: "inherit",
        env: { ...process.env, LIVESYNC_VAULT_PATH: VAULT },
    });

    proc.on("close", (code) => {
        if (code !== 0) {
            log(`push exited ${code} for ${vaultRelPath} — continuing`);
        }
        pushRunning = false;
        drainQueue();
    });

    proc.on("error", (err) => {
        log(`push spawn error: ${err.message}`);
        pushRunning = false;
        drainQueue();
    });
}

// ── Watcher ───────────────────────────────────────────────────────────────────

const watcher = chokidar.watch(VAULT, {
    // ignore all dot-prefixed files and directories (.livesync/, .git/, etc.)
    // and common editor temp files
    ignored: [
        /(^|[/\\])\../,
        /~$/,
        /\.tmp$/,
        /\.swp$/,
        /\.swx$/,
    ],
    persistent: true,
    ignoreInitial: true,
    // wait for writes to finish before firing (handles atomic rename writes)
    awaitWriteFinish: {
        stabilityThreshold: 500,
        pollInterval: 100,
    },
});

function toVaultRel(absPath) {
    return path.relative(VAULT, absPath);
}

watcher
    .on("add", (absPath) => {
        const rel = toVaultRel(absPath);
        log(`added    ${rel}`);
        scheduleChange(rel, false);
    })
    .on("change", (absPath) => {
        const rel = toVaultRel(absPath);
        log(`changed  ${rel}`);
        scheduleChange(rel, false);
    })
    .on("unlink", (absPath) => {
        const rel = toVaultRel(absPath);
        log(`deleted  ${rel}`);
        scheduleChange(rel, true);
    })
    .on("error", (err) => {
        log(`watcher error: ${err.message}`);
    })
    .on("ready", () => {
        log(`Vault:   ${VAULT}`);
        log(`Watching for file changes (Ctrl-C to stop)...`);
    });

// ── Signals ───────────────────────────────────────────────────────────────────

process.on("SIGINT", () => { log("SIGINT — shutting down."); process.exit(0); });
process.on("SIGTERM", () => { log("SIGTERM — shutting down."); process.exit(0); });
