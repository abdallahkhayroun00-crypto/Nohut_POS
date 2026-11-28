// Supabase Edge Function entrypoint for Nohut POS Cloud Capabilities v1.
// Authenticates the Windows POS agent via opaque 64-hex x-nohut-agent-token
// and reports tenant-scoped booleans for server-hosted integrations.
// Never exposes secret material, secret names, or tenant identifiers.
import postgres from "npm:postgres@3.4.7";
import { createCloudCapabilitiesHandler } from "./handler.mjs";

const env = (key: string) => Deno.env.get(key);
const dbUrl = env("NOHUT_CAPABILITIES_DB_URL") || env("NOHUT_TRENDYOL_DB_URL") || env("SUPABASE_DB_URL") || "";
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
};

const handle = createCloudCapabilitiesHandler({ env, ports });
Deno.serve(handle);
