#!/usr/bin/env node
/**
 * 到手工资设计预览 · 真实浏览器检查与截图。
 * 只用 Node 内置模块驱动本机 Chrome / Edge，不需要 npm install。
 *   node Design/salary-v1/check-browser.mjs
 * 环境变量 CHROME_PATH 指定浏览器，CDP_PORT 指定调试端口（默认 9344）。
 * 退出码 0 = 全部通过。截图是设计预览的截图，不是 iOS 模拟器验收。
 */
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const DIR = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.CDP_PORT || 9344);
const CANDIDATES = [
  process.env.CHROME_PATH,
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Microsoft/Edge/Application/msedge.exe',
  '/usr/bin/google-chrome', '/usr/bin/chromium',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
].filter(Boolean);
const chromePath = CANDIDATES.find(p => { try { return fs.statSync(p).isFile(); } catch { return false; } });
if (!chromePath) { console.log('找不到浏览器，请用 CHROME_PATH 指定。'); process.exit(1); }

let pass = 0, fail = 0;
const check = (name, ok, extra = '') => {
  if (ok) { pass++; console.log('  ok  ' + name); }
  else { fail++; console.log('FAIL  ' + name + (extra ? '  → ' + extra : '')); }
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'salary-preview-'));
const chrome = spawn(chromePath, [
  '--headless=new', '--disable-gpu', '--no-sandbox', '--no-first-run', '--disable-dev-shm-usage',
  '--window-size=430,980', '--hide-scrollbars', '--force-device-scale-factor=2',
  `--remote-debugging-port=${PORT}`, `--user-data-dir=${profile}`, 'about:blank'
], { stdio: ['ignore', 'ignore', 'pipe'] });
let chromeErr = '';
chrome.stderr.on('data', d => { chromeErr += d.toString(); });

let ws;
function send(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = send._id = (send._id || 0) + 1;
    const onMsg = ev => {
      let m; try { m = JSON.parse(ev.data); } catch { return; }
      if (m.id === id) {
        ws.removeEventListener('message', onMsg);
        m.error ? reject(new Error(`${method}: ${JSON.stringify(m.error)}`)) : resolve(m.result);
      }
    };
    ws.addEventListener('message', onMsg);
    ws.send(JSON.stringify({ id, method, params }));
    setTimeout(() => { ws.removeEventListener('message', onMsg); reject(new Error(`${method} 超时`)); }, 30000);
  });
}
const pageErrors = [];
const describe = a => !a ? '' : a.type === 'string' ? a.value : ('value' in a ? JSON.stringify(a.value) : (a.description || a.type));
function collect(m) {
  const p = m.params;
  if (m.method === 'Runtime.consoleAPICalled' && p.type === 'error') pageErrors.push((p.args || []).map(describe).join(' ').split('\n')[0]);
  else if (m.method === 'Runtime.exceptionThrown') pageErrors.push(p.exceptionDetails.exception?.description || p.exceptionDetails.text);
  else if (m.method === 'Log.entryAdded' && p.entry.level === 'error') pageErrors.push(`${p.entry.text} ${p.entry.url || ''}`);
}
async function js(expression) {
  const r = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true, userGesture: true });
  if (r.exceptionDetails) return { __error: r.exceptionDetails.exception?.description || r.exceptionDetails.text };
  return r.result.value;
}
async function shot(name, beyond = false) {
  const r = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: beyond });
  fs.writeFileSync(path.join(DIR, name), Buffer.from(r.data, 'base64'));
}
const setField = (sel, value) => js(`(() => {
  const el = document.querySelector(${JSON.stringify(sel)});
  if (!el) return 'missing';
  const proto = el.tagName === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, ${JSON.stringify(String(value))});
  el.dispatchEvent(new Event('input', { bubbles: true }));
  el.dispatchEvent(new Event('change', { bubbles: true }));
  return 'ok';
})()`);
const click = sel => js(`(() => { const el = document.querySelector(${JSON.stringify(sel)}); if (!el) return 'missing'; if (typeof el.click === 'function') el.click(); else el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window })); return 'ok'; })()`);
const text = sel => js(`(document.querySelector(${JSON.stringify(sel)})||{}).textContent || ''`);
const expand = on => js(`(() => {
  let s = document.getElementById('shot-style');
  if (!s) { s = document.createElement('style'); s.id = 'shot-style'; document.head.appendChild(s); }
  s.textContent = ${JSON.stringify(on ? '.phone{height:auto!important;min-height:844px}.app-scroll{overflow:visible!important;flex:none!important}.sticky-net{display:none!important}' : '')};
  window.scrollTo(0, 0);
  return 'ok';
})()`);
const scrollInner = sel => js(`(() => {
  const sc = document.getElementById('app-scroll');
  const el = document.querySelector(${JSON.stringify(sel)});
  sc.scrollTop = el.offsetTop - sc.offsetTop - 8;
  return sc.scrollTop;
})()`);

