'use strict';
/* 房贷用到的利率历史（changelog §102）。只记变化的那几期，按日期升序；页面和 tests/check_mortgage_calc.cjs 共用。
 *
 * ⚠ 新的一期 LPR 变了（每月 20 日公布，节假日顺延）或公积金利率调了，就在这里加一行，再把 AS_OF 改成核对的日期。
 *   页面上「最新 LPR」「公积金利率」的默认值都从这里取；页面也会提示「利率表截至 AS_OF」。
 *
 * LPR：5 年期以上，全国银行间同业拆借中心每月公布。2019-08-20 起；在这之前放的商贷 2020 年转成了 LPR + 加点。
 *   2026-10-27 核对（逐月历史表 xa.bendibao.com/fangchan/2024223/124350.shtm；2024-10 那次按央行公告是 21 日）：
 *   2025-05-20 之后到 2026-10-20 每月都是 3.5%。
 * 公积金：5 年以上首套。存量贷款在调整后的次年 1 月 1 日起执行。
 *   2015-08-26 3.25%；2022-10-01 3.1%；2024-05-18 2.85%；2025-05-08 2.6%（2026-10-27 核对）。
 *   5 年及以下、二套是另外几档（现在 2.1% / 二套 5 年以上 3.075%），用到的时候在页面上直接填利率。
 */
(function (root) {
 const AS_OF = '2026-10-20';
 const LPR = [
  {date: '2019-08-20', rate: 4.85},
  {date: '2019-11-20', rate: 4.8},
  {date: '2020-02-20', rate: 4.75},
  {date: '2020-04-20', rate: 4.65},
  {date: '2022-01-20', rate: 4.6},
  {date: '2022-05-20', rate: 4.45},
  {date: '2022-08-22', rate: 4.3},
  {date: '2023-06-20', rate: 4.2},
  {date: '2024-02-20', rate: 3.95},
  {date: '2024-07-22', rate: 3.85},
  {date: '2024-10-21', rate: 3.6},
  {date: '2025-05-20', rate: 3.5},
 ];
 const FUND = [
  {date: '2015-08-26', rate: 3.25},
  {date: '2022-10-01', rate: 3.1},
  {date: '2024-05-18', rate: 2.85},
  {date: '2025-05-08', rate: 2.6},
 ];
 const api = {AS_OF, LPR, FUND};
 if (typeof module === 'object' && module.exports) module.exports = api;
 else root.MortgageRates = Object.freeze(api);
})(typeof self !== 'undefined' ? self : this);
