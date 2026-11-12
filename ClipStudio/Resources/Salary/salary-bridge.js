/* Native input/output adapter. The calculation itself is the unchanged Design/salary-v1 engine. */
(function (root) {
  'use strict';
  const C = root.SalaryCalc;
  const EDGES = [36000, 144000, 300000, 420000, 660000, 960000];
  const rowOf = bonus => C.MONTH_TABLE.find(x => bonus / 12 <= x[0]) || C.MONTH_TABLE[C.MONTH_TABLE.length - 1];
  // JSON has no Infinity; the open-ended top bracket travels as null.
  const table = rows => rows.map(row => [Number.isFinite(row[0]) ? row[0] : null, row[1], row[2]]);

  function trap(bonus) {
    if (!(bonus > 0)) return { state: 'empty' };
    for (const edge of EDGES) {
      const net = bonus - C.bonusTax(bonus), edgeNet = edge - C.bonusTax(edge);
      if (bonus > edge && net < edgeNet - 0.01) {
        const row = rowOf(edge + 1);
        return { state: 'blind', edge, loss: C.r2(edgeNet - net), fix: Math.ceil((edgeNet - row[2]) / (1 - row[1])) };
      }
    }
    const next = EDGES.find(edge => edge > bonus);
    if (!next) return { state: 'top' };
    return { state: 'below', next, fromRate: rowOf(bonus)[1], toRate: rowOf(next + 1)[1] };
  }

  root.NativeSalary = {
    defaults: () => JSON.stringify(C.defaults),
    cities: () => JSON.stringify(C.CITIES),
    tables: () => JSON.stringify({ year: table(C.YEAR_TABLE), month: table(C.MONTH_TABLE), special: C.SPECIAL, standard: C.STANDARD }),
    compute: data => JSON.stringify(C.compute(JSON.parse(data))),
    marginal: (data, delta) => JSON.stringify(C.marginal(JSON.parse(data), delta)),
    bonusTrap: bonus => JSON.stringify(trap(bonus))
  };
})(this);