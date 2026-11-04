'use strict';
/* 房贷计算（changelog §102）。纯函数、不碰页面，页面和 tests/mortgage/check_calc.cjs 共用。
 *
 * 口径（和银行一致的地方、简化的地方都写在这里，页面的「怎么算的」照抄这几条）：
 * - 月利率 = 年利率 / 12。每期利息 = 剩余本金 × 月利率，四舍五入到分；最后一期把零头收干净。
 * - 等额本息：月供按剩余本金、剩余期数、当期利率现算，利率变了从那一期起重算月供。
 * - 等额本金：每期还本金 = 剩余本金 / 剩余期数（提前还款后重算），利息逐期递减。
 * - 提前还款记在某一期还完之后。「缩短年限」= 月供（等额本金是每期本金）不变、期数变少；
 *   「减少月供」= 期数不变、月供重算。
 * - 正在还的房贷：第 i 期用「上一期还款日」那天生效的利率（第 1 期用放款日）。银行在重定价那个月会按天拆开算，
 *   这里不拆，所以和银行 App 上的数会差一点点；页面上可以填银行 App 显示的剩余本金来校准。
 * - LPR 重定价：每年 1 月 1 日或放款日对应日，用重定价日所在月的上一个月公布的 5 年期以上 LPR，加上当时的加点。
 *   加点变了（比如 2023 年 9 月、2024 年 11 月银行批量下调存量房贷）从那天起就按新的加点。
 * - 公积金：利率调整后，存量贷款从次年 1 月 1 日起按新利率。
 */
