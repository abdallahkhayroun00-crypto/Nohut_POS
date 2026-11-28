// Supabase Edge Function entrypoint for Trendyol Cloud Proxy v1.
// Disabled by default until NOHUT_TRENDYOL_PROXY_ENABLED=true is explicitly set.
// Uses preconfigured Supabase Secrets only; never exposes credentials to clients or logs.
import postgres from "npm:postgres@3.4.7";
import { loadProxyConfig } from "./config.mjs";
import { createTgoClient } from "./tgo-client.mjs";
import { createTrendyolProxyHandler } from "./handler.mjs";

const env = (key: string) => Deno.env.get(key);
const dbUrl = env("NOHUT_TRENDYOL_DB_URL") || env("SUPABASE_DB_URL") || "";
const sql = dbUrl ? postgres(dbUrl, { ssl: "require", max: 4, prepare: false }) : null;

const ports = {
  async authenticateAgent(token: string) {
    if (!sql) throw new Error("db_unconfigured");
    const rows = await sql`
      select (nohut_private.authenticate_windows_agent(${token})).restaurant_id::text as restaurant_id
    `;
    const r = rows[0]?.restaurant_id;
    return r ? { restaurantId: r } : null;
  },
  async validateCommandLease(args: {
    token: string;
    commandId: string;
    leaseGeneration: number;
    envelopeSha256: string;
    expectedActionType: string;
  }) {
    if (!sql) throw new Error("db_unconfigured");
    const rows = await sql`
      select public.nohut_agent_validate_claim(
        ${args.token},
        ${args.commandId}::uuid,
        ${args.leaseGeneration}::integer,
        ${args.envelopeSha256}
      ) as res
    `;
    const res = rows[0]?.res;
    if (!res || res.status !== "valid") return { valid: false };
    const envRows = await sql`
      select envelope from nohut_private.commands
       where request_id = ${args.commandId}
       limit 1
    `;
    const envelope = envRows[0]?.envelope;
    if (!envelope || envelope.action_type !== args.expectedActionType) {
      return { valid: false };
    }
    return { valid: true, payload: envelope.payload };
  },
};

Deno.serve(async (req) => {
  let config;
  try {
    config = loadProxyConfig(env);
  } catch {
    return new Response(JSON.stringify({ version: 1, status: "proxy_disabled" }), {
      status: 503,
      headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
    });
  }
  const tgo = config.enabled ? createTgoClient(config) : null;
  const handle = createTrendyolProxyHandler({ config, tgo, ports });
  return handle(req);
});
