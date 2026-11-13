'use strict';
/* 到手工资计算自检：node Design/salary-v1/check.cjs */
require('./salary.js');
const C = globalThis.SalaryCalc;
let pass = 0, fail = 0;
const near = (a, b, eps = 0.01) => Math.abs(a - b) <= eps;
function ok(name, cond, detail) {
  if (cond) { pass++; console.log('  ok  ' + name); }
  else { fail++; console.log('FAIL  ' + name + (detail ? '  → ' + detail : '')); }
}
function eq(name, actual, expected) { ok(name, near(actual, expected), `期望 ${expected}，实际 ${actual}`); }

console.log('年终奖单独计税（按月换算表）');
eq('税务总局案例 42000 → 3990', C.bonusTax(42000), 3990);
eq('36000 → 1080', C.bonusTax(36000), 1080);
eq('36001 → 3390.10（临界点跳档）', C.bonusTax(36001), 3390.1);
ok('36001 到手反而更少', 36001 - C.bonusTax(36001) < 36000 - C.bonusTax(36000));
eq('0 → 0', C.bonusTax(0), 0);
eq('144000 → 14190', C.bonusTax(144000), 14190);

console.log('累计预扣预缴');
const bare = { city: 'custom', gross: 10000, baseMode: 'custom', customBase: 0, fundMode: 'custom', customFundBase: 0, fundRate: 0, bonus: 0, children: 0, elder: 'none', housing: 'none' };
const b = C.compute(bare);
eq('无扣除 1 月预扣 150', b.main.rows[0].tax, 150);
eq('无扣除 7 月仍 3% 档', b.main.rows[6].tax, 150);
eq('无扣除 8 月跳档补差 430', b.main.rows[7].tax, 430);
eq('无扣除全年个税 3480', b.main.taxTotal, 3480);
ok('8 月标记跳档', !!b.main.rows[7].jump && b.main.rows[7].jump.to === 0.1);
eq('全年到手 = 120000 − 3480', b.main.net, 116520);
ok('逐月到手递减', b.main.rows[0].net > b.main.rows[11].net);

console.log('三险一金与基数截断');
const sh = C.compute({ city: 'shanghai', gross: 32000, fundRate: 7, bonus: 60000, children: 1, elder: 'only', housing: 'rent', rentTier: 0 });
eq('上海基数未触顶', sh.insurance.base, 32000);
eq('养老 8%', sh.insurance.items[0].value, 2560);
eq('医疗 2%', sh.insurance.items[1].value, 640);
eq('失业 0.5%', sh.insurance.items[2].value, 160);
eq('公积金 7%', sh.insurance.fund, 2240);
eq('个人合计 5600', sh.insurance.total, 5600);
eq('工伤个人不缴', sh.insurance.items[3].value, 0);
const ceil = C.compute({ city: 'shanghai', gross: 60000, fundRate: 7 });
eq('超上限按 36921 封顶', ceil.insurance.base, 36921);
ok('标记已封顶', ceil.insurance.capped);
const floor = C.compute({ city: 'shanghai', gross: 3000, fundRate: 7 });
eq('低于下限按 7384 托底', floor.insurance.base, 7384);
ok('标记已托底', floor.insurance.floored);
eq('北京医疗含大病 3 元', C.compute({ city: 'beijing', gross: 20000 }).insurance.items[1].value, 403);

console.log('专项附加扣除');
eq('示例组合 6500/月', sh.special.total, 6500);
eq('两孩 + 婴幼儿', C.specialMonthly({ children: 2, infants: 1, elder: 'none', housing: 'none' }).total, 6000);
eq('非独生分摊 1500', C.specialMonthly({ elder: 'share', housing: 'none' }).total, 1500);
eq('房租二档 1100', C.specialMonthly({ housing: 'rent', rentTier: 1, elder: 'none' }).total, 1100);
eq('房贷与房租互斥', C.specialMonthly({ housing: 'loan', rentTier: 0, elder: 'none' }).total, 1000);
eq('个人养老金封顶 1000', C.specialMonthly({ pension: 5000, elder: 'none', housing: 'none' }).total, 1000);

console.log('示例方案全年口径');
eq('示例 1 月到手 25953', sh.main.rows[0].net, 25953);
eq('示例全年工资个税 18840', sh.main.tax, 18840);
eq('示例年终奖单独计税 5790', sh.separate.bonusTax, 5790);
eq('自动择优选单独', sh.bonusCompare.best === 'separate' ? 1 : 0, 1);
eq('单独比并入省 6210', sh.bonusCompare.saving, 6210);
eq('全年到手 352170', sh.main.net, 352170);
eq('月均到手 29347.50', sh.main.avgNet, 29347.5);
ok('12 月含年终奖', sh.main.rows[11].bonus === 60000);
eq('逐月净额累加等于全年', sh.main.rows[11].cumNet, sh.main.net);

console.log('低收入并入更划算');
const low = C.compute({ city: 'shanghai', gross: 8000, fundRate: 7, bonus: 20000, children: 1, elder: 'only', housing: 'rent' });
ok('自动择优改选并入', low.bonusCompare.best === 'merged', JSON.stringify(low.bonusCompare));
ok('并入后全年税额更低', low.main.taxTotal <= low.separate.taxTotal);

console.log('入职月份与边际');
const mid = C.compute(Object.assign({}, bare, { startMonth: 7 }));
eq('7 月入职只发 6 个月', mid.main.months, 6);
eq('前 6 个月无收入', mid.main.rows[0].net, 0);
eq('7 月起按首月 3% 预扣', mid.main.rows[6].tax, 150);
const m = C.marginal(bare, 1000);
eq('月薪 +1000 全年多到手 10800', m.yearGain, 10800);
eq('边际留存率 90%', Math.round(m.keepRate * 100), 90);

console.log('边界输入');
const zero = C.compute({ city: 'shanghai', gross: 0, bonus: 0 });
ok('零收入不报错', Number.isFinite(zero.main.net));
ok('零收入平均不除零', zero.main.avgNet === 0);
const odd = C.compute({ city: 'shanghai', gross: '32,000', bonus: '', fundRate: '7' });
eq('字符串金额可解析', odd.insurance.base, 32000);
eq('空奖金按 0', odd.main.bonus, 0);
const over = C.compute({ city: 'shanghai', gross: 32000, fundRate: 30 });
eq('公积金比例封顶 12%', over.insurance.rate, 12);

console.log(`\n${pass} 项通过，${fail} 项失败`);
process.exit(fail ? 1 : 0);