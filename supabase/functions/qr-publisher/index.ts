// Review entrypoint: hard-disabled until independent QA and credential rotation.
// Do not deploy as a functional publisher or change the hard gate here.
import postgres from "npm:postgres@3.4.7";
import {makeDatabaseTransport} from "./database-transport.mjs";
import {makePublisherRuntime} from "./runtime.mjs";

const env = (key: string) => Deno.env.get(key);
const enabled = () => false;
const db = makeDatabaseTransport({env,postgres});
const handle = makePublisherRuntime({env,query:db.query,enabled});
Deno.serve(handle);
