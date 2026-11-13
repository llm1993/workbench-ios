'use strict';
/* 到手工资：打包资源自检。node scripts/check-salary.cjs
 * 只证明打包进 App 的 JS 与设计稿一致、桥接口径正确；不代表 Swift 运行时或真机验收。 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { isDeepStrictEqual } = require('node:util');
const root = path.resolve(__dirname, '..');
const resources = path.join(root, 'ClipStudio', 'Resources', 'Salary');
const design = path.join(root, 'Design', 'salary-v1');
const read = file => fs.readFileSync(file, 'utf8');
const same = (a, b, message) => assert.ok(isDeepStrictEqual(a, b), message || 'calculation output differs');
// vm realm objects carry a different prototype; compare plain JSON on both sides.
const plain = value => JSON.parse(JSON.stringify(value));

// The bundled engine must stay byte-identical to the engine the design review approved.
same(fs.readFileSync(path.join(resources, 'salary.js')), fs.readFileSync(path.join(design, 'salary.js')),
     'bundled salary.js drifted from Design/salary-v1/salary.js');

const context = vm.createContext({
  console,
  process: { exit(code) { if (code) throw new Error('打包引擎未通过设计稿的计算自检'); } }
});
for (const name of ['salary.js', 'salary-bridge.js']) {
  vm.runInContext(read(path.join(resources, name)), context, { filename: name });
}
// Run the design's calculation suite against the bundled copy rather than the design copy.
vm.runInContext(read(path.join(design, 'check.cjs')).replace("require('./salary.js');", ''), context, { filename: 'check.cjs' });

const bridge = context.NativeSalary;
const calc = context.SalaryCalc;
const defaults = JSON.parse(bridge.defaults());
const compute = data => JSON.parse(bridge.compute(JSON.stringify(data)));
let cases = 0;
function check(title, action) { action(); cases++; console.log('bridge: ' + title); }

check('defaults and city presets travel as plain JSON', () => {
  same(defaults, plain(calc.defaults));
  const cities = JSON.parse(bridge.cities());
  same(cities, plain(calc.CITIES));
  assert.equal(cities.length, 7);
  assert.ok(cities.every(c => c.floor >= 0 && c.ceil > c.floor && c.fund >= 0 && c.fund <= 12));
});
check('tax tables keep the open-ended top bracket as null', () => {
  const tables = JSON.parse(bridge.tables());
  assert.equal(tables.standard, 5000);
  assert.equal(tables.year.length, 7);
  assert.equal(tables.month.length, 7);
  assert.equal(tables.year[6][0], null);
  assert.equal(tables.month[6][0], null);
  assert.equal(tables.year[6][1], 0.45);
  assert.equal(tables.special.pensionCap, 1000);
  same(tables.special.rent, [1500, 1100, 800]);
});
check('bridge compute matches the engine for the reviewed demo scenario', () => {
  same(compute(defaults), plain(calc.compute(defaults)));
  const r = compute(defaults);
  assert.equal(r.main.rows[0].net, 25953);
  assert.equal(r.main.net, 352170);
  assert.equal(r.bonusMode, 'separate');
  assert.equal(r.bonusCompare.saving, 6210);
});
check('bridge compute accepts partial input and string amounts', () => {
  same(compute({ gross: '32,000' }), plain(calc.compute({ gross: '32,000' })));
  assert.equal(compute({ gross: '32,000' }).insurance.base, 32000);
  assert.equal(compute({}).main.rows.length, 12);
});
check('marginal matches the engine and keeps less of a bigger raise', () => {
  same(JSON.parse(bridge.marginal(JSON.stringify(defaults), 1000)), plain(calc.marginal(defaults, 1000)));
  const small = JSON.parse(bridge.marginal(JSON.stringify(defaults), 1000));
  const large = JSON.parse(bridge.marginal(JSON.stringify(defaults), 5000));
  assert.equal(small.yearGain, 7920);
  assert.equal(small.keepRate, 0.66);
  assert.ok(large.yearGain > small.yearGain);
  // Past the contribution ceiling a raise stops paying more social insurance, so the keep rate rises.
  assert.ok(large.keepRate > small.keepRate);
  assert.equal(compute({ ...defaults, gross: 37000 }).insurance.capped, true);
});
check('bonus blind zone reports the edge, the loss and the amount that clears it', () => {
  const blind = JSON.parse(bridge.bonusTrap(36001));
  assert.equal(blind.state, 'blind');
  assert.equal(blind.edge, 36000);
  assert.equal(blind.fix, 38567);
  assert.ok(blind.loss > 2300 && blind.loss < 2320);
  assert.ok(38567 - calc.bonusTax(38567) >= 36000 - calc.bonusTax(36000));
  assert.ok(38566 - calc.bonusTax(38566) < 36000 - calc.bonusTax(36000));
});
check('bonus outside the blind zone names the next threshold and both rates', () => {
  const below = JSON.parse(bridge.bonusTrap(60000));
  assert.equal(below.state, 'below');
  assert.equal(below.next, 144000);
  assert.equal(below.fromRate, 0.1);
  assert.equal(below.toRate, 0.2);
  assert.equal(JSON.parse(bridge.bonusTrap(0)).state, 'empty');
  assert.equal(JSON.parse(bridge.bonusTrap(1000000)).edge, 960000);
  assert.equal(JSON.parse(bridge.bonusTrap(1200000)).state, 'top');
});
check('zero income and over-cap rates stay finite instead of NaN', () => {
  const zero = compute({ gross: 0, bonus: 0 });
  assert.ok(Number.isFinite(zero.main.net) && zero.main.avgNet === 0);
  assert.equal(compute({ gross: 32000, fundRate: 30 }).insurance.rate, 12);
  assert.equal(compute({ gross: 999999 }).insurance.capped, true);
});
console.log(cases + ' native adapter checks passed; no Swift runtime or device acceptance implied.');