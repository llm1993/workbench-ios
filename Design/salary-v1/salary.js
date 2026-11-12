'use strict';
/* 到手工资计算。纯函数、不碰页面，预览页与 check.cjs 共用。
 *
 * 口径：
 * - 个税按居民工资薪金「累计预扣预缴法」逐月算：本月预扣 = 累计应纳税额 − 已预扣合计，不为负。
 *   所以同样月薪，年初到手多、跳档后到手少，这是真实工资条的样子，不是简化成每月一样。
 * - 三险一金个人部分：养老 8%、医疗 2%（部分城市另加大病固定额）、失业 0.5%；工伤 / 生育个人不缴。
 *   基数按当地上下限截断；公积金基数与比例单独设置。
 * - 年终奖单独计税：奖金 ÷ 12 找「按月换算表」的税率与速算扣除数，税额 = 奖金 × 税率 − 速算扣除数。
 *   政策执行至 2027-12-31（财政部 税务总局公告 2023 年第 30 号）。也可选择并入综合所得。
 * - 「自动择优」= 两种口径各算一遍全年税额，取少的那个，并给出差额。
 * - 城市预设是示例值，正式接入前须按当地社保年度公布数据核对；页面上全部可改。
 */
(function (root) {
  const r2 = x => Math.round((x + (x >= 0 ? 1e-9 : -1e-9)) * 100) / 100;
  const clamp = (x, lo, hi) => Math.min(Math.max(x, lo), hi);

  const YEAR_TABLE = [
    [36000, 0.03, 0], [144000, 0.10, 2520], [300000, 0.20, 16920],
    [420000, 0.25, 31920], [660000, 0.30, 52920], [960000, 0.35, 85920], [Infinity, 0.45, 181920]
  ];
  const MONTH_TABLE = [
    [3000, 0.03, 0], [12000, 0.10, 210], [25000, 0.20, 1410],
    [35000, 0.25, 2660], [55000, 0.30, 4410], [80000, 0.35, 7160], [Infinity, 0.45, 15160]
  ];
  const rowOf = (table, x) => table.find(b => x <= b[0]) || table[table.length - 1];
  const annualTax = x => x <= 0 ? 0 : r2(x * rowOf(YEAR_TABLE, x)[1] - rowOf(YEAR_TABLE, x)[2]);
  const bonusTax = b => b <= 0 ? 0 : r2(b * rowOf(MONTH_TABLE, b / 12)[1] - rowOf(MONTH_TABLE, b / 12)[2]);

  /* 示例预设（2025 社保年度量级）。er* 为单位缴纳部分，只用于「雇主成本」展示。 */
  const CITIES = [
    { key: 'beijing', name: '北京', floor: 6821, ceil: 35283, fundFloor: 2420, fundCeil: 36549, fund: 12, medical: 2, medicalFix: 3, erMedical: 9.8, injury: 0.4 },
    { key: 'shanghai', name: '上海', floor: 7384, ceil: 36921, fundFloor: 2690, fundCeil: 36921, fund: 7, medical: 2, medicalFix: 0, erMedical: 9.5, injury: 0.16 },
    { key: 'shenzhen', name: '深圳', floor: 4500, ceil: 27234, fundFloor: 2360, fundCeil: 41400, fund: 5, medical: 2, medicalFix: 0, erMedical: 5.2, injury: 0.14 },
    { key: 'guangzhou', name: '广州', floor: 4546, ceil: 27234, fundFloor: 2300, fundCeil: 39876, fund: 12, medical: 2, medicalFix: 0, erMedical: 6.85, injury: 0.2 },
    { key: 'hangzhou', name: '杭州', floor: 4812, ceil: 24930, fundFloor: 2490, fundCeil: 39987, fund: 12, medical: 2, medicalFix: 0, erMedical: 9.5, injury: 0.2 },
    { key: 'chengdu', name: '成都', floor: 4511, ceil: 22554, fundFloor: 2100, fundCeil: 31362, fund: 12, medical: 2, medicalFix: 0, erMedical: 8.3, injury: 0.16 },
    { key: 'custom', name: '自定义', floor: 0, ceil: 999999, fundFloor: 0, fundCeil: 999999, fund: 12, medical: 2, medicalFix: 0, erMedical: 9, injury: 0.3 }
  ];
  const PENSION = 8, UNEMPLOYMENT = 0.5, ER_PENSION = 16, ER_UNEMPLOYMENT = 0.5;
  const STANDARD = 5000;
  const SPECIAL = { child: 2000, infant: 2000, elderOnly: 3000, elderShare: 1500, loan: 1000, rent: [1500, 1100, 800], study: 400, pensionCap: 1000 };

  const defaults = {
    city: 'shanghai', gross: 32000, baseMode: 'auto', customBase: '', fundRate: 7, fundMode: 'auto', customFundBase: '',
    bonus: 60000, bonusMode: 'auto', bonusMonth: 12,
    children: 1, infants: 0, elder: 'only', housing: 'rent', rentTier: 0, study: false, pension: 0,
    otherPre: 0, afterTax: 0, startMonth: 1
  };

  const num = (v, fallback = 0) => {
    const n = typeof v === 'number' ? v : parseFloat(String(v ?? '').replace(/[,\s]/g, ''));
    return Number.isFinite(n) ? n : fallback;
  };

  function specialMonthly(s) {
    const elder = s.elder === 'only' ? SPECIAL.elderOnly : s.elder === 'share' ? SPECIAL.elderShare : 0;
    const housing = s.housing === 'loan' ? SPECIAL.loan
      : s.housing === 'rent' ? SPECIAL.rent[clamp(Math.round(num(s.rentTier)), 0, 2)] : 0;
    const items = [
      { key: 'children', name: '子女教育', value: Math.max(0, Math.round(num(s.children))) * SPECIAL.child },
      { key: 'infants', name: '婴幼儿照护', value: Math.max(0, Math.round(num(s.infants))) * SPECIAL.infant },
      { key: 'elder', name: '赡养老人', value: elder },
      { key: 'housing', name: s.housing === 'loan' ? '住房贷款利息' : '住房租金', value: housing },
      { key: 'study', name: '继续教育', value: s.study ? SPECIAL.study : 0 },
      { key: 'pension', name: '个人养老金', value: clamp(num(s.pension), 0, SPECIAL.pensionCap) }
    ];
    return { items, total: r2(items.reduce((a, b) => a + b.value, 0)) };
  }

  function insurance(s, city) {
    const gross = Math.max(0, num(s.gross));
    const raw = s.baseMode === 'floor' ? city.floor : s.baseMode === 'custom' ? num(s.customBase, gross) : gross;
    const base = r2(clamp(raw, city.floor, city.ceil));
    const rawFund = s.fundMode === 'floor' ? city.fundFloor : s.fundMode === 'custom' ? num(s.customFundBase, gross) : gross;
    const fundBase = r2(clamp(rawFund, city.fundFloor, city.fundCeil));
    const rate = clamp(num(s.fundRate, city.fund), 0, 12);
    const items = [
      { key: 'pension', name: '养老保险', rate: PENSION, value: r2(base * PENSION / 100), er: r2(base * ER_PENSION / 100) },
      { key: 'medical', name: '医疗保险', rate: city.medical, value: r2(base * city.medical / 100 + city.medicalFix), er: r2(base * city.erMedical / 100) },
      { key: 'unemployment', name: '失业保险', rate: UNEMPLOYMENT, value: r2(base * UNEMPLOYMENT / 100), er: r2(base * ER_UNEMPLOYMENT / 100) },
      { key: 'injury', name: '工伤保险', rate: 0, value: 0, er: r2(base * city.injury / 100) },
      { key: 'fund', name: '住房公积金', rate, value: r2(fundBase * rate / 100), er: r2(fundBase * rate / 100) }
    ];
    const social = r2(items[0].value + items[1].value + items[2].value);
    const fund = items[4].value;
    return {
      base, fundBase, rate, items, social, fund, total: r2(social + fund),
      capped: raw > city.ceil + 0.005, floored: raw < city.floor - 0.005,
      employer: r2(items.reduce((a, b) => a + b.er, 0))
    };
  }

  /* 一次全年逐月推演。mode: 'separate' | 'merged' */
  function run(s, city, ins, special, mode) {
    const gross = Math.max(0, num(s.gross));
    const bonus = Math.max(0, num(s.bonus));
    const bonusMonth = clamp(Math.round(num(s.bonusMonth, 12)), 1, 12);
    const start = clamp(Math.round(num(s.startMonth, 1)), 1, 12);
    const otherPre = Math.max(0, num(s.otherPre));
    const afterTax = Math.max(0, num(s.afterTax));
    const separateBonus = mode === 'separate' ? bonusTax(bonus) : 0;
    const rows = [];
    let cumIncome = 0, cumDeduct = 0, cumPaid = 0, prevRate = 0;
    for (let m = 1; m <= 12; m++) {
      const active = m >= start && gross > 0;
      const pay = active ? gross : 0;
      const monthBonus = m === bonusMonth ? bonus : 0;
      const social = active ? ins.social : 0;
      const fund = active ? ins.fund : 0;
      const extra = active ? special.total : 0;
      const pre = active ? otherPre : 0;
      const income = pay + (mode === 'merged' ? monthBonus : 0);
      cumIncome += income;
      cumDeduct += (active ? STANDARD : 0) + social + fund + extra + pre;
      const taxable = Math.max(0, r2(cumIncome - cumDeduct));
      const row = rowOf(YEAR_TABLE, taxable);
      const cumTax = annualTax(taxable);
      const tax = active ? r2(Math.max(0, cumTax - cumPaid)) : 0;
      cumPaid = r2(cumPaid + tax);
      const bTax = m === bonusMonth ? separateBonus : 0;
      const net = r2(pay + monthBonus - social - fund - tax - bTax - (active ? afterTax : 0));
      rows.push({
        month: m, active, gross: pay, bonus: monthBonus,
        social, fund, insurance: r2(social + fund), special: extra, otherPre: pre, afterTax: active ? afterTax : 0,
        cumIncome: r2(cumIncome), cumDeduct: r2(cumDeduct), cumTaxable: taxable,
        rate: row[1], quick: row[2], cumTax, tax, bonusTax: bTax,
        taxTotal: r2(tax + bTax), net, cumNet: 0,
        jump: active && row[1] > prevRate && m > start ? { from: prevRate, to: row[1] } : null
      });
      if (active) prevRate = row[1];
    }
    let running = 0;
    rows.forEach(r => { running = r2(running + r.net); r.cumNet = running; });
    const sum = key => r2(rows.reduce((a, b) => a + b[key], 0));
    const months = rows.filter(r => r.active).length;
    return {
      mode, rows, months,
      gross: sum('gross'), bonus: sum('bonus'), social: sum('social'), fund: sum('fund'),
      tax: sum('tax'), bonusTax: sum('bonusTax'), taxTotal: sum('taxTotal'),
      afterTax: sum('afterTax'), net: sum('net'),
      avgNet: months ? r2(sum('net') / months) : 0,
      salaryNet: r2(sum('net') - (bonus - separateBonus)),
      bonusNet: r2(bonus - separateBonus),
      jumps: rows.filter(r => r.jump)
    };
  }

  function compute(raw) {
    const s = Object.assign({}, defaults, raw || {});
    const city = CITIES.find(c => c.key === s.city) || CITIES[0];
    const ins = insurance(s, city);
    const special = specialMonthly(s);
    const separate = run(s, city, ins, special, 'separate');
    const merged = run(s, city, ins, special, 'merged');
    const requested = s.bonusMode === 'auto' ? (separate.taxTotal <= merged.taxTotal ? 'separate' : 'merged') : s.bonusMode;
    const main = requested === 'merged' ? merged : separate;
    const bonus = Math.max(0, num(s.bonus));
    const employer = r2(ins.employer * main.months);
    return {
      input: s, city, insurance: ins, special, main, separate, merged,
      bonusMode: requested, auto: s.bonusMode === 'auto',
      bonusCompare: {
        separate: { tax: separate.taxTotal, net: separate.net, bonusTax: separate.bonusTax },
        merged: { tax: merged.taxTotal, net: merged.net, bonusTax: merged.bonusTax },
        best: separate.taxTotal <= merged.taxTotal ? 'separate' : 'merged',
        saving: r2(Math.abs(separate.taxTotal - merged.taxTotal)),
        hasBonus: bonus > 0
      },
      cost: { employer, total: r2(main.gross + main.bonus + employer) },
      effectiveRate: main.gross + main.bonus > 0 ? main.taxTotal / (main.gross + main.bonus) : 0,
      netRate: main.gross + main.bonus > 0 ? main.net / (main.gross + main.bonus) : 0,
      raise: marginal(s, 1000)
    };
  }

  function marginal(raw, delta = 1000) {
    const s = Object.assign({}, defaults, raw || {});
    const a = computeQuiet(s), b = computeQuiet(Object.assign({}, s, { gross: Math.max(0, num(s.gross)) + delta }));
    const gain = r2(b.main.net - a.main.net);
    return { delta, yearGain: gain, monthGain: r2(gain / 12), keepRate: delta > 0 ? gain / (delta * 12) : 0 };
  }
  function computeQuiet(s) {
    const city = CITIES.find(c => c.key === s.city) || CITIES[0];
    const ins = insurance(s, city), special = specialMonthly(s);
    const separate = run(s, city, ins, special, 'separate'), merged = run(s, city, ins, special, 'merged');
    const mode = s.bonusMode === 'auto' ? (separate.taxTotal <= merged.taxTotal ? 'separate' : 'merged') : s.bonusMode;
    return { main: mode === 'merged' ? merged : separate };
  }

  root.SalaryCalc = {
    compute, marginal, insurance, specialMonthly, annualTax, bonusTax,
    CITIES, SPECIAL, YEAR_TABLE, MONTH_TABLE, STANDARD, defaults, r2
  };
})(typeof globalThis !== 'undefined' ? globalThis : this);