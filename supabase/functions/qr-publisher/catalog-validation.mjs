// Pure QR publisher catalog validation. No network or authorization; caller must enforce authority, revision and durable receipt before writing.
export function validateCatalog(menu, previous = null) {
  const fail=(reason)=>{throw new Error(reason)};
  const obj=x=>x!==null&&typeof x==="object"&&!Array.isArray(x);
  const exact=(x,required,optional=[])=>obj(x)&&required.every(k=>Object.hasOwn(x,k))&&Object.keys(x).every(k=>required.includes(k)||optional.includes(k));
  const lang=(x,required=false,max=2500)=>exact(x,["tr","en","ar"])&&["tr","en","ar"].every(k=>typeof x[k]==="string"&&x[k].length<=max&&(!required||x[k].trim().length>0));
  const id=(x,re)=>typeof x==="string"&&re.test(x);
  const price=x=>typeof x==="number"&&Number.isFinite(x)&&x>=0&&x<=100000&&Math.abs(x*100-Math.round(x*100))<1e-6;
  const asset=x=>x===null||(typeof x==="string"&&x.length<=300&&/^assets\/[A-Za-z0-9_./-]+\.(png|jpg|jpeg|webp|svg)$/.test(x)&&!x.includes("..")&&!x.includes("//")&&!x.includes("/./"));
  const date=x=>x===null||(typeof x==="string"&&/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})$/.test(x)&&Number.isFinite(Date.parse(x)));
  const flag=x=>typeof x==="boolean";
  const order=x=>Number.isSafeInteger(x)&&x>=0&&x<=1000000;
  if(!exact(menu,["schemaVersion","source","currency","categories","products","campaigns"])||menu.schemaVersion!==1||menu.source!=="nohutfalafel/qr-menu"||menu.currency!=="TRY"||!Array.isArray(menu.categories)||menu.categories.length<2||menu.categories.length>80||!Array.isArray(menu.products)||menu.products.length<1||menu.products.length>500||!Array.isArray(menu.campaigns)||menu.campaigns.length>100)fail("invalid_catalog");
  const categories=new Map(),products=new Map(),names=new Set(),legacy=new Set(),campaigns=new Set();
  for(const c of menu.categories){
    if(!exact(c,["id","name","description","active","order"])||!id(c.id,/^[a-z][a-z0-9-]{0,49}$/)||categories.has(c.id)||!lang(c.name,true)||!lang(c.description)||!flag(c.active)||!order(c.order))fail("invalid_category");
    categories.set(c.id,c);
  }
  if(categories.get("all")?.active!==true)fail("all_category_required");
  for(const p of menu.products){
    if(!exact(p,["id","category","name","displayName","description","price","active","image","available","legacyKey","order"])||!Number.isSafeInteger(p.id)||p.id<0||p.id>1000000||products.has(p.id)||!categories.has(p.category)||p.category==="all"||!lang(p.name,true)||!lang(p.displayName,true)||!lang(p.description)||!price(p.price)||!flag(p.active)||!flag(p.available)||!asset(p.image)||!order(p.order)||typeof p.legacyKey!=="string"||!p.legacyKey.trim()||p.legacyKey.length>150||legacy.has(p.legacyKey)||names.has(p.name.tr.trim().toLowerCase()))fail("invalid_product");
    products.set(p.id,p);names.add(p.name.tr.trim().toLowerCase());legacy.add(p.legacyKey);
  }
  for(const c of menu.campaigns){
    if(!exact(c,["id","active","startsAt","endsAt","price","poster","thumbnail","title","description","items"],["eyebrow"])||!id(c.id,/^[a-z0-9-]{1,70}$/)||campaigns.has(c.id)||!flag(c.active)||!date(c.startsAt)||!date(c.endsAt)||(c.startsAt!==null&&c.endsAt!==null&&Date.parse(c.startsAt)>=Date.parse(c.endsAt))||!price(c.price)||!asset(c.poster)||!asset(c.thumbnail)||!lang(c.title,true)||!lang(c.description)||(Object.hasOwn(c,"eyebrow")&&!lang(c.eyebrow))||!Array.isArray(c.items)||c.items.length>100||!c.items.every(x=>lang(x,true)))fail("invalid_campaign");
    campaigns.add(c.id);
  }
  if(previous!==null){
    validateCatalog(previous);
    for(const p of previous.products)if(products.get(p.id)?.legacyKey!==p.legacyKey)fail("stable_product_identity");
    for(const c of previous.categories)if(!categories.has(c.id))fail("stable_category_identity");
  }
  return menu;
}
