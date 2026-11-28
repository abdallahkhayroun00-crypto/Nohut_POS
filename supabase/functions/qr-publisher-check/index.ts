// Temporary, server-only QR connection diagnostic. Never publishes.
import { createPrivateKey, sign, timingSafeEqual } from "node:crypto";

const repo = "nohutfalafel/qr-menu";
const api = "https://api.github.com";
const json = (data: unknown, status = 200) => new Response(JSON.stringify(data), {
  status, headers: { "content-type": "application/json", "cache-control": "no-store" },
});
const b64 = (data: unknown) => Buffer.from(JSON.stringify(data)).toString("base64url");
import { Buffer } from "node:buffer";

function same(a: string, b: string) {
  const x = Buffer.from(a), y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

class CheckError extends Error {
  constructor(public stage: string, public status: number) { super(stage); }
}

export function makeHandler(env: (name: string) => string | undefined, call = fetch) {
  return async (req: Request): Promise<Response> => {
    // Separate high-entropy diagnostic credential; never require a database
    // administrator key in the Dashboard. Gateway JWT verification stays on.
    // Missing/short configuration fails closed.
    const checkKey = env("NOHUT_QR_CHECK_KEY") ?? "";
    const supplied = req.headers.get("x-nohut-check-key") ?? "";
    if (checkKey.length < 32 || !same(supplied, checkKey))
      return json({error:"forbidden"},403);
    if (req.method !== "POST") return json({error:"method_not_allowed"},405);
    const steps: string[] = [];
    let stage = "config";
    try {
      const id = env("NOHUT_QR_GITHUB_APP_ID")?.trim() ?? "";
      const pem = env("NOHUT_QR_GITHUB_PRIVATE_KEY") ?? "";
      if (!/^\d{1,16}$/.test(id) || !pem) throw new CheckError(stage, 503);
      const key = createPrivateKey(pem.replace(/\\n/g, "\n").trim());
      if (key.asymmetricKeyType !== "rsa" || (key.asymmetricKeyDetails?.modulusLength ?? 0) < 2048)
        throw new CheckError(stage, 503);
      steps.push("rsa_key_loaded");
      const now = Math.floor(Date.now()/1000);
      const unsigned = b64({alg:"RS256",typ:"JWT"})+"."+b64({iat:now-60,exp:now+480,iss:id});
      const jwt = unsigned+"."+sign("RSA-SHA256",Buffer.from(unsigned),key).toString("base64url");
      async function gh(path: string, token: string, body?: unknown, missing = false) {
        const response = await call(api+path, {
          method:body===undefined?"GET":"POST", redirect:"error",
          headers:{authorization:"Bearer "+token,accept:"application/vnd.github+json",
            "x-github-api-version":"2022-11-28","user-agent":"NohutQrConnectivity/1",
            ...(body===undefined?{}:{"content-type":"application/json"})},
          body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(12000),
        });
        if (missing && response.status===404) return null;
        if (!response.ok) throw new CheckError(stage,response.status);
        return await response.json();
      }
      stage="app_auth";
      const app=await gh("/app",jwt);
      if (String(app.id)!==id || app.slug!=="nohut-qr-publisher") throw new CheckError(stage,403);
      steps.push("github_app_authenticated");
      stage="installation";
      const installation=await gh("/repos/"+repo+"/installation",jwt);
      if (!Number.isSafeInteger(installation.id)||installation.id<=0||
        String(installation.app_id)!==id||installation.suspended_at||
        installation.account?.login?.toLowerCase()!=="nohutfalafel")
        throw new CheckError(stage,403);
      steps.push("repository_installation_found");
      stage="read_token";
      // Explicitly attenuate installation token to ONE repository and read-only contents.
      const access=await gh("/app/installations/"+installation.id+"/access_tokens",jwt,
        {repositories:["qr-menu"],permissions:{contents:"read"}});
      if (typeof access.token!=="string"||access.permissions?.contents!=="read")
        throw new CheckError(stage,403);
      steps.push("read_only_token_created");
      stage="catalog_read";
      const managed=await gh("/repos/"+repo+"/contents/cms/pos-managed-menu.json?ref=main",access.token,undefined,true);
      const file=managed??await gh("/repos/"+repo+"/contents/cms/catalog-v1.json?ref=main",access.token);
      if (file?.encoding!=="base64"||typeof file.content!=="string"||
        typeof file.sha!=="string"||file.content.length>2000000) throw new CheckError(stage,502);
      const catalog=JSON.parse(Buffer.from(file.content.replace(/\s/g,""),"base64").toString("utf8"));
      if (!Array.isArray(catalog.products)||!Array.isArray(catalog.categories)||!Array.isArray(catalog.campaigns))
        throw new CheckError(stage,502);
      steps.push("catalog_read");
      return json({ok:true,mode:"read_only",repository:repo,installation_id:installation.id,
        repository_selection:installation.repository_selection,
        installation_contents_write:installation.permissions?.contents==="write",
        revision:file.sha,products:catalog.products.length,categories:catalog.categories.length,
        campaigns:catalog.campaigns.length,steps});
    } catch (e) {
      // No exception strings, request headers, response bodies or secret values.
      return json({ok:false,mode:"read_only",stage:e instanceof CheckError?e.stage:stage,
        upstream_status:e instanceof CheckError?e.status:null,steps},502);
    }
  };
}
if (import.meta.main) Deno.serve(makeHandler(name=>Deno.env.get(name)));
