(() => {
  'use strict';
  const C = globalThis.SalaryCalc;
  const $ = id => document.getElementById(id);
  const esc = s => String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const money = n => Number(n || 0).toLocaleString('zh-CN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const whole = n => Math.round(Number(n || 0)).toLocaleString('zh-CN');
  const num = n => Number(n || 0).toLocaleString('zh-CN', { maximumFractionDigits: 2 });
  const wan = n => num(Number(n || 0) / 10000);
  const pct = n => (Number(n || 0) * 100).toFixed(1) + '%';
  const clamp = (x, a, b) => Math.min(Math.max(x, a), b);
  const nOf = v => { const n = parseFloat(String(v ?? '').replace(/[,\s]/g, '')); return Number.isFinite(n) ? n : 0; };

  const state = Object.assign({}, C.defaults);
  let scene = 'calc', month = 1, chartMode = 'salary', showEmployer = false, raiseDelta = 1000;
  let offerA = null, offerB = null, result = null, syncing = false;

  const PRESETS = [
    { name: '上海 · 一娃租房', desc: '月薪 32,000 · 年终奖 6 万 · 公积金 7%', data: Object.assign({}, C.defaults) },
    { name: '北京 · 双娃房贷', desc: '月薪 45,000 · 年终奖 12 万 · 公积金 12%', data: Object.assign({}, C.defaults, { city: 'beijing', gross: 45000, fundRate: 12, bonus: 120000, children: 2, infants: 0, elder: 'share', housing: 'loan', pension: 1000 }) },
    { name: '深圳 · 应届入职', desc: '月薪 18,000 · 7 月入职 · 仅租房扣除', data: Object.assign({}, C.defaults, { city: 'shenzhen', gross: 18000, fundRate: 5, bonus: 20000, children: 0, elder: 'none', housing: 'rent', rentTier: 0, startMonth: 7 }) },
    { name: '杭州 · 扣除用满', desc: '月薪 25,000 · 个人养老金 1,000', data: Object.assign({}, C.defaults, { city: 'hangzhou', gross: 25000, fundRate: 12, bonus: 40000, children: 1, infants: 1, elder: 'only', housing: 'loan', study: true, pension: 1000 }) },
    { name: '成都 · 低收入并入更划算', desc: '月薪 8,000 · 年终奖 2 万', data: Object.assign({}, C.defaults, { city: 'chengdu', gross: 8000, fundRate: 12, bonus: 20000, children: 1, elder: 'only', housing: 'rent', rentTier: 1 }) }
  ];
  let presets = PRESETS.slice();
  let activePreset = 0;

  const HUES = [
    { key: 'net', name: '到手', css: 'var(--net)' },
    { key: 'fund', name: '公积金', css: 'var(--fund)' },
    { key: 'social', name: '社保', css: 'var(--si)' },
    { key: 'tax', name: '个税', css: 'var(--tax)' },
    { key: 'after', name: '税后扣款', css: 'var(--other)' }
  ];

  /* ── 初始化静态控件 ── */
  const cityOptions = C.CITIES.map(c => `<option value="${c.key}">${c.name}</option>`).join('');
  $('city-select').innerHTML = cityOptions;
  document.querySelectorAll('select[data-offer][data-key="city"]').forEach(s => { s.innerHTML = cityOptions; });
  const monthOptions = Array.from({ length: 12 }, (_, i) => `<option value="${i + 1}">${i + 1} 月</option>`).join('');
  $('bonus-month-select').innerHTML = monthOptions;
  $('start-month-select').innerHTML = Array.from({ length: 12 }, (_, i) => `<option value="${i + 1}">${i + 1} 月${i === 0 ? '（全年在职）' : ''}</option>`).join('');

  /* ── 计算 ── */
  function recalc() {
    result = C.compute(state);
    if (!offerA) offerA = pickOffer(state);
    if (!offerB) offerB = Object.assign({}, pickOffer(state), { gross: 38000, bonus: 90000, fundRate: 12, city: 'beijing' });
    month = clamp(month, 1, 12);
    renderHero();
    renderReadouts();
    renderChart();
    renderSlip();
    renderCompare();
    renderSticky();
  }
  const pickOffer = s => ({ city: s.city, gross: nOf(s.gross), bonus: nOf(s.bonus), fundRate: nOf(s.fundRate), baseMode: s.baseMode, customBase: s.customBase, fundMode: s.fundMode, customFundBase: s.customFundBase, children: s.children, infants: s.infants, elder: s.elder, housing: s.housing, rentTier: s.rentTier, study: s.study, pension: s.pension, otherPre: s.otherPre, afterTax: s.afterTax, startMonth: s.startMonth, bonusMode: s.bonusMode, bonusMonth: s.bonusMonth });

  /* ── 主卡 ── */
  function renderHero() {
    const r = result.main.rows[month - 1];
    const total = r.gross + r.bonus;
    $('slip-month').textContent = `${month} 月到手`;
    $('slip-badge').textContent = !r.active ? '未入职' : r.bonus > 0 ? '含年终奖' : r.jump ? `本月跳档 ${Math.round(r.rate * 100)}%` : `税率档 ${Math.round(r.rate * 100)}%`;
    $('slip-badge').className = 'pill' + (r.jump ? ' tax' : '');
    animateNumber($('net-value'), r.net);
    $('slip-sub').innerHTML = `<span>${esc(result.city.name)} · 税前 <b>${whole(total)}</b></span><span>到手率 <b>${total > 0 ? pct(r.net / total) : '—'}</b></span><span>专项附加 <b>${whole(result.special.total)}</b>/月</span>`;

    const rows = [
      { name: '税前月薪', value: r.gross, sign: '', color: 'var(--sub)' },
      r.bonus > 0 ? { name: `年终奖（${result.bonusMode === 'separate' ? '单独计税' : '并入综合所得'}）`, value: r.bonus, sign: '', color: 'var(--sub)' } : null,
      { name: '社保个人部分', value: -r.social, sign: '−', color: 'var(--si)' },
      { name: '公积金个人部分', value: -r.fund, sign: '−', color: 'var(--fund)', note: '进你的账户' },
      { name: '个人所得税', value: -r.taxTotal, sign: '−', color: 'var(--tax)' },
      r.afterTax > 0 ? { name: '税后扣款', value: -r.afterTax, sign: '−', color: 'var(--other)' } : null
    ].filter(Boolean);
    $('flow').innerHTML = rows.map(x => `<div class="flow-row"><i class="dot" style="background:${x.color}"></i><span class="name">${esc(x.name)}${x.note ? ` <small style="opacity:.7">· ${x.note}</small>` : ''}</span><span class="amt" style="color:${x.value < 0 ? x.color : 'var(--ink)'}">${x.value < 0 ? '−' : ''}${money(Math.abs(x.value))}</span></div>`).join('')
      + `<div class="flow-row total"><i class="dot" style="background:var(--net)"></i><span class="name">实发到手</span><span class="amt" style="color:var(--net)">${money(r.net)}</span></div>`;

    const parts = [
      { key: 'net', v: Math.max(0, r.net) }, { key: 'fund', v: r.fund },
      { key: 'social', v: r.social }, { key: 'tax', v: r.taxTotal }, { key: 'after', v: r.afterTax }
    ];
    const sum = parts.reduce((a, b) => a + b.v, 0) || 1;
    $('share').innerHTML = parts.filter(p => p.v > 0).map(p => {
      const h = HUES.find(x => x.key === p.key);
      return `<span style="width:${p.v / sum * 100}%;background:${h.css}"></span>`;
    }).join('');
    $('share').setAttribute('aria-label', parts.map(p => `${HUES.find(x => x.key === p.key).name} ${pct(p.v / sum)}`).join('，'));
    $('share-labels').innerHTML = parts.filter(p => p.v > 0).map(p => {
      const h = HUES.find(x => x.key === p.key);
      return `<span><i style="background:${h.css}"></i>${h.name} ${pct(p.v / sum)}</span>`;
    }).join('');

    $('metrics').innerHTML = [
      ['全年到手', wan(result.main.net), '万元'],
      ['月均到手', whole(result.main.avgNet), '元'],
      ['全年个税', whole(result.main.taxTotal), '元']
    ].map(([t, v, u]) => `<div class="metric"><span>${t}</span><strong>${esc(v)}</strong><small>${u}</small></div>`).join('');

    const bc = result.bonusCompare;
    if (bc.hasBonus) {
      $('insight-text').textContent = `年终奖 ${whole(result.main.bonus)} 元，${bc.best === 'separate' ? '单独计税' : '并入综合所得'}比另一种少交 ${whole(bc.saving)} 元。`;
      $('insight-action').textContent = '看两种算法差多少';
    } else {
      $('insight-text').textContent = `月薪每加 1,000 元，全年实际多到手 ${whole(result.raise.yearGain)} 元，落袋 ${pct(result.raise.keepRate)}。`;
      $('insight-action').textContent = '看涨薪与 offer 对比';
    }

    const notice = $('calc-notice');
    const warnings = [];
    if (r.active && r.net < 0) warnings.push('社保按下限托底后已超过月薪，本月到手为负，实际请与 HR 确认缴纳口径。');
    if (result.insurance.capped) warnings.push(`月薪高于${result.city.name}社保基数上限，社保按 ${whole(result.insurance.base)} 封顶计算。`);
    if (result.insurance.floored) warnings.push(`月薪低于${result.city.name}社保基数下限，社保按 ${whole(result.insurance.base)} 托底计算。`);
    notice.hidden = warnings.length === 0;
    $('calc-notice-text').textContent = warnings.join(' ');

    $('invite-copy').textContent = `当前方案全年到手 ${wan(result.main.net)} 万元，月均 ${whole(result.main.avgNet)} 元。`;
    $('policy-note').textContent = '全年一次性奖金单独计税政策执行至 2027-12-31（财政部 税务总局公告 2023 年第 30 号）。';
  }

  let animFrame = 0;
  function animateNumber(el, target) {
    const from = parseFloat(String(el.textContent).replace(/,/g, '')) || 0;
    if (matchMedia('(prefers-reduced-motion: reduce)').matches || Math.abs(target - from) < 0.5) { el.textContent = money(target); return; }
    cancelAnimationFrame(animFrame);
    const t0 = performance.now(), dur = 320;
    const step = t => {
      const k = clamp((t - t0) / dur, 0, 1), e = 1 - Math.pow(1 - k, 3);
      el.textContent = money(from + (target - from) * e);
      if (k < 1) animFrame = requestAnimationFrame(step);
    };
    animFrame = requestAnimationFrame(step);
  }

  /* ── 参数台读数（不重建输入框，避免打断输入） ── */
  function renderReadouts() {
    syncing = true;
    document.querySelectorAll('[data-field]').forEach(el => {
      const k = el.dataset.field;
      if (k === 'cityFloor' || k === 'cityCeil') return;
      if (el === document.activeElement) return;
      const v = state[k];
      if (el.tagName === 'SELECT') el.value = String(v);
      else el.value = String(v ?? '');
    });
    const custom = C.CITIES.find(c => c.key === 'custom');
    const floorInput = document.querySelector('[data-field="cityFloor"]');
    const ceilInput = document.querySelector('[data-field="cityCeil"]');
    if (floorInput !== document.activeElement) floorInput.value = String(custom.floor);
    if (ceilInput !== document.activeElement) ceilInput.value = String(custom.ceil);
    syncing = false;

    $('gross-read').textContent = '¥' + whole(state.gross);
    $('gross-slider').value = String(clamp(nOf(state.gross), 3000, 120000));
    $('si-base-read').textContent = '¥' + whole(result.insurance.base);
    $('fund-read').textContent = num(result.insurance.rate) + '% · ¥' + whole(result.insurance.fund);
    $('fund-slider').value = String(result.insurance.rate);
    $('fund-base-read').textContent = '¥' + whole(result.insurance.fundBase);
    $('special-read').textContent = '¥' + whole(result.special.total) + '/月';
    $('children-count').textContent = String(Math.max(0, Math.round(nOf(state.children))));
    $('infants-count').textContent = String(Math.max(0, Math.round(nOf(state.infants))));
    $('bonus-mode-read').textContent = result.auto ? '已选' + (result.bonusMode === 'separate' ? '单独' : '并入') : '';
    $('si-hint').innerHTML = `${esc(result.city.name)}示例区间 <b>${whole(result.city.floor)} – ${whole(result.city.ceil)}</b>；个人缴养老 8% + 医疗 ${num(result.city.medical)}%${result.city.medicalFix ? ` + ${result.city.medicalFix} 元` : ''} + 失业 0.5%，工伤生育个人不缴。`;

    $('custom-city-row').hidden = state.city !== 'custom';
    $('custom-base-field').hidden = state.baseMode !== 'custom';
    $('custom-fund-field').hidden = state.fundMode !== 'custom';
    $('rent-field').hidden = state.housing !== 'rent';
    document.querySelectorAll('[data-base]').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.base === state.baseMode)));
    document.querySelectorAll('[data-fundbase]').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.fundbase === state.fundMode)));
    document.querySelectorAll('[data-elder]').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.elder === state.elder)));
    document.querySelectorAll('[data-housing]').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.housing === state.housing)));
    document.querySelectorAll('[data-bonusmode]').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.bonusmode === state.bonusMode)));
    document.querySelector('[data-toggle="study"]').setAttribute('aria-pressed', String(!!state.study));
    document.querySelectorAll('[data-step]').forEach(b => {
      const k = b.dataset.step, v = Math.max(0, Math.round(nOf(state[k])));
      b.disabled = b.dataset.delta === '-1' ? v <= 0 : v >= 6;
    });
  }

  /* ── 逐月图表 ── */
  function renderChart() {
    const rows = result.main.rows;
    const withBonus = chartMode === 'all';
    const data = rows.map(r => ({
      month: r.month, active: r.active, jump: r.jump,
      net: Math.max(0, r.net - (withBonus ? 0 : r.bonus - r.bonusTax)),
      fund: r.fund, social: r.social,
      tax: r.taxTotal - (withBonus ? 0 : r.bonusTax),
      after: r.afterTax
    }));
    const totals = data.map(d => d.net + d.fund + d.social + d.tax + d.after);
    const peak = Math.max(1, ...totals);
    const unit = peak >= 20000 ? 10000 : 1000;
    const top = Math.ceil(peak / unit) * unit;
    const L = 32, R = 314, T = 16, B = 156, H = B - T;
    const slot = (R - L) / 12, bw = Math.min(15, slot - 7);
    const y = v => B - (v / top) * H;
    let s = '';
    for (let i = 0; i <= 2; i++) {
      const v = top * i / 2, yy = y(v);
      s += `<line x1="${L}" y1="${yy.toFixed(1)}" x2="${R}" y2="${yy.toFixed(1)}" stroke="var(--line)" stroke-width="1"${i ? ' stroke-dasharray="2 4"' : ''}/>`;
      s += `<text x="${L - 6}" y="${(yy + 3).toFixed(1)}" text-anchor="end">${num(v / unit)}</text>`;
    }
    s += `<text x="${L - 6}" y="${T - 5}" text-anchor="end">${unit === 10000 ? '万' : '千'}</text>`;
    const order = ['net', 'fund', 'social', 'tax', 'after'];
    data.forEach((d, i) => {
      const x = L + i * slot + (slot - bw) / 2;
      if (d.month === month) s += `<rect class="sel" x="${(L + i * slot).toFixed(1)}" y="${T - 6}" width="${slot.toFixed(1)}" height="${H + 12}" rx="7"/>`;
      if (!d.active) {
        s += `<rect x="${x.toFixed(1)}" y="${B - 5}" width="${bw.toFixed(1)}" height="5" rx="2" fill="var(--line2)"/>`;
      } else {
        s += `<clipPath id="barclip${i}"><rect x="${x.toFixed(1)}" y="${y(totals[i]).toFixed(1)}" width="${bw.toFixed(1)}" height="${Math.max(2, B - y(totals[i])).toFixed(1)}" rx="4"/></clipPath><g clip-path="url(#barclip${i})">`;
        let acc = 0;
        order.forEach(k => {
          const v = d[k]; if (v <= 0) return;
          const h = (v / top) * H;
          s += `<rect class="bar-${k === 'social' ? 'si' : k}" x="${x.toFixed(1)}" y="${y(acc + v).toFixed(1)}" width="${bw.toFixed(1)}" height="${Math.max(0.6, h).toFixed(1)}"/>`;
          acc += v;
        });
        s += '</g>';
        if (d.jump) {
          const jy = y(totals[i]) - 4;
          s += `<line class="jump-line" x1="${(x + bw / 2).toFixed(1)}" y1="${(jy + 2).toFixed(1)}" x2="${(x + bw / 2).toFixed(1)}" y2="${(jy + 12).toFixed(1)}"/>`;
          s += `<text class="jump-text" x="${(x + bw / 2).toFixed(1)}" y="${Math.max(9, jy - 1).toFixed(1)}" text-anchor="middle">↑${Math.round(d.jump.to * 100)}%</text>`;
        }
      }
      s += `<text x="${(L + i * slot + slot / 2).toFixed(1)}" y="${B + 15}" text-anchor="middle"${d.month === month ? ' fill="var(--accent)" font-weight="700"' : ''}>${d.month}</text>`;
      s += `<rect class="hit" data-month="${d.month}" x="${(L + i * slot).toFixed(1)}" y="${T - 8}" width="${slot.toFixed(1)}" height="${H + 26}" tabindex="0" role="button" aria-label="查看 ${d.month} 月"/>`;
    });
    if (withBonus && result.main.rows.some(r => r.bonus > 0)) {
      const bm = result.main.rows.findIndex(r => r.bonus > 0);
      s += `<text x="${(L + bm * slot + slot / 2).toFixed(1)}" y="${B + 28}" text-anchor="middle" fill="var(--fund)" font-size="8">年终奖</text>`;
    }
    $('plot').innerHTML = s;
    $('legend').innerHTML = HUES.filter(h => h.key !== 'after' || result.main.afterTax > 0)
      .map(h => `<span><i style="background:${h.css}"></i>${h.name}</span>`).join('')
      + '<span style="color:var(--tax)">↑ 表示当月税率跳档</span>';
    const d = data[month - 1];
    $('chart-read-label').textContent = `${month} 月${d.active ? '' : '（未入职）'} · 到手`;
    $('chart-read-value').textContent = '¥' + money(d.net);
    $('chart-sub').textContent = withBonus
      ? `含 ${result.main.rows.findIndex(r => r.bonus > 0) + 1} 月发放的年终奖，纵轴按全年峰值缩放。`
      : '累计预扣预缴：收入累计越高，税率跳档后到手越少。';
    document.querySelectorAll('[data-chart]').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.chart === chartMode)));
  }

  /* ── 工资条 ── */
  function renderSlip() {
    const r = result.main.rows[month - 1];
    const strip = $('month-strip');
    strip.innerHTML = result.main.rows.map(x => `<button type="button" data-month="${x.month}" aria-pressed="${x.month === month}" class="${x.bonus > 0 ? 'has-bonus' : ''}">${x.month} 月<b>${x.active ? (x.net / 1000).toFixed(1) + 'k' : '—'}</b></button>`).join('');
    const picked = strip.querySelector('[aria-pressed="true"]');
    if (picked) strip.scrollLeft = picked.offsetLeft - strip.clientWidth / 2 + picked.offsetWidth / 2;
    $('receipt-title').textContent = `${month} 月工资条`;
    $('receipt-sub').textContent = `${result.city.name} · 社保基数 ${whole(result.insurance.base)} · 公积金基数 ${whole(result.insurance.fundBase)} × ${num(result.insurance.rate)}%`;
    $('receipt-pill').textContent = !r.active ? '未入职' : r.bonus > 0 ? '含年终奖' : '在职';
    $('receipt-pill').className = 'pill' + (r.bonus > 0 ? ' warn' : '');

    const income = [{ n: '月薪（应发）', v: r.gross }];
    if (r.bonus > 0) income.push({ n: '全年一次性奖金', v: r.bonus });
    $('receipt-income').innerHTML = income.map(x => line(x.n, x.v)).join('')
      + `<div class="rline sum"><span>应发合计</span><b>${money(r.gross + r.bonus)}</b></div>`;

    const ins = result.insurance.items;
    const deduct = [
      { n: '养老保险', s: '8%', v: r.active ? ins[0].value : 0, c: 'var(--si)' },
      { n: '医疗保险', s: num(result.city.medical) + '%' + (result.city.medicalFix ? ` + ${result.city.medicalFix} 元` : ''), v: r.active ? ins[1].value : 0, c: 'var(--si)' },
      { n: '失业保险', s: '0.5%', v: r.active ? ins[2].value : 0, c: 'var(--si)' },
      { n: '住房公积金', s: num(result.insurance.rate) + '%', v: r.fund, c: 'var(--fund)' },
      { n: '其他税前扣除', s: '年金 / 税优健康险', v: r.otherPre, c: 'var(--other)' },
      { n: '个人所得税（工资）', s: `预扣 ${Math.round(r.rate * 100)}% 档`, v: r.tax, c: 'var(--tax)' },
      { n: '个人所得税（年终奖）', s: result.bonusMode === 'separate' ? '单独计税' : '已并入上行', v: r.bonusTax, c: 'var(--tax)' },
      { n: '税后扣款', s: '工会费 / 餐费等', v: r.afterTax, c: 'var(--other)' }
    ].filter(x => x.v > 0);
    const deductSum = r.social + r.fund + r.otherPre + r.taxTotal + r.afterTax;
    $('receipt-deduct').innerHTML = (deduct.length ? deduct.map(x => line(x.n, -x.v, x.s, x.c)).join('') : '<div class="rline mute"><span>本月无扣款</span><b>0.00</b></div>')
      + `<div class="rline sum"><span>扣除合计</span><b style="color:var(--tax)">−${money(deductSum)}</b></div>`;
    $('receipt-net').textContent = '¥' + money(r.net);

    $('employer-switch').setAttribute('aria-pressed', String(showEmployer));
    $('employer-section').hidden = !showEmployer;
    if (showEmployer) {
      const er = [
        { n: '养老保险', s: '16%', v: ins[0].er }, { n: '医疗保险（含生育）', s: num(result.city.erMedical) + '%', v: ins[1].er },
        { n: '失业保险', s: '0.5%', v: ins[2].er }, { n: '工伤保险', s: num(result.city.injury) + '%', v: ins[3].er },
        { n: '住房公积金', s: num(result.insurance.rate) + '%', v: ins[4].er }
      ].map(x => ({ n: x.n, s: x.s, v: r.active ? x.v : 0, c: 'var(--sub)' }));
      const erSum = r.active ? result.insurance.employer : 0;
      $('receipt-employer').innerHTML = er.map(x => line(x.n, x.v, x.s, x.c)).join('')
        + `<div class="rline sum"><span>单位缴纳合计</span><b>${money(erSum)}</b></div>`
        + `<div class="rline mute"><span>公司为你付出的总成本</span><b>${money(r.gross + r.bonus + erSum)}</b></div>`;
      $('receipt-er-sum').textContent = money(erSum);
    }

    const n = result.main.rows.slice(0, month).filter(x => x.active).length;
    const prevPaid = C.r2(r.cumTax - r.tax);
    const steps = [
      ['累计收入', r.cumIncome], [`累计减除费用（5,000 × ${n} 个月）`, -5000 * n],
      ['累计三险一金', -(cumOf('social') + cumOf('fund'))],
      ['累计专项附加扣除', -cumOf('special')], ['累计其他税前扣除', -cumOf('otherPre')]
    ];
    $('tax-rate-pill').textContent = r.active ? `${Math.round(r.rate * 100)}% 档 · 速算 ${whole(r.quick)}` : '未入职';
    $('tax-steps').innerHTML = steps.map(([k, v]) => `<div class="rline mute"><span>${esc(k)}</span><b>${v < 0 ? '−' : ''}${money(Math.abs(v))}</b></div>`).join('')
      + `<div class="rline sum"><span>累计应纳税所得额</span><b>${money(r.cumTaxable)}</b></div>`
      + `<div class="rline"><span>累计应纳税额</span><b>${money(r.cumTax)}</b></div>`
      + `<div class="rline mute"><span>此前已预扣</span><b>${prevPaid > 0 ? '−' : ''}${money(prevPaid)}</b></div>`
      + `<div class="rline sum"><span style="color:var(--tax)">本月应预扣</span><b style="color:var(--tax)">${money(r.tax)}</b></div>`;
    $('tax-formula').innerHTML = r.active
      ? `<b>本月预扣</b> = 累计应纳税所得额 ${money(r.cumTaxable)} × ${Math.round(r.rate * 100)}% − 速算扣除数 ${whole(r.quick)} − 已预扣 ${money(prevPaid)} = <b>${money(r.tax)}</b>${r.bonusTax > 0 ? `<br><b>年终奖单独计税</b> = ${money(r.bonus)} ÷ 12 = ${money(r.bonus / 12)} → 适用 ${Math.round(bonusRate(r.bonus) * 100)}% 档，税额 ${money(r.bonusTax)}` : ''}`
      : '本月尚未入职，不参与累计预扣。入职当月起重新从 3% 档累计。';
  }
  const cumOf = key => C.r2(result.main.rows.slice(0, month).reduce((a, b) => a + b[key], 0));
  const bonusRate = b => (C.MONTH_TABLE.find(x => b / 12 <= x[0]) || C.MONTH_TABLE[6])[1];
  function line(name, value, sub, color) {
    const neg = value < 0;
    return `<div class="rline"><span>${color ? `<i style="background:${color}"></i>` : ''}${esc(name)}${sub ? ` <small>${esc(sub)}</small>` : ''}</span><b style="${neg ? `color:${color || 'var(--tax)'}` : ''}">${neg ? '−' : ''}${money(Math.abs(value))}</b></div>`;
  }

  /* ── 对比 ── */
  function renderCompare() {
    const bc = result.bonusCompare;
    $('bonus-amount-pill').textContent = bc.hasBonus ? '年终奖 ¥' + whole(result.main.bonus) : '未填年终奖';
    const card = (key, title, obj) => {
      const best = bc.hasBonus && bc.best === key;
      return `<article class="${best ? 'best' : ''}">${best ? '<span class="tag">更省税</span>' : ''}
        <h3>${title}</h3><div class="big rnd" style="color:${best ? 'var(--net)' : 'var(--ink)'}">${whole(obj.tax)}</div><div class="cap">全年个税合计（元）</div>
        <dl><div><dt>年终奖税额</dt><dd>${whole(obj.bonusTax)}</dd></div>
        <div><dt>工资部分税额</dt><dd>${whole(obj.tax - obj.bonusTax)}</dd></div>
        <div><dt>全年到手</dt><dd style="color:var(--net)">${whole(obj.net)}</dd></div></dl></article>`;
    };
    $('bonus-versus').innerHTML = card('separate', '单独计税', bc.separate) + card('merged', '并入综合所得', bc.merged);
    const d = $('bonus-delta');
    if (!bc.hasBonus) {
      d.className = 'delta flat';
      d.innerHTML = `<svg><use href="#warn"/></svg><span>还没有填年终奖。填上金额后，这里会直接告诉你哪种算法更省。</span>`;
    } else {
      d.className = 'delta';
      d.innerHTML = `<svg><use href="#up"/></svg><span>选 <b>${bc.best === 'separate' ? '单独计税' : '并入综合所得'}</b>，全年少交 <b>¥${whole(bc.saving)}</b>，摊到每月多拿 <b>¥${whole(bc.saving / 12)}</b>。${result.auto ? '当前已自动择优。' : `当前手动选了${result.bonusMode === 'separate' ? '单独计税' : '并入综合所得'}。`}</span>`;
    }
    $('bonus-trap').innerHTML = trapText(nOf(state.bonus));

    ['a', 'b'].forEach(k => {
      const o = k === 'a' ? offerA : offerB;
      document.querySelectorAll(`[data-offer="${k}"]`).forEach(el => {
        if (el === document.activeElement) return;
        el.value = String(o[el.dataset.key] ?? '');
      });
      const res = C.compute(o);
      $(`offer-${k}-net`).textContent = '¥' + whole(res.main.net);
      $(`offer-${k}-city`).textContent = res.city.name + ' · 月均 ' + whole(res.main.avgNet);
    });
    const ra = C.compute(offerA), rb = C.compute(offerB);
    const diff = C.r2(rb.main.net - ra.main.net);
    const grossDiff = C.r2((rb.main.gross + rb.main.bonus) - (ra.main.gross + ra.main.bonus));
    const od = $('offer-delta');
    od.className = 'delta' + (Math.abs(diff) < 1 ? ' flat' : '');
    od.innerHTML = Math.abs(diff) < 1
      ? `<svg><use href="#compare"/></svg><span>两份 offer 全年到手基本一样，可以比公积金比例、通勤和成长空间。</span>`
      : `<svg><use href="#${diff > 0 ? 'up' : 'compare'}"/></svg><span>B 比 A 全年${diff > 0 ? '多' : '少'}到手 <b>¥${whole(Math.abs(diff))}</b>（月均 ${whole(Math.abs(diff) / 12)}）。税前差 ${whole(Math.abs(grossDiff))} 元，实际落袋 ${grossDiff !== 0 ? pct(Math.abs(diff / grossDiff)) : '—'}。公积金另有 B ${wan(rb.main.fund)} 万 / A ${wan(ra.main.fund)} 万进个人账户。</span>`;
    const maxNet = Math.max(ra.main.net, rb.main.net, 1);
    $('offer-bars').innerHTML = [['A', ra.main.net, 'var(--sub)'], ['B', rb.main.net, 'var(--net)']]
      .map(([n, v, c]) => bar(`offer ${n} 全年到手`, '¥' + whole(v), v / maxNet, c)).join('');

    const m = C.marginal(state, raiseDelta);
    $('raise-read').textContent = '¥' + whole(raiseDelta);
    $('raise-slider').value = String(raiseDelta);
    $('marginal-pill').textContent = '落袋 ' + pct(m.keepRate);
    $('marginal-metrics').innerHTML = [
      ['全年多到手', whole(m.yearGain), '元'], ['月均多到手', whole(m.monthGain), '元'], ['被吃掉', whole(raiseDelta * 12 - m.yearGain), '元']
    ].map(([t, v, u]) => `<div class="metric"><span>${t}</span><strong>${esc(v)}</strong><small>${u}</small></div>`).join('');

    const t = result.main;
    const gross = t.gross + t.bonus;
    $('year-total-pill').textContent = '税前 ¥' + whole(gross);
    const items = [
      ['到手（打进工资卡）', t.net, 'var(--net)'], ['公积金个人部分', t.fund, 'var(--fund)'],
      ['社保个人部分', t.social, 'var(--si)'], ['个人所得税', t.taxTotal, 'var(--tax)'], ['税后扣款', t.afterTax, 'var(--other)']
    ].filter(x => x[1] > 0);
    const base = Math.max(gross, 1);
    $('year-bars').innerHTML = items.map(([n, v, c]) => bar(n, '¥' + whole(v) + ' · ' + pct(v / base), v / base, c)).join('');
    $('year-note').innerHTML = `单位另为你缴纳五险一金 <b style="color:var(--fund)">¥${whole(result.cost.employer)}</b>，公司总成本 ¥${whole(result.cost.total)}。全年综合税负 ${pct(result.effectiveRate)}，到手率 ${pct(result.netRate)}。公积金个人部分虽从工资里扣，但仍进你的账户。`;
  }
  function bar(name, value, ratio, color) {
    return `<div class="bar-item"><div><span>${esc(name)}</span><b>${esc(value)}</b></div><div class="bar-track"><i style="width:${clamp(ratio * 100, 0, 100).toFixed(1)}%;background:${color}"></i></div></div>`;
  }
  function trapText(bonus) {
    if (bonus <= 0) return '年终奖单独计税一年只能用一次；季度奖、绩效奖需并入综合所得。';
    const edges = [36000, 144000, 300000, 420000, 660000, 960000];
    for (const e of edges) {
      if (bonus > e && bonus - C.bonusTax(bonus) < e - C.bonusTax(e) - 0.01) {
        const target = e - C.bonusTax(e);
        const row = C.MONTH_TABLE.find(x => (e + 1) / 12 <= x[0]) || C.MONTH_TABLE[6];
        const fix = Math.ceil((target - row[2]) / (1 - row[1]));
        return `<b>落在跳档盲区：</b>发 ${whole(bonus)} 元的到手，比发 ${whole(e)} 元还少 ${whole((e - C.bonusTax(e)) - (bonus - C.bonusTax(bonus)))} 元。要么降到 ${whole(e)}，要么至少发到 ${whole(fix)}。`;
      }
    }
    const next = edges.find(e => e > bonus);
    return next
      ? `当前不在跳档盲区。下一个临界点是 ${whole(next)} 元，跨过后税率会从 ${Math.round(bonusRate(bonus) * 100)}% 跳到 ${Math.round(bonusRate(next + 1) * 100)}%。`
      : '当前不在跳档盲区，已适用最高 45% 档。';
  }

  /* ── 迷你结果条 ── */
  function renderSticky() {
    const r = result.main.rows[month - 1];
    $('sticky-label').textContent = `${month} 月到手`;
    $('sticky-value').textContent = '¥' + money(r.net);
  }
  function onScroll() {
    const show = scene === 'calc' && $('app-scroll').scrollTop > 300;
    $('sticky-net').classList.toggle('on', show);
  }

  /* ── 场景切换 ── */
  function showScene(next) {
    scene = next;
    ['calc', 'slip', 'compare'].forEach(k => { $('scene-' + k).hidden = k !== next; });
    document.querySelectorAll('[data-scene]').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.scene === next)));
    if (next === 'compare') { offerA = pickOffer(state); }
    if (document.activeElement && document.activeElement.blur) document.activeElement.blur();
    $('app-scroll').scrollTop = 0;
    recalc();
    onScroll();
    const first = $('scene-' + next);
    first.querySelectorAll('.enter').forEach(el => { el.style.animation = 'none'; void el.offsetWidth; el.style.animation = ''; });
  }

  /* ── 弹层 ── */
  function openSheet(title, html) {
    $('sheet-title').textContent = title;
    $('sheet-content').innerHTML = html;
    if (!$('sheet').open) $('sheet').showModal();
    $('sheet-content').scrollTop = 0;
  }
  const closeSheet = () => { if ($('sheet').open) $('sheet').close(); };

  function plansSheet() {
    openSheet('示例方案', `<p>下面是设计稿自带的示例参数，点一下即可套用。正式版本会按账户保存本机草稿与云端方案。</p>`
      + presets.map((p, i) => `<button type="button" class="preset" data-preset="${i}" aria-pressed="${i === activePreset}"><span><strong>${esc(p.name)}</strong><small>${esc(p.desc)}</small></span><span class="num">¥${whole(C.compute(p.data).main.avgNet)}/月</span></button>`).join('')
      + `<button type="button" class="btn primary" id="save-preset" style="width:100%;margin-top:6px">把当前参数存为示例方案</button>`);
  }
  function explainSheet() {
    const ytable = C.YEAR_TABLE.map((b, i) => {
      const lo = i ? C.YEAR_TABLE[i - 1][0] : 0;
      const label = b[0] === Infinity ? `超过 ${whole(lo)}` : `${whole(lo)} – ${whole(b[0])}`;
      const hit = result.main.rows[month - 1].cumTaxable > lo && result.main.rows[month - 1].cumTaxable <= b[0];
      return `<tr class="${hit ? 'hl' : ''}"><td>${label}</td><td>${Math.round(b[1] * 100)}%</td><td>${whole(b[2])}</td></tr>`;
    }).join('');
    const mtable = C.MONTH_TABLE.map((b, i) => {
      const lo = i ? C.MONTH_TABLE[i - 1][0] : 0;
      const label = b[0] === Infinity ? `超过 ${whole(lo)}` : `${whole(lo)} – ${whole(b[0])}`;
      return `<tr><td>${label}</td><td>${Math.round(b[1] * 100)}%</td><td>${whole(b[2])}</td></tr>`;
    }).join('');
    openSheet('怎么算的', `<h3>1 · 每月到手</h3><p>到手 = 税前月薪 + 当月年终奖 − 社保个人部分 − 公积金个人部分 − 当月预扣个税 − 税后扣款。公积金虽然扣走，但仍进你的个人账户。</p>
      <h3>2 · 累计预扣预缴（工资个税）</h3><p>本月预扣 =（累计收入 − 累计 5,000/月 − 累计三险一金 − 累计专项附加 − 累计其他扣除）× 税率 − 速算扣除数 − 此前已预扣。所以年初税少、跳档后税多，工资条上的到手会逐月变小。</p>
      <table><caption>综合所得年度税率表（高亮为当前累计所在档）</caption><thead><tr><th>累计应纳税所得额</th><th>税率</th><th>速算扣除</th></tr></thead><tbody>${ytable}</tbody></table>
      <h3>3 · 年终奖单独计税</h3><p>奖金 ÷ 12 找下表档位，税额 = 奖金 × 税率 − 速算扣除数。一年只能用一次，政策执行至 2027-12-31。也可以选择并入综合所得，页面会自动比较两者。</p>
      <table><caption>按月换算后的综合所得税率表</caption><thead><tr><th>奖金 ÷ 12</th><th>税率</th><th>速算扣除</th></tr></thead><tbody>${mtable}</tbody></table>
      <h3>4 · 口径与边界</h3><ul><li>只算居民个人工资薪金与全年一次性奖金，不含劳务报酬、股权激励、经营所得。</li><li>工伤、生育保险个人不缴；医疗含生育按各地合并口径示例。</li><li>社保与公积金基数按当地上下限截断，公积金比例 0–12%。</li><li>不含公益性捐赠、大病医疗汇算扣除与年度汇算补退税。</li><li>城市预设为示例值，正式接入前须按当地社保年度公布数据核对。</li></ul>`);
  }
  function standardSheet() {
    const rows = [
      ['子女教育', '每孩 2,000 元/月', '学前教育至全日制学历教育'],
      ['3 岁以下婴幼儿照护', '每孩 2,000 元/月', '可由父母一方或双方分摊'],
      ['赡养老人', '独生 3,000 元/月', '非独生分摊，每人不超过 1,500'],
      ['住房贷款利息', '1,000 元/月', '首套住房，最长 240 个月'],
      ['住房租金', '1,500 / 1,100 / 800 元/月', '按城市档位，与房贷利息二选一'],
      ['继续教育', '学历 400 元/月', '同一学历最长 48 个月；职业资格 3,600 元/年'],
      ['个人养老金', '最高 1,000 元/月', '全年 12,000 元限额，领取时另计税']
    ];
    openSheet('专项附加扣除标准', `<p>按现行标准列示，实际以个人所得税 App 中填报的额度为准。</p><table><thead><tr><th>项目</th><th>标准</th></tr></thead><tbody>${rows.map(r => `<tr><td>${r[0]}<div style="font-size:9.5px;opacity:.75;margin-top:3px">${r[2]}</div></td><td>${r[1]}</td></tr>`).join('')}</tbody></table>`);
  }
  function citiesSheet() {
    openSheet('城市社保预设（示例）', `<p>下表是设计稿内置的示例区间，量级参考各地社保年度公布数据，<b>不是实时口径</b>。选择「自定义」城市可以直接在参数台里填自己的上下限。</p>
      <table><thead><tr><th>城市</th><th>社保下限</th><th>社保上限</th><th>公积金上限</th></tr></thead><tbody>${C.CITIES.map(c => `<tr class="${c.key === state.city ? 'hl' : ''}"><td>${c.name}</td><td>${whole(c.floor)}</td><td>${whole(c.ceil)}</td><td>${whole(c.fundCeil)}</td></tr>`).join('')}</tbody></table>
      <h3>个人缴纳比例</h3><ul><li>养老 8%，失业 0.5%，工伤 / 生育个人不缴。</li><li>医疗各地不同，北京另加大病 3 元/月。</li><li>公积金 0–12%，单位与个人同比例。</li></ul>`);
  }
  function detailSheet() {
    const rows = result.main.rows.map(r => `<tr class="${r.month === month ? 'hl' : ''}" data-jump="${r.month}" style="cursor:pointer"><td>${r.month} 月</td><td>${whole(r.net)}</td><td>${whole(r.social + r.fund)}</td><td>${whole(r.taxTotal)}</td><td>${Math.round(r.rate * 100)}%</td></tr>`).join('');
    openSheet('全年逐月明细', `<p>点任意一行切到那个月的工资条。单位：元。</p><table><thead><tr><th>月份</th><th>到手</th><th>五险一金</th><th>个税</th><th>税率档</th></tr></thead><tbody>${rows}</tbody></table>
      <table style="margin-top:14px"><tbody><tr><td>全年合计</td><td>${whole(result.main.net)}</td><td>${whole(result.main.social + result.main.fund)}</td><td>${whole(result.main.taxTotal)}</td><td>—</td></tr></tbody></table>`);
  }
  function monthSheet() {
    openSheet('选择月份', `<p>切换主卡与工资条显示的月份。</p><div class="chips">${result.main.rows.map(r => `<button type="button" class="chip" data-jump="${r.month}" aria-pressed="${r.month === month}" style="min-width:74px;justify-content:center">${r.month} 月<small>${r.active ? (r.net / 1000).toFixed(1) + 'k' : '—'}</small></button>`).join('')}</div>`);
  }
  function exportSheet() {
    openSheet('导出工资条', `<p>纯文本工资条，可直接粘进备忘录或聊天窗口。</p><pre id="export-text">${esc(slipText())}</pre>
      <div class="actions"><button type="button" class="btn" id="sheet-copy"><svg><use href="#copy"/></svg>复制</button><button type="button" class="btn primary" id="sheet-download"><svg><use href="#share"/></svg>下载 .txt</button></div>`);
  }
  function slipText() {
    const r = result.main.rows[month - 1], ins = result.insurance.items;
    const L = [];
    L.push(`【${month} 月工资条 · 示例测算】`);
    L.push(`城市：${result.city.name} 社保基数：${whole(result.insurance.base)} 公积金基数：${whole(result.insurance.fundBase)} × ${num(result.insurance.rate)}%`);
    L.push('────────────────');
    L.push(`应发月薪     ${money(r.gross)}`);
    if (r.bonus > 0) L.push(`全年一次性奖金  ${money(r.bonus)}`);
    L.push(`应发合计     ${money(r.gross + r.bonus)}`);
    L.push('────────────────');
    if (r.active) {
      L.push(`养老保险 8%    −${money(ins[0].value)}`);
      L.push(`医疗保险      −${money(ins[1].value)}`);
      L.push(`失业保险 0.5%   −${money(ins[2].value)}`);
      L.push(`住房公积金      −${money(r.fund)}`);
    }
    if (r.otherPre > 0) L.push(`其他税前扣除    −${money(r.otherPre)}`);
    L.push(`个税（工资）    −${money(r.tax)} ${Math.round(r.rate * 100)}% 档`);
    if (r.bonusTax > 0) L.push(`个税（年终奖）  −${money(r.bonusTax)} 单独计税`);
    if (r.afterTax > 0) L.push(`税后扣款     −${money(r.afterTax)}`);
    L.push('────────────────');
    L.push(`实发到手     ${money(r.net)}`);
    L.push('────────────────');
    L.push(`全年到手 ${money(result.main.net)} 月均 ${money(result.main.avgNet)} 全年个税 ${money(result.main.taxTotal)}`);
    L.push(`年终奖口径：${result.bonusMode === 'separate' ? '单独计税' : '并入综合所得'}${result.auto ? '（自动择优）' : ''}`);
    L.push('按累计预扣预缴法测算，仅供设计预览参考。');
    return L.join('\n');
  }
  async function copySlip() {
    const text = slipText();
    let ok = false;
    try {
      if (navigator.clipboard && window.isSecureContext) { await navigator.clipboard.writeText(text); ok = true; }
    } catch { ok = false; }
    if (!ok) ok = legacyCopy(text);
    toast(ok ? '工资条已复制' : '复制失败，请在导出弹层里长按文本复制');
  }
  function legacyCopy(text) {
    const ta = document.createElement('textarea');
    ta.value = text; ta.setAttribute('readonly', '');
    ta.style.position = 'fixed'; ta.style.top = '0'; ta.style.left = '0'; ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select(); ta.setSelectionRange(0, text.length);
    let ok = false;
    try { ok = document.execCommand('copy'); } catch { ok = false; }
    ta.remove();
    return ok;
  }
  function downloadSlip() {
    const blob = new Blob([slipText()], { type: 'text/plain;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url; a.download = `工资条-${month}月-示例.txt`;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 2000);
    toast('已导出文本文件');
  }
  let toastTimer = 0;
  function toast(msg) {
    const el = $('toast');
    el.textContent = msg; el.classList.add('on');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove('on'), 1900);
  }

  /* ── 事件 ── */
  document.addEventListener('input', e => {
    const el = e.target;
    if (syncing) return;
    if (el.dataset && el.dataset.field) {
      const k = el.dataset.field;
      if (k === 'cityFloor' || k === 'cityCeil') {
        const custom = C.CITIES.find(c => c.key === 'custom');
        if (k === 'cityFloor') { custom.floor = Math.max(0, nOf(el.value)); custom.fundFloor = Math.min(custom.fundFloor, custom.floor); }
        else { custom.ceil = Math.max(custom.floor, nOf(el.value)); custom.fundCeil = custom.ceil; }
      } else state[k] = el.value;
      if (k === 'city') {
        const c = C.CITIES.find(x => x.key === el.value);
        state.fundRate = c.fund;
        if (offerA) offerA.city = el.value;
      }
      if (k === 'startMonth') month = Math.max(month, nOf(el.value));
      activePreset = -1;
      recalc();
    } else if (el.dataset && el.dataset.offer) {
      const o = el.dataset.offer === 'a' ? offerA : offerB;
      o[el.dataset.key] = el.value;
      renderCompare();
    } else if (el.id === 'raise-slider') {
      raiseDelta = nOf(el.value);
      renderCompare();
    }
  });

  document.addEventListener('click', e => {
    const t = e.target.closest('button,[data-month],[data-jump]');
    if (!t) return;
    const d = t.dataset;
    if (d.scene) return showScene(d.scene);
    if (d.month) { month = Number(d.month); recalc(); return; }
    if (d.jump) { month = Number(d.jump); closeSheet(); recalc(); return; }
    if (d.base) { state.baseMode = d.base; activePreset = -1; return recalc(); }
    if (d.fundbase) { state.fundMode = d.fundbase; activePreset = -1; return recalc(); }
    if (d.elder) { state.elder = d.elder; activePreset = -1; return recalc(); }
    if (d.housing) { state.housing = d.housing; activePreset = -1; return recalc(); }
    if (d.bonusmode) { state.bonusMode = d.bonusmode; activePreset = -1; return recalc(); }
    if (d.chart) { chartMode = d.chart; return renderChart(); }
    if (d.toggle === 'study') { state.study = !state.study; activePreset = -1; return recalc(); }
    if (d.step) {
      const k = d.step;
      state[k] = clamp(Math.round(nOf(state[k])) + Number(d.delta), 0, 6);
      activePreset = -1;
      return recalc();
    }
    if (d.preset !== undefined) {
      const i = Number(d.preset);
      Object.assign(state, presets[i].data);
      activePreset = i; month = Math.max(1, nOf(state.startMonth));
      offerA = pickOffer(state);
      closeSheet(); recalc(); toast('已套用：' + presets[i].name);
      return;
    }
    switch (t.id) {
      case 'theme-toggle': {
        const on = $('phone').classList.toggle('dark');
        t.setAttribute('aria-pressed', String(on));
        t.textContent = on ? '浅色' : '深色';
        renderChart();
        return;
      }
      case 'text-toggle': {
        const on = document.documentElement.classList.toggle('large-text');
        t.setAttribute('aria-pressed', String(on));
        return;
      }
      case 'plans-button': return plansSheet();
      case 'close-sheet': return closeSheet();
      case 'insight-button': case 'invite-button': return showScene('compare');
      case 'explain-button': return explainSheet();
      case 'standard-button': return standardSheet();
      case 'detail-button': return detailSheet();
      case 'export-button': return exportSheet();
      case 'slip-month-button': return monthSheet();
      case 'copy-slip-button': case 'sheet-copy': return copySlip();
      case 'download-slip-button': case 'sheet-download': return downloadSlip();
      case 'employer-switch': showEmployer = !showEmployer; return renderSlip();
      case 'sticky-top': $('app-scroll').scrollTo({ top: 0, behavior: 'smooth' }); return;
      case 'sync-offer-button': offerA = pickOffer(state); renderCompare(); return toast('A 已同步当前参数');
      case 'save-preset': {
        const snapshot = Object.assign({}, state);
        presets = presets.concat([{ name: `我的方案 ${presets.length - PRESETS.length + 1}`, desc: `${C.CITIES.find(c => c.key === state.city).name} · 月薪 ${whole(state.gross)} · 年终奖 ${whole(state.bonus)}`, data: snapshot }]);
        activePreset = presets.length - 1;
        plansSheet(); toast('已存为示例方案');
        return;
      }
      case 'reset-button': {
        Object.assign(state, C.defaults);
        const custom = C.CITIES.find(c => c.key === 'custom');
        custom.floor = 0; custom.ceil = 999999; custom.fundFloor = 0; custom.fundCeil = 999999;
        activePreset = 0; month = 1; chartMode = 'salary'; offerA = pickOffer(state);
        recalc(); toast('已恢复默认示例');
        return;
      }
      case 'random-button': {
        const pick = a => a[Math.floor(Math.random() * a.length)];
        const city = pick(C.CITIES.filter(c => c.key !== 'custom'));
        Object.assign(state, {
          city: city.key, gross: pick([12000, 18000, 25000, 32000, 45000, 60000, 80000]),
          fundRate: city.fund, bonus: pick([0, 20000, 36000, 60000, 120000, 200000]),
          children: pick([0, 1, 2]), infants: pick([0, 0, 1]), elder: pick(['only', 'share', 'none']),
          housing: pick(['loan', 'rent', 'none']), rentTier: pick([0, 1, 2]),
          study: Math.random() < .3, pension: pick([0, 0, 1000]), startMonth: 1, baseMode: 'auto', fundMode: 'auto'
        });
        activePreset = -1; offerA = pickOffer(state);
        recalc(); toast('换了一组示例参数');
        return;
      }
    }
    if (t.classList.contains('hit') || t.hasAttribute('data-month')) {
      month = Number(t.getAttribute('data-month'));
      recalc();
    }
  });

  $('plot').addEventListener('keydown', e => {
    const hit = e.target.closest('[data-month]');
    if (!hit) return;
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); month = Number(hit.dataset.month); recalc(); }
    if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
      e.preventDefault();
      month = clamp(month + (e.key === 'ArrowRight' ? 1 : -1), 1, 12);
      recalc();
      const next = $('plot').querySelector(`[data-month="${month}"]`);
      if (next) next.focus({ preventScroll: true });
    }
  });
    $('app-scroll').addEventListener('scroll', onScroll, { passive: true });
  $('sheet').addEventListener('click', e => { if (e.target === $('sheet')) closeSheet(); });
  document.querySelectorAll('.preview-tools button').forEach(b => b.setAttribute('type', 'button'));

  showScene('calc');
  globalThis.SalaryPreview = { get state() { return state; }, get result() { return result; }, setMonth: m => { month = m; recalc(); }, showScene };
})();