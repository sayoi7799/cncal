// 通过真实的 chinese-days 包回答查询。
// 用法:node scripts/cd_query.js <包目录> < 请求.json > 响应.json
// 请求(都是可选的):
//   daily:   ["YYYY-MM-DD", …]          → [[日期, isWorkday(0/1), getDayDetail().work(0/1), getDayDetail().name], …]
//   add:     [["YYYY-MM-DD", n], …]     → findWorkday(n, 日期) 的结果日期
//   between: [["YYYY-MM-DD","YYYY-MM-DD"], …] → getWorkdaysInRange(起, 止) 的天数(两端都含)
const path = require("path");
const cd = require(path.resolve(process.argv[2]));
const api = cd.getDayDetail ? cd : cd.default;

const chunks = [];
process.stdin.on("data", (c) => chunks.push(c));
process.stdin.on("end", () => {
  const req = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  const res = {};
  if (req.daily) {
    res.daily = req.daily.map((d) => {
      const detail = api.getDayDetail(d);
      return [d, api.isWorkday(d) ? 1 : 0, detail.work ? 1 : 0, detail.name];
    });
  }
  if (req.add) {
    res.add = req.add.map(([d, n]) => api.findWorkday(n, d));
  }
  if (req.between) {
    res.between = req.between.map(([a, b]) => api.getWorkdaysInRange(a, b).length);
  }
  process.stdout.write(JSON.stringify(res));
});
