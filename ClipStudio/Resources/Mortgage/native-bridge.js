/* Native input/output adapter. The calculation functions and rate history are the unchanged PWA files. */
(function (root) {
 'use strict';
 const C = root.MortgageCalc, R = root.MortgageRates;
 const defaults = {
  new: {v:1,type:'commercial',by:'price',price:300,down:30,amount:210,fundAmount:60,lpr:R.LPR.at(-1).rate,bp:-45,fundRate:R.FUND.at(-1).rate,years:30,method:'equal',preMonth:36,preAmount:20,prePart:'commercial'},
  current: {v:1,parts:[part()],extraAmount:10,extraWhen:'0',extraPart:0,scenarioLpr:''}
 };
 function part() { return {kind:'commercial',amount:100,years:30,start:'',firstDue:'',method:'equal',rateMode:'lpr',bp:-30,rate:'',reprice:'jan1',changes:[],prepays:[],bank:''}; }
 const num = x => x === '' || x == null ? NaN : Number(x);
 const dateOK = s => {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(s || '')) return false;
  const d = new Date(s + 'T00:00:00Z'); return !isNaN(d) && d.toISOString().slice(0,10) === s;
 };
 const check = (ok, message) => { if (!ok) throw new Error(message); };
 function calculate(kind, raw, today) {
  const s = Object.assign({}, defaults[kind], raw || {});
  if (kind === 'new') {
   const total = s.by === 'price' ? num(s.price)*(1-num(s.down)/100)*1e4 : num(s.amount)*1e4;
   const months = Math.round(num(s.years)*12), cr = Math.round((num(s.lpr)+num(s.bp)/100)*10000)/10000;
   check(total > 0 && Number.isFinite(total), '请填写有效贷款金额或房价、首付比例');
   check(s.by !== 'price' || num(s.down) >= 0 && num(s.down) < 100, '首付比例应在 0 到 100% 之间');
   check(months >= 1 && months <= 360, '期限应在 1 到 30 年之间');
   let parts = s.type === 'fund' ? [{kind:'fund',amount:total,rate:num(s.fundRate)}] : [{kind:'commercial',amount:total,rate:cr}];
   if (s.type === 'combo') {
    const f = Math.min(num(s.fundAmount)*1e4,total); check(f>0,'请填写公积金贷款金额');
    parts = [{kind:'commercial',amount:total-f,rate:cr},{kind:'fund',amount:f,rate:num(s.fundRate)}].filter(x=>x.amount>0);
   }
   parts.forEach(p=>check(p.rate>=0 && p.rate<20,'年利率应在 0 到 20% 之间'));
   const sum = (method,pre) => C.merge(parts.map(p=>C.loan({amount:p.amount,months,rate:p.rate,method,prepays:pre&&p.kind===pre.kind?[pre]:[]})));
   const equal = sum('equal'), principal = sum('principal'), base = s.method==='principal'?principal:equal;
   const after = Math.round(num(s.preMonth)), amount = num(s.preAmount)*1e4;
   const target = parts.find(x=>x.kind===s.prePart)||parts[0];
   let term = null, payment = null, savedMonths = null;
   if (amount>0 && after>=1 && after<months) {
    term = sum(s.method,{after,amount,kind:target.kind,mode:'term'});
    payment = sum(s.method,{after,amount,kind:target.kind,mode:'payment'});
    const one = C.loan({amount:target.amount,months,rate:target.rate,method:s.method});
    const short = C.loan({amount:target.amount,months,rate:target.rate,method:s.method,prepays:[{after,amount,mode:'term'}]});
    savedMonths = one.months-short.months;
   }
   return {kind,total,base,equal,principal,term,payment,savedMonths,after,parts,asOf:R.AS_OF};
  }
  check(dateOK(today),'当前日期无效');
  const parts = (Array.isArray(s.parts)&&s.parts.length?s.parts:[part()]).slice(0,2);
  const qs = parts.map(p=>{
   const lpr=p.kind==='commercial'&&p.rateMode==='lpr';
   const q={kind:p.kind,amount:num(p.amount)*1e4,months:Math.round(num(p.years)*12),start:p.start,firstDue:p.firstDue||'',method:p.method,
    rateMode:p.kind==='commercial'?p.rateMode:'fund',bp:num(p.bp)||0,rate:p.rate===''||p.rate==null?(p.kind==='fund'?null:NaN):num(p.rate),reprice:p.reprice,
    changes:(p.changes||[]).filter(c=>dateOK(c.date)&&c.value!==''&&c.value!=null&&Number.isFinite(num(c.value))).map(c=>lpr?{date:c.date,bp:num(c.value)}:{date:c.date,rate:num(c.value)}),
    prepays:(p.prepays||[]).filter(x=>dateOK(x.date)&&num(x.amount)>0).map(x=>({date:x.date,amount:num(x.amount)*1e4,mode:x.mode||'term'})),bankBalance:num(p.bank)>0?num(p.bank):0};
   check(q.amount>0&&Number.isFinite(q.amount),'请填写贷款金额'); check(q.months>=1&&q.months<=360,'期限应在 1 到 30 年之间');
   check(dateOK(q.start)&&q.start<=today,'放款日期应是有效的过去日期');
   check(!q.firstDue || dateOK(q.firstDue)&&q.firstDue>q.start,'首次还款日应在放款日之后');
   check(q.kind==='commercial'&&q.rateMode==='lpr' || q.rate===null&&q.kind==='fund' || q.rate>=0&&q.rate<20,'请填写正确的年利率');
   if(q.kind==='fund'&&q.rate===null)check(C.valueAt(R.FUND,q.start)!==null,'此放款日期没有公积金历史利率，请手填起始利率');
   if(q.kind==='commercial'&&q.rateMode==='lpr')check(q.start>='2015-10-24','该放款日期过早，请选固定利率并用银行剩余本金校准');
   return q;
  });
  const scenario = s.scenarioLpr===''||s.scenarioLpr==null?null:num(s.scenarioLpr);
  check(scenario===null || scenario>=0&&scenario<20,'情景 LPR 应在 0 到 20% 之间');
  const env = extra=>({today,lpr:R.LPR,fund:R.FUND,scenarioLpr:scenario,extra});
  const results=qs.map(q=>C.current(q,env([])));
  const i=Math.min(Math.max(0,Number(s.extraPart)||0),qs.length-1), after=Math.max(0,Math.round(num(s.extraWhen)||0)), amount=num(s.extraAmount)*1e4;
  const extra = mode=>C.merge(qs.map((q,k)=>k===i?C.current(q,env([{after,amount,mode}])).withExtra:results[k].future).filter(Boolean));
  return {kind,parts:results,base:C.merge(results.map(r=>r.future)),total:results.reduce((sum,r)=>sum+r.balance,0),
   term:amount>0?extra('term'):null,payment:amount>0?extra('payment'):null,after,asOf:R.AS_OF};
 }
 root.NativeMortgage = {
  defaults:()=>JSON.stringify(defaults), part:()=>JSON.stringify(part()),
  calculate:(kind,data,today)=>JSON.stringify(calculate(kind,JSON.parse(data),today))
 };
})(this);
