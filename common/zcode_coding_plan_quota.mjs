#!/usr/bin/env node
// Fetch normalized Z.ai Coding Plan quotas without printing credentials.

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

function parseArgs(argv) {
  const result = { home: os.homedir(), username: os.userInfo().username, platform: process.platform };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--home") result.home = argv[++index];
    else if (arg === "--username") result.username = argv[++index];
    else if (arg === "--platform") result.platform = argv[++index];
    else if (arg === "--credentials") result.credentials = argv[++index];
    else throw new Error(`unknown argument: ${arg}`);
  }
  result.credentials ||= path.join(result.home, ".zcode", "v2", "credentials.json");
  return result;
}

function createDecryptor(options) {
  const secret = process.env.ZCODE_CREDENTIAL_SECRET
    || `zcode-credential-fallback:${options.platform}:${options.home}:${options.username}`;
  const key = crypto.createHash("sha256").update(secret).digest();
  return (value) => {
    if (!value.startsWith("enc:v1:")) return value;
    const segments = value.slice("enc:v1:".length).split(".");
    if (segments.length !== 3) throw new Error("invalid encrypted credential format");
    const [ivText, tagText, dataText] = segments;
    const decipher = crypto.createDecipheriv("aes-256-gcm", key, Buffer.from(ivText, "base64url"));
    decipher.setAuthTag(Buffer.from(tagText, "base64url"));
    return Buffer.concat([
      decipher.update(Buffer.from(dataText, "base64url")),
      decipher.final(),
    ]).toString("utf8");
  };
}

function readCredential(record, decrypt, predicate, label) {
  const entry = Object.entries(record).find(([name]) => predicate(name));
  if (!entry) throw new Error(`${label} credential not found`);
  return decrypt(entry[1]);
}

async function getJson(url, headers) {
  const response = await fetch(url, { headers, signal: AbortSignal.timeout(15000) });
  const text = await response.text();
  let body;
  try { body = JSON.parse(text); } catch { throw new Error(`${url}: invalid JSON response`); }
  if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`);
  return body;
}

function windowName(item) {
  if (item.unit === 3 && item.number === 5) return "five_hour";
  if (item.unit === 6 && item.number === 1) return "weekly";
  return `unit_${item.unit ?? "unknown"}_x${item.number ?? "unknown"}`;
}

function status(percentage) {
  if (percentage >= 95) return "critical";
  if (percentage >= 85) return "high";
  if (percentage >= 70) return "warning";
  return "ok";
}

function normalizeLimit(item, observedAt) {
  const limit = Number(item.usage ?? 0);
  const used = Number(item.currentValue ?? 0);
  const remaining = Number(item.remaining ?? Math.max(0, limit - used));
  const usedPercent = Number(item.percentage ?? (limit > 0 ? used / limit * 100 : 0));
  return {
    provider: "zcode",
    kind: "coding_plan",
    name: windowName(item),
    model: null,
    meter: item.type ?? "CREDIT_LIMIT",
    unit: "credit",
    window: windowName(item),
    used,
    limit,
    remaining,
    used_percent: usedPercent,
    status: status(usedPercent),
    resets_at: item.nextResetTime ? Math.floor(Number(item.nextResetTime) / 1000) : null,
    observed_at: observedAt,
    source: "zcode-live-api",
    raw_unit: item.unit ?? null,
    raw_number: item.number ?? null,
  };
}

function normalizeMcp(data, observedAt) {
  const usage = data?.total_usage;
  if (!usage || !(Number(usage.limit) > 0)) return null;
  const used = Number(usage.used ?? 0);
  const limit = Number(usage.limit);
  const remaining = Number(usage.remaining ?? Math.max(0, limit - used));
  const percentage = limit > 0 ? used / limit * 100 : 0;
  const serverTime = Number(data.server_time ?? observedAt);
  const next = Number(data.next_refresh_at ?? 0);
  const delta = next > serverTime ? next - serverTime : 0;
  const window = delta >= 27 * 86400 ? "monthly" : delta >= 6 * 86400 ? "weekly" : "daily";
  return {
    provider: "zcode",
    kind: "mcp",
    name: "official-mcp",
    model: null,
    meter: "mcp_usage",
    unit: "request",
    window,
    used,
    limit,
    remaining,
    used_percent: Math.round(percentage * 100) / 100,
    status: status(percentage),
    resets_at: next || null,
    observed_at: observedAt,
    source: "zcode-live-api",
    plan_level: data.level ?? null,
  };
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const record = JSON.parse(fs.readFileSync(options.credentials, "utf8"));
  const decrypt = createDecryptor(options);
  const planKey = readCredential(
    record,
    decrypt,
    (name) => name.startsWith("account-provider:coding-plan:account:zai-individual-coding-plan:")
      && name.endsWith(":api-key"),
    "Coding Plan API key",
  );
  const zcodeJwt = readCredential(record, decrypt, (name) => name === "zcodejwttoken", "ZCode JWT");
  const zaiToken = readCredential(record, decrypt, (name) => name === "oauth:zai:access_token", "Z.ai OAuth");

  const [quotaEnvelope, mcpEnvelope] = await Promise.all([
    getJson("https://api.z.ai/api/monitor/usage/quota/limit", { authorization: planKey }),
    getJson("https://zcode.z.ai/api/v1/mcp/usage", {
      authorization: /^Bearer\s/i.test(zcodeJwt) ? zcodeJwt : `Bearer ${zcodeJwt}`,
      "X-Bigmodel-Authorization": /^Bearer\s/i.test(zaiToken) ? zaiToken : `Bearer ${zaiToken}`,
      "Bigmodel-Target-Type": "PERSONAL",
    }),
  ]);
  if (!(quotaEnvelope?.success && [0, 200].includes(quotaEnvelope.code))) {
    throw new Error("Coding Plan quota API returned a business error");
  }
  const observedAt = Math.floor(Date.now() / 1000);
  const planData = quotaEnvelope.data ?? {};
  const buckets = (planData.limits ?? []).map((item) => normalizeLimit(item, observedAt));
  const mcp = normalizeMcp(mcpEnvelope?.data, observedAt);
  if (mcp) buckets.push(mcp);
  const level = String(planData.level ?? mcpEnvelope?.data?.level ?? "").trim().toLowerCase() || null;
  console.log(JSON.stringify({
    schema_version: 1,
    generated_at: observedAt,
    buckets,
    plans: level ? [{
      provider: "zcode",
      plan_id: "coding-plan",
      name: `Coding Plan ${level.toUpperCase()}`,
      status: "active",
      level,
      observed_at: observedAt,
      source: "zcode-live-api",
    }] : [],
  }, null, 2));
}

main().catch((error) => {
  console.error(`zcode quota fetch failed: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
});