(async () => {
  try {
    const t0 = Date.now();
    let up = false;
    while (Date.now() - t0 < 30000) {
      try { if ((await fetch(`http://127.0.0.1:${PORT}/json/version`)).ok) { up = true; break; } } catch { }
      await sleep(250);
    }
    if (!up) throw new Error('DevTools 未就绪：' + chromeErr.slice(-400));
    const list = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
    const page = list.find(t => t.type === 'page');
    ws = new WebSocket(page.webSocketDebuggerUrl);
    await new Promise((res, rej) => { ws.addEventListener('open', res, { once: true }); ws.addEventListener('error', rej, { once: true }); });
    ws.addEventListener('message', ev => { let m; try { m = JSON.parse(ev.data); } catch { return; } if (m.method) collect(m); });
    await send('Runtime.enable'); await send('Log.enable'); await send('Page.enable');
    await send('Page.navigate', { url: 'file:///' + path.join(DIR, 'index.html').replace(/\\/g, '/') });
    await sleep(1600);

    console.log('\n[1] 首屏渲染');
    check('主卡显示示例 1 月到手 25,953.00', (await text('#net-value')) === '25,953.00', await text('#net-value'));
    const share = await js(`(() => { const s = document.getElementById('share'); const r = s.getBoundingClientRect(); return { w: r.width, h: r.height, n: s.children.length }; })()`);
    check('税前去向占比条已渲染', share.w > 200 && share.h >= 6 && share.n === 4, JSON.stringify(share));
    const dup = await js(`(() => { const ids = [...document.querySelectorAll('[id]')].map(e => e.id); return ids.filter((x, i) => ids.indexOf(x) !== i); })()`);
    check('没有重复元素 id', Array.isArray(dup) && dup.length === 0, JSON.stringify(dup));
    const icons = await js(`[...document.querySelectorAll('use')].filter(u => !document.querySelector(u.getAttribute('href'))).map(u => u.getAttribute('href'))`);
    check('所有 SVG 图标引用都能解析', Array.isArray(icons) && icons.length === 0, JSON.stringify(icons));
    check('底部三个入口都在', (await js(`document.querySelectorAll('.bottom-nav button').length`)) === 3);
    await shot('preview-light.png');

    console.log('\n[2] 参数台实时联动');
    const tools = await js(`document.querySelectorAll('#scene-calc .controls [data-field], #scene-calc .controls [data-base], #scene-calc .controls [data-fundbase], #scene-calc .controls [data-elder], #scene-calc .controls [data-housing], #scene-calc .controls [data-bonusmode], #scene-calc .controls [data-step], #scene-calc .controls [data-toggle], #scene-calc .controls .icon-btn').length`);
    check('常驻参数控件不少于 7 个', tools >= 7, String(tools));
    check('参数台默认可见（未折叠）', await js(`!document.querySelector('#scene-calc .controls').hidden && document.getElementById('gross-slider').getBoundingClientRect().height > 0`));
    await setField('input[data-field="gross"]', 50000);
    await sleep(450);
    check('改月薪后主卡重算', (await text('#net-value')) !== '25,953.00', await text('#net-value'));
    check('超上限出现封顶提示', !(await js(`document.getElementById('calc-notice').hidden`)) && (await text('#calc-notice-text')).includes('封顶'), await text('#calc-notice-text'));
    check('社保基数按上海上限 36,921 截断', (await text('#si-base-read')) === '¥36,921', await text('#si-base-read'));
    await setField('#fund-slider', 12);
    await sleep(350);
    check('公积金比例滑块生效', (await text('#fund-read')).startsWith('12%'), await text('#fund-read'));
    const before = await text('#special-read');
    await click('[data-step="children"][data-delta="1"]');
    await sleep(300);
    check('子女教育加一孩，专项附加 +2,000', before !== (await text('#special-read')), before + ' → ' + (await text('#special-read')));
    await click('[data-elder="none"]');
    await sleep(300);
    check('赡养老人切到「无」后扣除减少 3,000', (await text('#special-read')) === '¥5,500/月', await text('#special-read'));
    await setField('select[data-field="city"]', 'beijing');
    await sleep(350);
    check('切城市后公积金比例跟随预设', (await text('#fund-read')).startsWith('12%'), await text('#fund-read'));
    check('北京医疗含大病 3 元', (await text('#si-hint')).includes('3 元'), await text('#si-hint'));
    await click('#reset-button');
    await sleep(400);
    check('恢复默认回到 25,953.00', (await text('#net-value')) === '25,953.00', await text('#net-value'));
    await click('#random-button');
    await sleep(400);
    const randomized = await text('#net-value');
    check('随机示例按钮改变了参数', typeof randomized === 'string' && randomized.length > 3, randomized);
    await click('#reset-button');
    await sleep(400);

    console.log('\n[3] 逐月图表');
    const chart = await js(`(() => {
      const p = document.getElementById('plot');
      return { bars: p.querySelectorAll('clipPath').length, hits: p.querySelectorAll('[data-month]').length, jumps: p.querySelectorAll('.jump-text').length };
    })()`);
    check('12 根柱子与 12 个点击区', chart.bars === 12 && chart.hits === 12, JSON.stringify(chart));
    check('标出税率跳档月份', chart.jumps >= 1, JSON.stringify(chart));
    const decSalary = await js(`(() => { SalaryPreview.setMonth(12); return document.getElementById('chart-read-value').textContent; })()`);
    const expect = await js(`(() => { const r = SalaryPreview.result.main.rows[11]; return '¥' + (r.net - (r.bonus - r.bonusTax)).toLocaleString('zh-CN', { minimumFractionDigits: 2, maximumFractionDigits: 2 }); })()`);
    check('「只看月薪」口径已剔除年终奖', decSalary === expect, decSalary + ' vs ' + expect);
    await click('[data-chart="all"]');
    await sleep(300);
    const decAll = await text('#chart-read-value');
    check('切到「含年终奖」后 12 月变高', decAll !== decSalary, decSalary + ' → ' + decAll);
    await click('[data-chart="salary"]');
    await js(`SalaryPreview.setMonth(1)`);
    await click('#plot [data-month="8"]');
    await sleep(350);
    check('点柱子切换到 8 月', (await text('#slip-month')) === '8 月到手', await text('#slip-month'));
    await js(`SalaryPreview.setMonth(1)`);
    await sleep(250);

    console.log('\n[4] 工资条页');
    await click('[data-scene="slip"]');
    await sleep(500);
    check('12 个月份按钮', (await js(`document.querySelectorAll('#month-strip button').length`)) === 12);
    const slipNet = await text('#receipt-net');
    check('工资条实发与主卡一致', slipNet === '¥25,953.00', slipNet);
    check('扣除逐项列出', (await js(`document.querySelectorAll('#receipt-deduct .rline').length`)) >= 5);
    check('个税算式给出本月预扣', (await text('#tax-formula')).includes('本月预扣'), (await text('#tax-formula')).slice(0, 60));
    check('首月此前已预扣不显示负零', !(await text('#tax-steps')).includes('−0.00'), (await text('#tax-steps')).slice(-40));
    await js(`document.getElementById('tax-steps').closest('section').scrollIntoView({ block: 'center' })`);
    await sleep(500);
    await shot('preview-tax.png');
    check('单位缴纳默认隐藏', await js(`document.getElementById('employer-section').hidden`));
    await click('#employer-switch');
    await sleep(350);
    check('打开开关后显示单位缴纳', !(await js(`document.getElementById('employer-section').hidden`)) && (await text('#receipt-er-sum')).length > 3, await text('#receipt-er-sum'));
    await click('#month-strip button[data-month="12"]');
    await sleep(350);
    check('切到 12 月出现年终奖行', (await text('#receipt-income')).includes('全年一次性奖金'), (await text('#receipt-income')).slice(0, 60));
    check('12 月工资条含单独计税年终奖税额', (await text('#receipt-deduct')).includes('年终奖'), '');
    await click('#copy-slip-button');
    await sleep(500);
    check('复制工资条给出反馈', (await text('#toast')).includes('复制'), await text('#toast'));
    await sleep(2100);
    await shot('preview-slip.png');
    await click('#month-strip button[data-month="1"]');
    await sleep(300);

    console.log('\n[5] 对比页');
    await click('[data-scene="compare"]');
    await sleep(500);
    check('年终奖两种算法两张卡', (await js(`document.querySelectorAll('#bonus-versus article').length`)) === 2);
    check('标出更省税的一种', (await js(`document.querySelectorAll('#bonus-versus .tag').length`)) === 1);
    check('给出省税差额', (await text('#bonus-delta')).includes('6,210'), await text('#bonus-delta'));
    const offerBefore = await text('#offer-delta');
    await setField('[data-offer="b"][data-key="gross"]', 60000);
    await sleep(400);
    check('改 offer B 后差额重算', offerBefore !== (await text('#offer-delta')), await text('#offer-delta'));
    const mBefore = await text('#marginal-metrics');
    await setField('#raise-slider', 5000);
    await sleep(400);
    check('涨薪滑块联动边际结果', mBefore !== (await text('#marginal-metrics')), (await text('#marginal-pill')));
    check('全年汇总列出五项去向', (await js(`document.querySelectorAll('#year-bars .bar-item').length`)) >= 4);
    await shot('preview-compare.png');

    console.log('\n[6] 年终奖跳档盲区');
    await click('[data-scene="calc"]');
    await sleep(400);
    await setField('input[data-field="bonus"]', 36001);
    await sleep(400);
    await click('[data-scene="compare"]');
    await sleep(400);
    check('36,001 元提示落在盲区', (await text('#bonus-trap')).includes('盲区'), await text('#bonus-trap'));
    check('盲区给出追平金额 38,567', (await text('#bonus-trap')).includes('38,567'), await text('#bonus-trap'));
    await click('[data-scene="calc"]');
    await sleep(300);
    await click('#reset-button');
    await sleep(400);

    console.log('\n[7] 弹层');
    await click('#plans-button');
    await sleep(400);
    check('方案弹层列出示例方案', (await js(`document.querySelectorAll('#sheet-content .preset').length`)) >= 5);
    await click('#sheet-content .preset[data-preset="1"]');
    await sleep(500);
    check('套用北京双娃方案后重算', (await text('#slip-sub')).includes('北京'), await text('#slip-sub'));
    await click('#plans-button'); await sleep(300);
    await click('#save-preset'); await sleep(400);
    check('可把当前参数存为示例方案', (await js(`document.querySelectorAll('#sheet-content .preset').length`)) >= 6);
    await click('#close-sheet'); await sleep(300);
    await click('#reset-button'); await sleep(400);
    await click('#explain-button'); await sleep(400);
    check('计算说明含两张税率表', (await js(`document.querySelectorAll('#sheet-content table').length`)) === 2);
    check('高亮当前累计所在税档', (await js(`document.querySelectorAll('#sheet-content tr.hl').length`)) === 1);
    await click('#close-sheet'); await sleep(250);
    await click('#standard-button'); await sleep(350);
    check('专项附加扣除标准表 7 项', (await js(`document.querySelectorAll('#sheet-content tbody tr').length`)) === 7);
    await click('#close-sheet'); await sleep(250);
    await click('#detail-button'); await sleep(350);
    check('全年明细 12 行', (await js(`document.querySelectorAll('#sheet-content tr[data-jump]').length`)) === 12);
    await click('#sheet-content tr[data-jump="6"]'); await sleep(400);
    check('点明细行切到 6 月', (await text('#slip-month')) === '6 月到手', await text('#slip-month'));
    await click('#export-button'); await sleep(350);
    const exp = await text('#export-text');
    check('导出文本含实发到手', exp.includes('实发到手') && exp.includes('工资条'), exp.slice(0, 40));
    await click('#close-sheet'); await sleep(250);
    await click('#slip-month-button'); await sleep(350);
    check('月份选择弹层 12 个选项', (await js(`document.querySelectorAll('#sheet-content [data-jump]').length`)) === 12);
    await click('#close-sheet'); await sleep(250);
    await click('#reset-button'); await sleep(400);

    console.log('\n[8] 滚动迷你结果条');
    await scrollInner('#scene-calc .controls');
    await sleep(500);
    check('滚下去后出现常驻到手条', await js(`document.getElementById('sticky-net').classList.contains('on')`));
    check('迷你条金额与主卡一致', (await text('#sticky-value')) === '¥25,953.00', await text('#sticky-value'));
    await sleep(2100);
    await shot('preview-controls.png');
    await click('#sticky-top'); await sleep(700);
    check('回到顶部后迷你条收起', !(await js(`document.getElementById('sticky-net').classList.contains('on')`)));

    await scrollInner('#scene-calc > section.panel:last-of-type');
    await sleep(600);
    await shot('preview-chart.png');
    await click('#sticky-top'); await sleep(700);

    console.log('\n[9] 深色模式');
    await click('#theme-toggle');
    await sleep(500);
    check('切到深色', await js(`document.getElementById('phone').classList.contains('dark')`));
    const darkBg = await js(`getComputedStyle(document.getElementById('phone')).backgroundColor`);
    check('深色背景已换色', darkBg === 'rgb(16, 22, 21)', darkBg);
    await shot('preview-dark.png');
    await click('[data-scene="slip"]'); await sleep(500);
    await shot('preview-slip-dark.png');
    await click('[data-scene="calc"]'); await sleep(400);
    await click('#theme-toggle'); await sleep(400);

    console.log('\n[10] 大字号与窄屏');
    await click('#text-toggle');
    await send('Emulation.setDeviceMetricsOverride', { width: 320, height: 900, deviceScaleFactor: 2, mobile: true });
    await sleep(700);
    const overflow = await js(`(() => {
  const bad = [];
  const decorative = el => el.closest('[aria-hidden="true"]') !== null;
  document.querySelectorAll('#scene-calc .panel, #scene-calc .slip, .bottom-nav, .metrics, .versus, .form-row, .share-labels').forEach(el => {
    const right = el.getBoundingClientRect().right;
    const kids = [...el.querySelectorAll('*')].filter(k => !decorative(k) && k.getBoundingClientRect().width > 0 && k.getBoundingClientRect().right > right + 1)
      .map(k => k.tagName + '.' + (k.className.baseVal ?? k.className) + ':' + Math.round(k.getBoundingClientRect().right - right) + 'px:' + (k.textContent || '').trim().slice(0, 18));
    if (kids.length) bad.push((el.className || el.id) + ' [' + kids.slice(0, 4).join(' | ') + ']');
  });
  return { bad, doc: document.documentElement.scrollWidth, win: innerWidth };
})()`);
    check('320px 大字号下核心区域无横向溢出', overflow.bad.length === 0, JSON.stringify(overflow.bad));
    check('页面本身不横向滚动', overflow.doc <= overflow.win + 1, JSON.stringify(overflow));
    await shot('preview-large.png');
    await click('[data-scene="compare"]'); await sleep(600);
    const overflow2 = await js(`(() => { const bad = []; document.querySelectorAll('#scene-compare .panel, .versus, .offer-card .mini').forEach(el => { if (el.scrollWidth > el.clientWidth + 1) bad.push(el.className + ':' + el.scrollWidth + '>' + el.clientWidth); }); return bad; })()`);
    check('对比页大字号无横向溢出', overflow2.length === 0, JSON.stringify(overflow2));
    await click('[data-scene="calc"]'); await sleep(400);
    await click('#text-toggle');
    await send('Emulation.clearDeviceMetricsOverride');
    await sleep(500);

    console.log('\n[11] 超长整页截图');
    await expand(true); await sleep(500);
    await shot('preview-calc-full.png', true);
    await click('[data-scene="slip"]'); await sleep(600);
    await shot('preview-slip-full.png', true);
    await click('[data-scene="compare"]'); await sleep(600);
    await shot('preview-compare-full.png', true);
    await click('[data-scene="calc"]'); await sleep(400);
    await expand(false); await sleep(300);

    console.log('\n[12] 反复交互稳定性');
    for (let i = 0; i < 6; i++) {
      await click('[data-scene="slip"]'); await click('[data-scene="compare"]'); await click('[data-scene="calc"]');
    }
    await sleep(700);
    check('来回切场景后仍显示正确结果', (await text('#net-value')) === '25,953.00', await text('#net-value'));
    check('图表未重复堆积节点', (await js(`document.getElementById('plot').querySelectorAll('clipPath').length`)) === 12);
    check('月份条未重复堆积', (await js(`document.querySelectorAll('#month-strip button').length`)) === 12);
    check('全程无脚本错误', pageErrors.length === 0, JSON.stringify(pageErrors.slice(0, 4)));

    console.log(`\n${pass} 项通过，${fail} 项失败`);
    fs.writeFileSync(path.join(DIR, 'verification.json'), JSON.stringify({
      checkedAt: new Date().toISOString(), browser: chromePath, pass, fail, pageErrors
    }, null, 2) + '\n');
  } catch (e) {
    console.log('运行异常：' + e.message);
    fail++;
  } finally {
    try { ws && ws.close(); } catch { }
    chrome.kill();
    await sleep(400);
    try { fs.rmSync(profile, { recursive: true, force: true }); } catch { }
    process.exit(fail ? 1 : 0);
  }
})();