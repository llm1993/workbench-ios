(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const drafts = JSON.parse(NativeMortgage.defaults());
  // The preview contract is deliberately a labelled example; never read an account or cloud draft.
  drafts.current.parts[0] = {...JSON.parse(NativeMortgage.part()), amount:210, start:'2021-06-15', bp:-45};
  let scene = 'trial', kind = 'new', strategy = 'term', expanded = false, calculation;
  const titles = {trial:'买房试算',current:'我的房贷',prepayment:'提前还款'};
  const subtitles = {trial:'算清每月开支，从容计划一个家。',current:'从放款到结清，看清你的还款进度。',prepayment:'少付多少利息，早多久还清。'};
  const money = n => Number(n).toLocaleString('zh-CN',{minimumFractionDigits:2,maximumFractionDigits:2});
  const num = n => Number(n).toLocaleString('zh-CN',{maximumFractionDigits:2});
  const wan = n => num(n/10000);
  const esc = s => String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const typeName = t => ({commercial:'商业贷款',fund:'公积金贷款',combo:'组合贷款'})[t];
  const methodName = t => t==='principal'?'等额本金':'等额本息';
  const resultKey = () => scene==='prepayment' ? strategy : 'base';
  const saved = key => Math.max(0,calculation.base.interest-calculation[key].interest);
  const savedMonths = key => Math.max(0,kind==='new'&&key==='term'?calculation.savedMonths:calculation.base.months-calculation[key].months);
  function payment(key=resultKey()) { return calculation[key]?.rows[scene==='prepayment'?calculation.after:0]?.payment || 0; }
  function metric(title,value,unit) { return `<div class="metric"><span>${title}</span><strong>${esc(value)}</strong><small>${unit}</small></div>`; }
  function fact(title,value) { return `<div><span>${title}</span><strong>${esc(value)}</strong></div>`; }
  function showScene(next) {
    scene=next;
    if(scene==='trial')kind='new';
    if(scene==='current')kind='current';
    expanded=scene==='prepayment';
    render(true);
    $('app-scroll').scrollTop=0;
  }
  function render(form=false) {
    $('scene-title').textContent=titles[scene];
    $('scene-subtitle').textContent=subtitles[scene];
    $('draft-label').textContent=kind==='current'?'示例合同':'本机草稿';
    document.querySelectorAll('[data-scene]').forEach(b=>b.setAttribute('aria-pressed',b.dataset.scene===scene));
    const d=drafts[kind], pre=scene==='prepayment';
    try {
      calculation=JSON.parse(NativeMortgage.calculate(kind,JSON.stringify(d),'2026-11-11'));
      if(pre&&!calculation[strategy])throw new Error('请设置有效的提前还款金额和时间。');
      $('error').hidden=true;
      document.querySelector('.summary').hidden=false;
      document.querySelector('.chart-panel').hidden=false;
      const result=calculation[resultKey()];
      $('payment-title').textContent=pre?'提前还款后月供':kind==='current'?'预计下期还款':d.method==='principal'?'预计首月还款':'预计每月还款';
      $('payment-badge').textContent=pre?(strategy==='term'?'缩短年限':'减少月供'):kind==='current'?'按合同测算':d.method==='principal'?'逐月递减':'每月固定';
      $('monthly-value').textContent=money(payment());
      const rate=d.type==='fund'?Number(d.fundRate):Number(d.lpr)+Number(d.bp)/100;
      let meta=kind==='current'?`1 笔合同 / 未来 ${result.months} 期 / 含历史利率调整`:`${typeName(d.type)} / ${wan(calculation.total)} 万元 / ${d.years} 年 / ${d.type==='combo'?'分笔计息':'年利率 '+num(rate)+'%'}`;
      if(pre) {
        const planned=Number(kind==='current'?d.extraAmount:d.preAmount)*10000;
        const actual=kind==='current'&&calculation.after===0?Math.min(planned,calculation.parts[Number(d.extraPart)||0].balance):(result.rows.find(r=>r.n===calculation.after)?.prepay||0);
        meta=`实际提前还 ${wan(actual)} 万元 / ${calculation.after===0?'现在还款':'第 '+calculation.after+' 期后'} / 第 ${calculation.after+1} 期起`;
        if(Math.abs(planned-actual)>.01)meta+=` / 计划 ${wan(planned)} 万元`;
      }
      $('payment-meta').textContent=meta;
      $('cost-share').hidden=pre||kind==='current';
      const fraction=calculation.total/(calculation.total+result.interest);
      $('principal-bar').style.width=`${fraction*100}%`;
      $('principal-ratio').textContent=`本金 ${num(fraction*100)}%`;
      $('interest-ratio').textContent=`利息 ${num((1-fraction)*100)}%`;
      $('cost-bar').setAttribute('aria-label',`本金占累计还款的 ${num(fraction*100)}%，其余为利息`);
      if(pre) $('metrics').innerHTML=metric('节省利息',wan(saved(strategy)),'万元')+metric(kind==='new'&&d.type==='combo'&&strategy==='term'?'目标贷款缩短':'提前还清',savedMonths(strategy),'个月')+metric(kind==='current'?'未来还款':'累计还款',wan(calculation.total+result.interest),'万元');
      else if(kind==='current') $('metrics').innerHTML=metric('剩余本金',wan(calculation.total),'万元')+metric('已付利息',wan(calculation.parts.reduce((s,p)=>s+p.paidInterest,0)),'万元')+metric('未来利息',wan(result.interest),'万元');
      else $('metrics').innerHTML=metric('贷款总额',wan(calculation.total),'万元')+metric('利息总额',wan(result.interest),'万元')+metric('累计还款',wan(calculation.total+result.interest),'万元');
      $('insight-text').textContent=pre?(strategy==='term'?(kind==='new'&&d.type==='combo'?'缩短的是所选贷款，组合贷整体结清时间可能不变。':'月供或每期本金基本不变，更早还清所选贷款。'):'保留剩余期数，给每月开支留一点余地。'):kind==='current'?'未来按现有利率表推算，可用银行剩余本金校准。':`等额本金比等额本息，少付 ${wan(calculation.equal.interest-calculation.principal.interest)} 万元利息。`;
      $('compare-label').textContent=pre?'比较两种还法':kind==='current'?'查看还款计划':'对比还款方式';
      $('quick-facts').innerHTML=kind==='new'&&!pre?fact('贷款金额',wan(calculation.total)+' 万')+fact('贷款年限',d.years+' 年')+fact(d.type==='combo'?'贷款类型':'年利率',d.type==='combo'?'组合贷款':num(rate)+'%'):`<p>${kind==='current'?'1 笔示例合同 · 历史调整与还款记录':'沿用当前贷款，调整提前还款金额和时间'}</p>`;
      $('progress-panel').hidden=scene!=='current';
      if(scene==='current') {
        const p=calculation.parts[0];
        $('progress-panel').innerHTML=`<div class="progress-title"><strong>合同 1 的还款进度</strong><span>${p.paidCount} / ${p.total} 期</span></div><div class="progress-track"><span style="width:${p.paidCount/p.total*100}%"></span></div><div class="progress-stats"><span>已还本金</span><b>${money(p.paidPrincipal)} 元</b></div><div class="progress-stats"><span>当前利率</span><b>${num(p.rateNow)}%</b></div>`;
      }
      drawChart();
      $('invitation').hidden=pre;
      $('invitation-copy').textContent=calculation.term?`按当前提前还款设置，缩短年限可少付 ${wan(saved('term'))} 万元利息。`:'选个时间和金额，看看利息能少多少。';
      $('rates-date').textContent=`默认利率表截至 ${calculation.asOf}，非实时报价，可手动修改。`;
    } catch(e) {
      $('error').hidden=false;$('error').textContent=e.message;
      document.querySelector('.summary').hidden=true;document.querySelector('.chart-panel').hidden=true;
      $('invitation').hidden=true;$('progress-panel').hidden=true;expanded=true;
    }
    $('parameters-title').textContent=pre?'提前还款设置':kind==='current'?'贷款合同':'贷款参数';
    $('parameter-action').textContent=expanded?'收起⌃':'修改⌄';
    $('parameter-toggle').setAttribute('aria-expanded',expanded);
    $('parameter-form').hidden=!expanded;$('quick-facts').hidden=expanded;
    if(form)renderForm();
  }
  function input(key,title,value,type='number',attr='') {
    return `<label class="field"><span>${title}</span><input data-field="${key}" type="${type}" value="${esc(value)}" ${attr}></label>`;
  }
  function select(key,title,value,options) {
    return `<label class="field"><span>${title}</span><select data-field="${key}">${options.map(([id,name])=>`<option value="${id}" ${String(value)===id?'selected':''}>${name}</option>`).join('')}</select></label>`;
  }
  function renderForm() {
    const d=drafts[kind];let content='';
    if(scene==='prepayment') {
      content+=select('source','基于哪份贷款计算',kind,[['new','买房试算'],['current','我的房贷（示例合同）']]);
      content+=input(kind==='new'?'preAmount':'extraAmount','计划提前还（万元）',kind==='new'?d.preAmount:d.extraAmount,'number','min="0" step="1"');
      content+=input(kind==='new'?'preMonth':'extraWhen',kind==='new'?'还满多少期后':'现在之后第几期（0 = 马上）',kind==='new'?d.preMonth:d.extraWhen,'number','min="0" step="1"');
      if(kind==='new'&&d.type==='combo')content+=select('prePart','提前还哪一笔',d.prePart,[['commercial','商业贷款'],['fund','公积金贷款']]);
      content+=`<button type="button" class="choice" data-strategy="term" aria-pressed="${strategy==='term'}"><span>${strategy==='term'?'◉':'○'}</span><strong>缩短年限<small>月供或每期本金基本不变，更早还清</small></strong></button><button type="button" class="choice" data-strategy="payment" aria-pressed="${strategy==='payment'}"><span>${strategy==='payment'?'◉':'○'}</span><strong>减少月供<small>保留剩余期数，每月压力更小</small></strong></button>`;
    } else if(kind==='new') {
      content+=select('type','贷款类型',d.type,[['commercial','商业贷款'],['fund','公积金贷款'],['combo','组合贷款']]);
      content+=select('by','金额填写方式',d.by,[['price','按房价和首付'],['amount','直接填贷款额']]);
      content+=input(d.by==='price'?'price':'amount',d.by==='price'?'房屋总价（万元）':'贷款金额（万元）',d.by==='price'?d.price:d.amount,'number','min="0" step="1"');
      if(d.by==='price')content+=input('down','首付比例（%）',d.down,'number','min="0" max="99.9"');
      if(d.type==='combo')content+=input('fundAmount','其中公积金贷款（万元）',d.fundAmount,'number','min="0"');
      content+=input('years','贷款年限（年）',d.years,'number','min="1" max="30" step="1"');
      if(d.type!=='fund')content+=`<div class="form-row">${input('lpr','5 年期以上 LPR（%）',d.lpr,'number','step=".05"')}${input('bp','加点（基点，可负）',d.bp,'number','step="1"')}</div>`;
      if(d.type!=='commercial')content+=input('fundRate','公积金年利率（%）',d.fundRate,'number','step=".05"');
      content+=`<div class="seg" role="group" aria-label="还款方式"><button type="button" data-method="equal" aria-pressed="${d.method==='equal'}">等额本息</button><button type="button" data-method="principal" aria-pressed="${d.method==='principal'}">等额本金</button></div>`;
    } else {
      const p=d.parts[0];
      content+=`<p class="form-caption">以下为独立示例合同，不代表你的实际贷款。</p>`;
      content+=input('part.amount','原始金额（万元）',p.amount,'number','min="0"');
      content+=input('part.years','合同年限（年）',p.years,'number','min="1" max="30"');
      content+=input('part.start','放款日期',p.start,'date');
      content+=input('part.bp','初始加点（基点）',p.bp);
      content+=input('part.bank','银行剩余本金（元，可空）',p.bank);
    }
    $('form-fields').innerHTML=content;
  }
  function series() {
    return (scene==='prepayment'?[['base','原还款计划'],[strategy,'提前还款后']]:kind==='current'?[['base','剩余本金']]:[['equal','等额本息'],['principal','等额本金']]).map(([key,title])=>{
      let balance=calculation.total;
      if(scene==='prepayment'&&kind==='current'&&calculation.after===0&&key!=='base')balance-=Math.min(Number(drafts.current.extraAmount)*10000,calculation.parts[Number(drafts.current.extraPart)||0].balance);
      return {key,title,points:[{n:0,balance},...calculation[key].rows]};
    });
  }
  function drawChart() {
    const ss=series(),months=Math.max(1,...ss.flatMap(s=>s.points.map(p=>p.n))),maximum=Math.max(1,...ss.flatMap(s=>s.points.map(p=>p.balance)));
    const x=n=>32+n/months*268,y=b=>164-b/maximum*148;
    let marks='';
    for(const fraction of [1,.5,0])marks+=`<line x1="32" x2="300" y1="${y(maximum*fraction)}" y2="${y(maximum*fraction)}" stroke="var(--line)"/><text x="25" y="${y(maximum*fraction)+3}" text-anchor="end">${num(maximum*fraction/10000)}</text>`;
    for(const m of [0,Math.round(months/2),months])marks+=`<text x="${x(m)}" y="186" text-anchor="${m===0?'start':m===months?'end':'middle'}">${m===0?'现在':num(m/12)+' 年'}</text>`;
    ss.forEach((s,i)=>{
      const points=s.points.filter((_,j)=>j%3===0||j===s.points.length-1);
      const line=points.map((p,j)=>`${j?'L':'M'}${x(p.n).toFixed(2)},${y(p.balance).toFixed(2)}`).join(' ');
      if(i===0)marks+=`<path d="${line} L${x(points.at(-1).n)},164 L32,164Z" fill="var(--series1)" opacity=".07"/>`;
      marks+=`<path d="${line}" fill="none" stroke="var(--series${i+1})" stroke-width="2" ${i?'stroke-dasharray="5 4"':''}/>`;
    });
    $('plot').innerHTML=`<title>剩余本金走势，单位万元</title>${marks}`;
    $('legend').innerHTML=ss.map(s=>`<span><i></i>${s.title}</span>`).join('');
    $('chart-title').textContent=scene==='prepayment'?'提前还款前后':'本金还款走势';
    $('chart-subtitle').textContent=scene==='prepayment'?'原计划与提前还款后的剩余本金':kind==='current'?'未来利率按现有利率表推算':'两种还款方式的剩余本金变化';
  }
  function openSheet(title,content) { $('sheet-title').textContent=title;$('sheet-content').innerHTML=content;$('sheet').showModal(); }
  function comparison() {
    if(kind==='current'&&scene!=='prepayment'){schedule();return;}
    const pre=scene==='prepayment';
    openSheet(pre?'提前还款，怎么选？':'两种还法，放在一起看',`<div class="comparison">${(pre?['term','payment']:['equal','principal']).map(key=>{
      const r=calculation[key],title=pre?(key==='term'?'缩短年限':'减少月供'):methodName(key);
      return `<article><h3>${title}</h3><p>${pre?'提前还款后月供':key==='principal'?'首月还款':'每月还款'}</p><div class="payment">¥ ${money(pre?payment(key):r.rows[0]?.payment||0)}</div><p>${pre?'节省利息':'利息总额'}<b>${wan(pre?saved(key):r.interest)} 万元</b></p><p>${pre?'提前还清':'还款节奏'}<b>${pre?savedMonths(key)+' 个月':key==='equal'?'每月相同':'逐月递减'}</b></p><p>${kind==='current'?'未来还款':'累计还款'}<b>${wan(calculation.total+r.interest)} 万元</b></p><button type="button" data-choose="${key}">${(pre?strategy:drafts.new.method)===key?'已选用':'选用此方式'}</button></article>`;
    }).join('')}</div>`);
  }
  function schedule() {
    const rows=calculation[resultKey()].rows;let content='<table><caption>按年汇总 · 单位：元</caption><thead><tr><th>期次</th><th>还款（含提前还）</th><th>其中利息</th></tr></thead><tbody>';
    for(let i=0;i<rows.length;i+=12){const year=rows.slice(i,i+12);content+=`<tr><td>第 ${i/12+1} 年</td><td>${money(year.reduce((s,r)=>s+r.payment+r.prepay,0))}</td><td>${money(year.reduce((s,r)=>s+r.interest,0))}</td></tr>`;}
    openSheet('还款计划明细',content+'</tbody></table>');
  }
  $('parameter-toggle').onclick=()=>{expanded=!expanded;render(true);};
  $('collapse-button').onclick=()=>{expanded=false;render();};
  $('invitation').onclick=()=>showScene('prepayment');
  document.querySelectorAll('[data-scene]').forEach(button=>button.onclick=()=>showScene(button.dataset.scene));
  $('parameter-form').onsubmit=e=>e.preventDefault();
  $('parameter-form').addEventListener('input',e=>{
    const key=e.target.dataset.field;if(!key)return;
    if(key==='source'){kind=e.target.value;render(true);return;}
    if(key.startsWith('part.'))drafts.current.parts[0][key.slice(5)]=e.target.value;
    else drafts[kind][key]=e.target.value;
    render(['type','by'].includes(key));
  });
  $('parameter-form').addEventListener('click',e=>{
    const method=e.target.closest('[data-method]'),choice=e.target.closest('[data-strategy]');
    if(method){drafts.new.method=method.dataset.method;render(true);}
    if(choice){strategy=choice.dataset.strategy;render(true);}
  });
  $('compare-button').onclick=comparison;$('schedule-button').onclick=schedule;
  $('chart-data-button').onclick=()=>{
    const ss=series(),last=Math.max(...ss.flatMap(s=>s.points.map(p=>p.n))),months=[...new Set([...Array.from({length:Math.ceil(last/12)},(_,i)=>i*12),last])];
    openSheet('剩余本金数据',`<table><caption>每年取一个期次 · 单位：万元</caption><thead><tr><th>期次</th>${ss.map(s=>`<th>${s.title}</th>`).join('')}</tr></thead><tbody>${months.map(m=>`<tr><td>${m===0?'还款起点':'第 '+m+' 期'}</td>${ss.map(s=>`<td>${wan(s.points.find(p=>p.n===m)?.balance||0)}</td>`).join('')}</tr>`).join('')}</tbody></table>`);
  };
  $('sheet-content').onclick=e=>{const button=e.target.closest('[data-choose]');if(!button)return;if(scene==='prepayment')strategy=button.dataset.choose;else drafts.new.method=button.dataset.choose;$('sheet').close();render(expanded);};
  $('close-sheet').onclick=()=>$('sheet').close();
  $('plans-button').onclick=()=>openSheet('方案', '<p>此处用于预览新版界面。正式 App 保留保存到云端、另存、载入、删除及多设备冲突处理。</p>');
  $('theme-toggle').onclick=()=>{const dark=$('phone').classList.toggle('dark');$('theme-toggle').setAttribute('aria-pressed',dark);$('theme-toggle').textContent=dark?'浅色':'深色';};
  $('text-toggle').onclick=()=>{const large=document.body.classList.toggle('large-text');$('text-toggle').setAttribute('aria-pressed',large);};
  render(true);
})();
