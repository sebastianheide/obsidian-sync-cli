#!/usr/bin/env node
/**
 * livesync-watch.js — watches CouchDB _changes feed and triggers pull on remote changes
 *
 * Usage:  node livesync-watch.js
 * Env:    LIVESYNC_VAULT_PATH   path to vault directory
 *         LIVESYNC_PULL_DEBOUNCE_MS  debounce window in ms (default: 3000)
 *
 * Long-polls CouchDB _changes endpoint. When remote documents change it runs
 * livesync-pull.sh. Uses exponential back-off on network errors.
 * Stop with Ctrl-C or SIGTERM.
 */

"use strict";

const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const http = require("http");
const https = require("https");

// ── Config ────────────────────────────────────────────────────────────────────

const VAULT = process.env.LIVESYNC_VAULT_PATH;
if (!VAULT) {
    console.error("[livesync-watch] Error: LIVESYNC_VAULT_PATH is not set");
    process.exit(1);
}

const SETTINGS_FILE = path.join(VAULT, ".livesync", "settings.json");
const PULL_SCRIPT = path.join(__dirname, "livesync-pull.sh");
const DEBOUNCE_MS = parseInt(process.env.LIVESYNC_PULL_DEBOUNCE_MS ?? "3000", 10);
const LONG_POLL_TIMEOUT_MS = 30_000;   // how long CouchDB holds the connection open
const REQ_TIMEOUT_MS = LONG_POLL_TIMEOUT_MS + 10_000; // node-side socket timeout
const MAX_RETRY_DELAY_MS = 60_000;
const INITIAL_RETRY_DELAY_MS = 1_000;

// ── Helpers ───────────────────────────────────────────────────────────────────

function log(msg) {
    process.stderr.write(`[livesync-watch] ${new Date().toISOString()} ${msg}\n`);
}

function sleep(ms) {
    return new Promise((r) => setTimeout(r, ms));
}

// ── Settings ──────────────────────────────────────────────────────────────────

let settings;
try {
    settings = JSON.parse(fs.readFileSync(SETTINGS_FILE, "utf8"));
} catch (e) {
    log(`Error: cannot read settings file ${SETTINGS_FILE}: ${e.message}`);
    process.exit(1);
}

const { couchDB_URI, couchDB_USER, couchDB_PASSWORD, couchDB_DBNAME } = settings;

if (!couchDB_URI || !couchDB_DBNAME) {
    log("Error: couchDB_URI and couchDB_DBNAME must be set in settings.json");
    process.exit(1);
}

if (!settings.isConfigured) {
    log("Error: LiveSync is not configured (isConfigured != true)");
    process.exit(1);
}

// Build base URL (credentials embedded so they survive redirects)
const baseUrl = new URL(`${couchDB_URI}/${encodeURIComponent(couchDB_DBNAME)}/_changes`);
if (couchDB_USER) {
    baseUrl.username = couchDB_USER;
    baseUrl.password = couchDB_PASSWORD ?? "";
}

// ── HTTP helper ───────────────────────────────────────────────────────────────

function fetchJSON(urlObj, timeoutMs) {
    return new Promise((resolve, reject) => {
        const lib = urlObj.protocol === "https:" ? https : http;
        const req = lib.get(urlObj.toString(), { timeout: timeoutMs }, (res) => {
            if (res.statusCode >= 400) {
                res.resume();
                return reject(new Error(`HTTP ${res.statusCode} from CouchDB`));
            }
            let raw = "";
            res.on("data", (chunk) => (raw += chunk));
            res.on("end", () => {
                try {
                    resolve(JSON.parse(raw));
                } catch {
                    reject(new Error(`Invalid JSON from CouchDB: ${raw.slice(0, 200)}`));
                }
            });
        });
        req.on("error", reject);
        req.on("timeout", () => {
            req.destroy();
            reject(new Error("Request timed out"));
        });
    });
}

