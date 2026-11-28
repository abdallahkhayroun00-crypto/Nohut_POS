// Fetch-compatible HTTP boundary for Nohut POS Cloud Capabilities v1.
// Authenticates the Windows POS agent via opaque 64-hex x-nohut-agent-token
// and returns strictly boolean capability flags with zero secret material.

import { evaluateCapabilities } from "./capabilities.mjs";

const TOKEN_RE = /^[a-f0-9]{64}$/;
const MAX_POST_BYTES = 128;

function json(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    },
  });
}

async function readBoundedText(req, maxBytes) {
  if (!req.body) return "";
  const reader = req.body.getReader();
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let total = 0;
  let text = "";
  try {
    while (true) {
      const part = await reader.read();
      if (part.done) break;
      total += part.value.byteLength;
      if (total > maxBytes) {
        await reader.cancel();
        return null;
      }
      text += decoder.decode(part.value, { stream: true });
    }
    text += decoder.decode();
    return text;
  } finally {
    reader.releaseLock();
  }
}

export function createCloudCapabilitiesHandler({ env, ports }) {
  if (typeof env !== "function" || !ports || typeof ports.authenticateAgent !== "function") {
    throw new Error("invalid_capabilities_configuration");
  }

  return async function handle(req) {
    if (req.method !== "GET" && req.method !== "POST") {
      return json(405, { error: "method_not_allowed" });
    }

    const token = req.headers.get("x-nohut-agent-token") ?? "";
    if (!TOKEN_RE.test(token)) {
      return json(401, { error: "unauthorized" });
    }

    if (req.method === "POST") {
      const lengthHeader = req.headers.get("content-length");
      if (lengthHeader !== null && (!/^\d+$/.test(lengthHeader) || Number(lengthHeader) > MAX_POST_BYTES)) {
        return json(413, { error: "request_too_large" });
      }
      let raw;
      try {
        raw = await readBoundedText(req, MAX_POST_BYTES);
      } catch {
        return json(400, { error: "invalid_request" });
      }
      if (raw === null) {
        return json(413, { error: "request_too_large" });
      }
      const trimmed = raw.trim();
      if (trimmed.length > 0) {
        const ct = req.headers.get("content-type") ?? "";
        if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(ct)) {
          return json(415, { error: "unsupported_content_type" });
        }
        let parsed;
        try {
          parsed = JSON.parse(trimmed);
        } catch {
          return json(400, { error: "invalid_request" });
        }
        if (!parsed || typeof parsed !== "object" || Array.isArray(parsed) || Object.keys(parsed).length > 0) {
          return json(400, { error: "invalid_request" });
        }
      }
    }

    let agent;
    try {
      agent = await ports.authenticateAgent(token);
    } catch {
      return json(503, { error: "capabilities_unavailable" });
    }
    if (!agent || typeof agent.restaurantId !== "string" || !agent.restaurantId) {
      return json(403, { error: "forbidden" });
    }

    return json(200, evaluateCapabilities(env, agent.restaurantId));
  };
}
