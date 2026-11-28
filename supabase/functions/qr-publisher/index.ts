// Controlled by explicit NOHUT_QR_PUBLISHER_ENABLED=true secret (disabled by default).
import postgres from "npm:postgres@3.4.7";
import {makeDatabaseTransport} from "./database-transport.mjs";
import {makePublisherRuntime} from "./runtime.mjs";

const env = (key: string) => Deno.env.get(key);
const enabled = () => String(env("NOHUT_QR_PUBLISHER_ENABLED") || "").trim().toLowerCase() === "true";
const db = makeDatabaseTransport({env,postgres});
const handle = makePublisherRuntime({env,query:db.query,enabled});
Deno.serve(handle);