(function (root) {
 const round2 = x => Math.round((x + (x >= 0 ? 1e-9 : -1e-9)) * 100) / 100;

 /* 等额本息的月供：本金 b、期数 n、月利率 r */
 function annuity(b, n, r) {
  if (n <= 0) return b;
  if (r === 0) return b / n;
  const f = Math.pow(1 + r, n);
  return b * r * f / (f - 1);
 }

 /* 月供 p 不变时，还完本金 b 要几期（等额本息「缩短年限」） */
 function monthsFor(b, p, r) {
  if (b <= 0) return 0;
  if (r === 0) return Math.ceil(b / p - 1e-9);
  if (p <= b * r) return Infinity;                 // 月供连利息都不够，永远还不完
  return Math.ceil(Math.log(p / (p - b * r)) / Math.log(1 + r) - 1e-9);
 }

 /* 通用的逐期计算。
  *   balance   起始本金          months   剩余期数        method  'equal'（等额本息）| 'principal'（等额本金）
  *   rateOf(i) 第 i 期的年利率（%），i 从 1 起            prepays [{after: 第几期还完之后, amount, mode: 'term' | 'payment'}]
  *   payment / part：接着算已经在还的贷款时，沿用当前的月供 / 每期本金（不传就现算）
  * 返回 {rows, interest, paid, months}；rows 每期 {n, rate, payment, principal, interest, balance, prepay}
  */
 function run({balance, months, method, rateOf, prepays = [], payment = null, part = null, limit = 1200}) {
  const rows = [];
  const byAfter = new Map();
  for (const p of prepays) {
   if (!(p.amount > 0) || !(p.after >= 0)) continue;
   if (!byAfter.has(p.after)) byAfter.set(p.after, []);
   byAfter.get(p.after).push(p);
  }
  let remaining = months, lastRate = null, interestSum = 0, paidSum = 0;
  balance = round2(balance);
  const applyPrepays = (after, r) => {
   let total = 0;
   for (const p of byAfter.get(after) || []) {
    const amount = round2(Math.min(p.amount, balance));
    if (amount <= 0) continue;
    balance = round2(balance - amount);
    total = round2(total + amount);
    if (balance <= 0) { remaining = 0; break; }
    if (p.mode === 'term') {
     if (method === 'equal') {
      if (payment == null) payment = round2(annuity(balance + amount, remaining, r));
      remaining = Math.min(remaining, monthsFor(balance, payment, r));
     } else {
      if (part == null) part = round2((balance + amount) / remaining);
      remaining = Math.min(remaining, Math.ceil(balance / part - 1e-9));
     }
    } else {
     payment = null;
     part = null;
    }
   }
   return total;
  };
  // 第 0 期之后的提前还款：接着算已经在还的贷款时，「现在马上还一笔」
  if (byAfter.has(0)) {
   const rate0 = rateOf(1);
   applyPrepays(0, rate0 / 1200);
  }
  for (let i = 1; balance > 0 && remaining > 0 && i <= limit; i++) {
   const rate = rateOf(i);
   const r = rate / 1200;
   if (method === 'equal') {
    // 只在利率真变了时重算：第一期 lastRate 还是空的，那时沿用的月供（缩短年限后的）不能被冲掉
    if (payment == null || lastRate != null && rate !== lastRate) payment = round2(annuity(balance, remaining, r));
   } else if (part == null) {
    part = round2(balance / remaining);
   }
   lastRate = rate;
   const interest = round2(balance * r);
   let principal = method === 'equal' ? round2(payment - interest) : part;
   if (principal >= balance || remaining === 1) principal = balance;
   if (principal < 0) principal = 0;                // 月供不够付利息（利率涨太多）：只付利息，本金不动
   balance = round2(balance - principal);
   remaining -= 1;
   interestSum = round2(interestSum + interest);
   paidSum = round2(paidSum + principal + interest);
   const row = {n: i, rate, payment: round2(principal + interest), principal, interest, balance, prepay: 0};
   row.prepay = applyPrepays(i, r);
   if (row.prepay) { row.balance = balance; paidSum = round2(paidSum + row.prepay); }
   rows.push(row);
  }
  return {rows, interest: interestSum, paid: paidSum, months: rows.length};
 }

 /* 新贷款：一笔（商贷或公积金）。rate 是年利率（%）。 */
 function loan({amount, months, rate, method, prepays = []}) {
  return run({balance: amount, months, method, rateOf: () => rate, prepays});
 }

 /* 几笔贷款（组合贷）按期加总 */
 function merge(results) {
  const n = Math.max(0, ...results.map(r => r.rows.length));
  const rows = [];
  for (let i = 0; i < n; i++) {
   const row = {n: i + 1, payment: 0, principal: 0, interest: 0, balance: 0, prepay: 0};
   for (const res of results) {
    const x = res.rows[i];
    if (!x) continue;
    row.payment = round2(row.payment + x.payment);
    row.principal = round2(row.principal + x.principal);
    row.interest = round2(row.interest + x.interest);
    row.balance = round2(row.balance + x.balance);
    row.prepay = round2(row.prepay + x.prepay);
    if (x.date) row.date = x.date;
   }
   rows.push(row);
  }
  return {rows, interest: round2(results.reduce((s, r) => s + r.interest, 0)),
   paid: round2(results.reduce((s, r) => s + r.paid, 0)), months: n};
 }

 /* ------------------------------------------------------------ 日期 */
 function parseDate(s) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s || '');
  return m ? {y: +m[1], m: +m[2], d: +m[3]} : null;
 }
 const pad = n => (n < 10 ? '0' : '') + n;
 const fmt = ({y, m, d}) => `${y}-${pad(m)}-${pad(d)}`;
 const daysIn = (y, m) => new Date(Date.UTC(y, m, 0)).getUTCDate();
 /* 加几个月；31 号碰到小月落在月底（银行也是这样排还款日的） */
 function addMonths(s, k, day) {
  const p = parseDate(s);
  let y = p.y, m = p.m + k;
  y += Math.floor((m - 1) / 12);
  m = ((m - 1) % 12 + 12) % 12 + 1;
  return fmt({y, m, d: Math.min(day || p.d, daysIn(y, m))});
 }
 const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);   // YYYY-MM-DD 直接按字符串比

 /* 历史表 [{date, rate}]（按日期升序）里 date 那天生效的值 */
 function valueAt(table, date) {
  let v = null;
  for (const row of table) { if (cmp(row.date, date) <= 0) v = row.rate; else break; }
  return v;
 }
 /* 严格早于 date 的最近一个值（重定价看的是「之前」公布的） */
 function valueBefore(table, date) {
  let v = null;
  for (const row of table) { if (cmp(row.date, date) < 0) v = row.rate; else break; }
  return v;
 }

 // 2019-10-08 之前放的商贷是 2020 年从基准利率转成 LPR 的：转换时基准固定用 2019 年 12 月的 LPR 4.80%，
 // 加点 = 原利率 − 4.80%，2021 年才第一次重定价。之后放的一开始就是 LPR 定价。
 const CONVERTED_BEFORE = '2019-10-08', CONVERTED_BASE = 4.8, CONVERTED_FIRST_REPRICE = '2021-01-01';

 /* 正在还的一笔贷款：从放款到现在逐期算一遍，再往后算到结清。
  *   p = {kind: 'commercial' | 'fund', amount, months, start（放款日）, firstDue（首次还款日，空 = 放款日后一个月）,
  *        method, rateMode: 'lpr' | 'fixed'（商贷）, bp（加点，基点）, rate（固定利率，或公积金的起始利率，%），
  *        reprice: 'jan1' | 'anniv', changes: [{date, bp}（商贷 LPR）或 {date, rate}（其余）], prepays: [{date, amount, mode}],
  *        bankBalance（银行 App 上的剩余本金，可空）}
  *   env = {today, lpr: [{date, rate}], fund: [{date, rate}], scenarioLpr（下次重定价起的 LPR，空 = 按最新一期不变）,
  *          extra: [{after: 现在之后第几期, amount, mode}]（打算提前还的，after = 0 是马上还）}
  */
 function current(p, env) {
  const firstDue = p.firstDue || addMonths(p.start, 1);
  const dueDay = parseDate(firstDue).d;
  const due = i => addMonths(firstDue, i - 1, dueDay);
  const accrual = i => (i <= 1 ? p.start : due(i - 1));
  const changes = (p.changes || []).filter(c => parseDate(c.date)).sort((a, b) => cmp(a.date, b.date));
  const lpr = env.lpr || [], fund = env.fund || [];
  const latestLpr = lpr.length ? lpr[lpr.length - 1].rate : null;
  const s = parseDate(p.start);
  const converted = p.kind === 'commercial' && p.rateMode === 'lpr' && cmp(p.start, CONVERTED_BEFORE) < 0;
  const anniv = y => fmt({y, m: s.m, d: Math.min(s.d, daysIn(y, s.m))});
  const repriceIn = y => (p.reprice === 'anniv' ? anniv(y) : `${y}-01-01`);
  const firstAllowed = converted ? CONVERTED_FIRST_REPRICE : null;
  const valid = r => cmp(r, p.start) > 0 && (!firstAllowed || cmp(r, firstAllowed) >= 0);

  // date 那天之前（含当天）最近的重定价日；没有就是 null（还在放款时的利率上）
  function lastReprice(date) {
   const y = parseDate(date).y;
   for (const cand of [repriceIn(y), repriceIn(y - 1)]) if (cmp(cand, date) <= 0 && valid(cand)) return cand;
   return null;
  }
  function nextReprice(date) {
   const y = parseDate(date).y;
   for (const cand of [repriceIn(y), repriceIn(y + 1), repriceIn(y + 2)]) if (cmp(cand, date) > 0 && valid(cand)) return cand;
   return null;
  }
  const changed = (base, key, date) => { for (const c of changes) if (c[key] != null && cmp(c.date, date) <= 0) base = c[key]; return base; };

  // 公积金只有起始利率和官方 5 年以上首套那一档一样时才自动跟着调（二套、5 年以下档位不同，靠手动记调整）
  const fundStart = valueAt(fund, p.start);
  const fundAuto = p.kind === 'fund' && (p.rate == null || fundStart != null && Math.abs(p.rate - fundStart) < 1e-9);

  function rateAt(date, future) {
   if (p.kind === 'fund') {
    let rate = p.rate != null ? p.rate : fundStart;
    // 存量公积金贷款在调整后的次年 1 月 1 日起执行新利率
    const jan = `${parseDate(date).y}-01-01`;
    if (fundAuto && cmp(jan, p.start) > 0) { const v = valueBefore(fund, jan); if (v != null) rate = v; }
    return changed(rate, 'rate', date);
   }
   if (p.rateMode === 'fixed') return changed(p.rate, 'rate', date);
   // 商贷 LPR：基准 = 最近一次重定价时的 LPR（还没重定价过就是放款时的），加点按当天生效的
   const bp = changed(p.bp || 0, 'bp', date);
   const rp = lastReprice(date);
   let base;
   if (rp && future && env.scenarioLpr != null && cmp(rp, env.today) > 0) base = env.scenarioLpr;
   else if (rp) base = valueBefore(lpr, rp.slice(0, 8) + '01');   // 重定价日所在月的上一个月公布的那期
   else base = converted ? CONVERTED_BASE : valueAt(lpr, p.start);
   if (base == null) base = latestLpr;
   return Math.round((base + bp / 100) * 10000) / 10000;
  }

  // 已经还过的提前还款，记在它之前最近一期还款之后
  const afterIndex = date => { let k = 0; while (k < p.months && cmp(due(k + 1), date) <= 0) k++; return k; };
  const past = (p.prepays || []).filter(x => parseDate(x.date) && x.amount > 0)
   .map(x => ({after: afterIndex(x.date), amount: x.amount, mode: x.mode || 'term'}));
  const full = run({balance: p.amount, months: p.months, method: p.method,
   rateOf: i => rateAt(accrual(i), false), prepays: past});
  full.rows.forEach(row => { row.date = due(row.n); });

  const paidCount = full.rows.filter(row => cmp(row.date, env.today) <= 0).length;
  const done = full.rows.slice(0, paidCount);
  const computedBalance = done.length ? done[done.length - 1].balance : round2(p.amount);
  const balance = p.bankBalance > 0 ? round2(p.bankBalance) : computedBalance;
  const remainingMonths = full.rows.length - paidCount;   // 缩短年限的提前还款会让它比合同少

  function project(extra) {
   if (balance <= 0 || remainingMonths <= 0) return {rows: [], interest: 0, paid: 0, months: 0};
   const res = run({balance, months: remainingMonths, method: p.method,
    rateOf: i => rateAt(accrual(paidCount + i), true), prepays: extra || []});
   res.rows.forEach(row => { row.n += paidCount; row.date = due(row.n); });
   return res;
  }
  const future = project([]);
  const next = nextReprice(env.today);
  return {
   paidCount, total: p.months, history: done,
   paidInterest: round2(done.reduce((sum, r) => sum + r.interest, 0)),
   paidPrincipal: round2(p.amount - computedBalance),
   computedBalance, balance, remainingMonths,
   rateNow: rateAt(accrual(paidCount + 1), false),
   paymentNow: future.rows.length ? future.rows[0].payment : 0,
   future, withExtra: env.extra && env.extra.length ? project(env.extra) : null,
   nextReprice: next, rateAfterReprice: next ? rateAt(next, true) : null, latestLpr,
   endDate: future.rows.length ? future.rows[future.rows.length - 1].date : (done.length ? done[done.length - 1].date : null),
  };
 }

 const api = {round2, annuity, monthsFor, run, loan, merge, current, addMonths, valueAt, valueBefore, parseDate};
 if (typeof module === 'object' && module.exports) module.exports = api;
 else root.MortgageCalc = Object.freeze(api);
})(typeof self !== 'undefined' ? self : this);