function buildChangesUrl(since, feed) {
    const u = new URL(baseUrl.toString());
    u.searchParams.set("since", String(since));
    u.searchParams.set("feed", feed);
    if (feed === "longpoll") {
        u.searchParams.set("timeout", String(LONG_POLL_TIMEOUT_MS));
        u.searchParams.set("heartbeat", "25000");
    }
    return u;
}

// ── Pull trigger ──────────────────────────────────────────────────────────────

let pulling = false;
let debounceTimer = null;

function schedulePull() {
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(doPull, DEBOUNCE_MS);
}

async function doPull() {
    if (pulling) {
        log("Pull already in progress — will re-run after it finishes.");
        // Re-schedule so the pending changes are picked up once the current pull ends.
        pulling = "pending";
        return;
    }
    pulling = true;
    log("Triggering livesync-pull.sh ...");
    try {
        await new Promise((resolve, reject) => {
            const proc = spawn("bash", [PULL_SCRIPT], {
                stdio: "inherit",
                env: { ...process.env, LIVESYNC_VAULT_PATH: VAULT },
            });
            proc.on("close", (code) =>
                code === 0 ? resolve() : reject(new Error(`Pull exited ${code}`))
            );
            proc.on("error", reject);
        });
        log("Pull complete.");
    } catch (e) {
        log(`Pull error (non-fatal): ${e.message}`);
    } finally {
        const wasPending = pulling === "pending";
        pulling = false;
        if (wasPending) {
            log("Changes arrived during pull — re-scheduling pull.");
            schedulePull();
        }
    }
}

// ── Watch loop ────────────────────────────────────────────────────────────────

async function watchLoop() {
    let retryDelay = INITIAL_RETRY_DELAY_MS;

    // 1. Get current sequence so we only react to *future* changes.
    log(`Vault:   ${VAULT}`);
    log(`CouchDB: ${couchDB_URI}/${couchDB_DBNAME}`);
    log("Fetching initial sequence...");

    let lastSeq;
    while (true) {
        try {
            const initial = await fetchJSON(buildChangesUrl("now", "normal"), REQ_TIMEOUT_MS);
            lastSeq = initial.last_seq;
            log(`Starting from seq: ${lastSeq}`);
            retryDelay = INITIAL_RETRY_DELAY_MS;
            break;
        } catch (e) {
            log(`Cannot reach CouchDB: ${e.message}. Retrying in ${retryDelay / 1000}s...`);
            await sleep(retryDelay);
            retryDelay = Math.min(retryDelay * 2, MAX_RETRY_DELAY_MS);
        }
    }

    // 2. Long-poll loop.
    log("Watching for remote changes (Ctrl-C to stop)...");
    while (true) {
        try {
            const result = await fetchJSON(
                buildChangesUrl(lastSeq, "longpoll"),
                REQ_TIMEOUT_MS
            );

            const changes = result.results ?? [];
            if (result.last_seq) lastSeq = result.last_seq;

            if (changes.length > 0) {
                log(`${changes.length} remote change(s) — scheduling pull (debounce ${DEBOUNCE_MS}ms)...`);
                schedulePull();
            }
            // else: timeout / heartbeat with no results — just loop again

            retryDelay = INITIAL_RETRY_DELAY_MS; // reset on success
        } catch (e) {
            log(`Watch error: ${e.message}. Retrying in ${retryDelay / 1000}s...`);
            await sleep(retryDelay);
            retryDelay = Math.min(retryDelay * 2, MAX_RETRY_DELAY_MS);
        }
    }
}

// ── Signals ───────────────────────────────────────────────────────────────────

process.on("SIGINT", () => { log("SIGINT — shutting down."); process.exit(0); });
process.on("SIGTERM", () => { log("SIGTERM — shutting down."); process.exit(0); });

// ── Run ───────────────────────────────────────────────────────────────────────

watchLoop().catch((e) => {
    log(`Fatal: ${e.message}`);
    process.exit(1);
});
