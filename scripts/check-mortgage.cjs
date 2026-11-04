'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {isDeepStrictEqual} = require('node:util');
const same=(a,b,message)=>assert.ok(isDeepStrictEqual(a,b),message || 'calculation output differs');
const root = path.resolve(__dirname, '..');
const resources = path.join(root, 'ClipStudio', 'Resources', 'Mortgage');
const reference = path.resolve(root, '..', 'workbench');

// Run the PWA's existing tests against the actual bundled calculation files.
for (const name of ['calc.js', 'rates.js']) {
    assert.deepEqual(fs.readFileSync(path.join(resources, name)), fs.readFileSync(path.join(reference, 'frontend', 'mortgage', name)));
}
const test = path.join(reference, 'tests', 'check_mortgage_calc.cjs');
vm.runInNewContext(fs.readFileSync(test, 'utf8'), {
    console, __dirname: path.dirname(test), require(id) {
        if (id.endsWith(path.join('mortgage', 'calc.js'))) return require(path.join(resources, 'calc.js'));
        if (id.endsWith(path.join('mortgage', 'rates.js'))) return require(path.join(resources, 'rates.js'));
        return require(id);
    }
}, { filename: test });

const context = vm.createContext({ console });
for (const name of ['calc.js', 'rates.js', 'native-bridge.js']) vm.runInContext(fs.readFileSync(path.join(resources, name), 'utf8'), context, {filename:name});
const bridge = context.NativeMortgage;
const calc = require(path.join(resources, 'calc.js'));
const rates = require(path.join(resources, 'rates.js'));
const defaults = JSON.parse(bridge.defaults());
const run = (kind, data) => JSON.parse(bridge.calculate(kind, JSON.stringify(data), '2026-11-02'));
let cases = 0;
function check(title, action) { action(); cases++; console.log('bridge: ' + title); }
check('commercial and both repayment methods match direct calculation', () => {
    const d = {...defaults.new, by:'amount', amount:100, lpr:4.9, bp:0, preAmount:0};
    const r = run('new',d);
    for (const method of ['equal','principal']) same(r[method], calc.merge([calc.loan({amount:1e6,months:360,rate:4.9,method})]), method+' merged schedule');
});
check('combination loan and prepayment retain component totals', () => {
    const d={...defaults.new,type:'combo',by:'amount',amount:150,fundAmount:50};
    const r=run('new',d);
    const sum=calc.merge([calc.loan({amount:1e6,months:360,rate:3.05,method:'equal'}),calc.loan({amount:5e5,months:360,rate:2.6,method:'equal'})]);
    same(r.base,sum);assert.ok(r.term.interest<r.base.interest);assert.ok(r.payment.interest<r.base.interest);
});
check('existing PWA current-plan data produces identical history and projection', () => {
    const part={...JSON.parse(bridge.part()),amount:100,start:'2021-06-15',changes:[{date:'2024-11-01',value:-45}],prepays:[{date:'2025-05-01',amount:10,mode:'payment'}],bank:612345.67};
    const d={...defaults.current,parts:[part],extraAmount:0};
    const expected=calc.current({kind:'commercial',amount:1e6,months:360,start:part.start,firstDue:'',method:'equal',rateMode:'lpr',bp:-30,rate:NaN,reprice:'jan1',changes:[{date:'2024-11-01',bp:-45}],prepays:[{date:'2025-05-01',amount:1e5,mode:'payment'}],bankBalance:612345.67},{today:'2026-11-02',lpr:rates.LPR,fund:rates.FUND,scenarioLpr:null,extra:[]});
    same(run('current',d).parts[0],expected,'current-loan history and projection');
});
check('invalid input rejects instead of showing zero or NaN', () => {
    for(const d of [{...defaults.new,years:0},{...defaults.new,by:'amount',amount:-1},{...defaults.new,down:120},{...defaults.new,lpr:'bad'}]) assert.throws(()=>run('new',d));
    assert.throws(()=>run('current',{...defaults.current,parts:[{...JSON.parse(bridge.part()),start:'2026-02-30'}]}));
});
check('prepayment summary must read the first installment after the extra payment', () => {
    const d={...defaults.new,preMonth:36,preAmount:20};
    const r=run('new',d);
    assert.equal(r.after,36);
    assert.equal(r.payment.rows[0].payment,r.base.rows[0].payment);
    assert.ok(r.payment.rows[r.after].payment<r.base.rows[r.after].payment);
    const payoff=run('new',{...d,preAmount:1000});
    assert.equal(payoff.term.rows.length,payoff.after);
    assert.equal(payoff.term.rows[payoff.after],undefined);
});
check('combination target shortening is not whole-plan shortening', () => {
    const r=run('new',{...defaults.new,type:'combo'});
    assert.ok(r.savedMonths>0);
    assert.equal(r.base.months,r.term.months);
});
check('current immediate prepayment totals must include the upfront principal', () => {
    const part={...JSON.parse(bridge.part()),start:'2021-06-15'};
    const r=run('current',{...defaults.current,parts:[part],extraWhen:0,extraAmount:10});
    assert.equal(r.after,0);
    for(const key of ['term','payment']) {
        assert.ok(Math.abs(r.total+r[key].interest-r[key].paid-100000)<0.02);
        assert.ok(r[key].interest<r.base.interest);
    }
});
check('oversized prepayments expose the actual capped amount in the schedule', () => {
    const trial=run('new',{...defaults.new,preAmount:1000});
    for(const key of ['term','payment']) {
        const applied=trial[key].rows[trial.after-1].prepay;
        assert.equal(applied,trial.base.rows[trial.after-1].balance);
        assert.ok(applied<1000*1e4);
    }
    const part={...JSON.parse(bridge.part()),start:'2021-06-15'};
    for(const after of [0,12]) {
        const r=run('current',{...defaults.current,parts:[part],extraWhen:after,extraAmount:1000});
        for(const key of ['term','payment']) {
            const actual=after===0?r.total:r[key].rows[after-1].prepay;
            assert.ok(actual>0&&actual<=r.total);
            if(after>0) assert.equal(actual,r.base.rows[after-1].balance);
        }
    }
});
console.log(cases+' native adapter checks passed; no Swift runtime or server acceptance implied.');
