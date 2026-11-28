import { validateCatalog } from './catalog-validation.mjs';
function runChecks(validateCatalog) {
 const tr={tr:"Test",en:"Test",ar:"اختبار"};
 const c={schemaVersion:1,source:"nohutfalafel/qr-menu",currency:"TRY",categories:[{id:"all",name:tr,description:tr,active:true,order:0},{id:"wrap",name:tr,description:tr,active:true,order:1}],products:[{id:1,category:"wrap",name:tr,displayName:tr,description:tr,price:140,active:true,image:"assets/products/test.webp",available:true,legacyKey:"Test",order:0}],campaigns:[{id:"test",active:true,startsAt:null,endsAt:null,price:99,poster:null,thumbnail:null,title:tr,description:tr,items:[tr]}]};
 const clone=()=>JSON.parse(JSON.stringify(c)); const results=[];
 function test(name,mutate,expected,prev=null){let x=clone();mutate(x);let got="ok";try{validateCatalog(x,prev)}catch(e){got=e.message}if(got!==expected)throw Error(name+": expected "+expected+" got "+got);results.push(name)}
 test("valid",()=>{},"ok");
 test("valid price update",x=>x.products[0].price=145.25,"ok",c);
 test("wrong repository",x=>x.source="other/repo","invalid_catalog");
 test("extra root field",x=>x.token="dummy","invalid_catalog");
 test("unexpected product field",x=>x.products[0].secret="dummy","invalid_product");
 test("fractional cent",x=>x.products[0].price=1.001,"invalid_product");
 test("negative price",x=>x.products[0].price=-1,"invalid_product");
 test("unsafe asset",x=>x.products[0].image="assets/../test.webp","invalid_product");
 test("external asset",x=>x.products[0].image="https://example.com/test.webp","invalid_product");
 test("missing translation",x=>delete x.products[0].name.ar,"invalid_product");
 test("inactive all",x=>x.categories[0].active=false,"all_category_required");
 test("duplicate product",x=>x.products.push({...x.products[0]}),"invalid_product");
 test("invalid category",x=>x.products[0].category="all","invalid_product");
 test("stable ID",x=>x.products[0].id=2,"stable_product_identity",c);
 test("stable legacy key",x=>x.products[0].legacyKey="new","stable_product_identity",c);
 test("bad campaign date",x=>x.campaigns[0].endsAt="tomorrow","invalid_campaign");
 test("reversed campaign dates",x=>{x.campaigns[0].startsAt="2026-12-02T00:00:00Z";x.campaigns[0].endsAt="2026-12-01T00:00:00Z"},"invalid_campaign");
 return results;
}
const results=runChecks(validateCatalog); console.log(`${results.length} catalog validation checks passed`);
