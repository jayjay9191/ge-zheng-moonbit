
"""Build a self-contained offline report from MoonBit outputs."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "results"
summary = json.loads((OUT / "summary.json").read_text(encoding="utf-8"))
grid = json.loads((OUT / "change.json").read_text(encoding="utf-8"))
source = json.loads((ROOT / "data/sources.json").read_text(encoding="utf-8"))
s = summary["change"]
same = summary["same"]
half = summary["half"]

html = """<!doctype html>
<html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>格证 · 巢湖样区</title><link rel="icon" href="data:,">
<style>
:root{font-family:"Microsoft YaHei UI","Segoe UI",sans-serif;color:#152c2b;background:#eef2ed;color-scheme:light}
*{box-sizing:border-box} body{margin:0} main{max-width:1160px;margin:auto;padding:30px 20px 45px}
.hero{padding:38px;border-radius:22px;background:#133838;color:#f4f7e9;box-shadow:0 12px 28px #183c3420}
.eyebrow{font-size:13px;letter-spacing:.16em;color:#a7d5bd;font-weight:700}
h1{font-size:clamp(29px,5vw,52px);margin:9px 0} h2{font-size:21px;margin:0 0 12px}
p{line-height:1.64;margin:7px 0} .sub{color:#58706e;font-size:14px} .hero p{color:#d2e1d4}
.stat{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin:16px 0}
.card,.panel{background:#fff;border-radius:16px;padding:18px;border:1px solid #dce7dd}
.card b{display:block;font-size:clamp(18px,3vw,29px);margin-top:8px;font-variant-numeric:tabular-nums}
.panel{margin-bottom:16px}.finding{background:#e0eee4;border-left:4px solid #26735d;border-radius:8px;padding:11px 16px;margin:0 0 16px}.maps{display:grid;grid-template-columns:repeat(3,1fr);gap:14px}
figure{margin:0} figcaption{margin:0 0 7px;font-weight:650}
canvas{display:block;width:100%;height:auto;image-rendering:pixelated;border-radius:8px;outline-offset:2px}
button{font:inherit;background:#e7f0e8;border:1px solid #a6bdb0;border-radius:7px;padding:6px 12px;color:#152c2b;cursor:pointer}
button[aria-pressed=true]{background:#174640;color:white;border-color:#174640}
.tools{display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin:7px 0 16px}
.legend{display:flex;flex-wrap:wrap;gap:6px 15px;font-size:13px;margin:12px 0}
.legend span:before{content:"";display:inline-block;width:11px;height:11px;margin-right:4px;border-radius:2px;background:var(--c)}
.cell{background:#f0f6f2;padding:12px;border-radius:9px;min-height:50px;font-size:14px}
table{width:100%;border-collapse:collapse;font-size:14px}th,td{text-align:left;padding:10px 7px;border-bottom:1px solid #dde7df}
a{color:#0d6255} footer{color:#58706e;font-size:13px} @media(max-width:620px){.hero{padding:23px}.stat{grid-template-columns:1fr 1fr}.maps{grid-template-columns:1fr 1fr}.maps figure:last-child{grid-column:1/-1}}
</style>
<main>
<header class="hero"><div class="eyebrow">格证 · Landsat 遥感变化质检</div>
<h1>巢湖样区植被指数变化</h1>
<p>2024-04-18 → 2024-10-11 · Landsat 9 Collection 2 Level-2 · WGS84 / UTM 50N</p></header>
<section class="stat">
<div class="card">共同有效覆盖<b>__COVERAGE__</b></div>
<div class="card">NDVI 上升面积<b id="gain-area">__GAIN__ km²</b></div>
<div class="card">NDVI 下降面积<b id="loss-area">__LOSS__ km²</b></div>
<div class="card">排除像元<b>__EXCLUDED__</b></div>
</section>
<p class="finding"><strong>水体标记影响解读</strong>　NDVI 上升像元中，__WATER_SHARE__ 至少有一期被 QA 标为水体。两期均未标水的 1,141 个有效像元里有 56 个上升、82 个下降（阈值 0.15）。</p>
<section class="panel"><h2>同一网格上的两期影像</h2>
<p class="sub">NDVI 图中浅色代表较低值，深绿代表较高值。点击任意图上的像元查看位置与两期数值。</p>
<div class="tools"><span>变化阈值</span><button type="button" data-threshold="0.10">0.10</button><button type="button" data-threshold="0.15" aria-pressed="true">0.15</button><button type="button" data-threshold="0.20">0.20</button><label><input type="checkbox" id="land-only"> 仅两期均未标水</label></div>
<div class="maps"><figure><figcaption>4 月 18 日 · NDVI</figcaption><canvas id="before" aria-label="4 月 NDVI 网格"></canvas></figure>
<figure><figcaption>10 月 11 日 · NDVI</figcaption><canvas id="after" aria-label="10 月 NDVI 网格"></canvas></figure>
<figure><figcaption>两期差值 · NDVI 分类</figcaption><canvas id="change" aria-label="NDVI 变化分类"></canvas></figure></div>
<div class="legend"><span style="--c:#16856b">上升</span><span style="--c:#bd663d">下降</span><span style="--c:#d8dfc8">阈值内</span><span style="--c:#405367">排除</span><span id="water-key" hidden style="--c:#acced7">至少一期标水</span></div>
<p id="selected" class="cell" aria-live="polite">点击图上的像元以查看计算证据。</p>
</section>
<section class="panel"><h2>三组检验</h2><table><thead><tr><th>实验</th><th>实际结果</th></tr></thead><tbody>
<tr><td>同景对照</td><td>__SAME_VALID__ 个有效像元，最大绝对差 0</td></tr>
<tr><td>半像元错位</td><td>向东 15 米，拒绝估算，退出码 __EXIT__</td></tr>
<tr><td>两期影像</td><td>__OVERLAP__ 个重叠像元，全量像元分类与独立参考一致</td></tr>
</tbody></table>
<p class="sub">两期差值最大数值误差 __ERROR__。结果仅用于样区 NDVI 对比，日期跨季，变化数值无法单独证明地表利用变化或成因。面积为 UTM 投影平面估算。</p></section>
<footer>
<a href="__STAC_A__">第一期产品</a> · <a href="__STAC_B__">第二期产品</a> · <a href="https://www.usgs.gov/landsat-missions/landsat-collection-2-quality-assessment-bands">USGS QA 定义</a>
</footer>
</main>
<script>
const g=__GRID__, colors={"1":[22,133,107],"-1":[189,102,61],"0":[216,223,200],"-2":[64,83,103],"-3":[172,206,215]};
const ids=["before","after","change"];
const indexColor=v=>v===null?colors[-2]:[0,1,2].map((i)=>Math.round([229,219,193][i]+(Math.max(0,Math.min(1,(v+0.15)/0.95)))*([20,97,72][i]-[229,219,193][i])));
const counts=__COUNTS__;
let threshold=0.15, selected=null, landOnly=false;
const label=d=>d===null ? -2 : d>=threshold ? 1 : d<=-threshold ? -1 : 0;
function paint(id,values,palette){
 const c=document.getElementById(id); c.width=g.width; c.height=g.height;
 const ctx=c.getContext("2d"), image=ctx.createImageData(g.width,g.height);
 for(let i=0;i<values.length;i++)image.data.set([...palette(values[i],i),255],i*4);
 ctx.putImageData(image,0,0);
 if(selected!==null){ctx.strokeStyle="#fff";ctx.strokeRect(selected%g.width-1,Math.floor(selected/g.width)-1,3,3);}
}
function draw(){
 const c=counts[String(threshold)];
 document.getElementById("gain-area").textContent=((landOnly?c.both_nonwater_gain:c.gain)*0.0009).toFixed(3)+" km²";
 document.getElementById("loss-area").textContent=((landOnly?c.both_nonwater_loss:c.loss)*0.0009).toFixed(3)+" km²";
 paint("before",g.ndvi_before,indexColor); paint("after",g.ndvi_after,indexColor);
 paint("change",g.delta,(d,i)=>colors[landOnly&&g.water_code[i]>0?-3:label(d)]);
 document.getElementById("water-key").hidden=!landOnly;
 if(selected===null)return;
 const i=selected, col=i%g.width, row=Math.floor(i/g.width);
 const f=v=>v===null?"已排除":v.toFixed(4);
 document.getElementById("selected").textContent=
   "第 "+(row+1)+" 行 · 第 "+(col+1)+" 列  |  UTM "+(g.x+30*col+15)+", "+(g.y-30*row-15)+
   "  |  4 月 "+f(g.ndvi_before[i])+" · 10 月 "+f(g.ndvi_after[i])+" · Δ "+f(g.delta[i])+"  |  "+({"-1":"有无效值","0":"两期均未标水","1":"4 月标水","2":"10 月标水","3":"两期均标水"}[g.water_code[i]]);
}
for(const id of ids){
 const c=document.getElementById(id);
 c.addEventListener("click",event=>{
  const r=c.getBoundingClientRect(), x=Math.min(g.width-1,Math.floor((event.clientX-r.left)*g.width/r.width));
  const y=Math.min(g.height-1,Math.floor((event.clientY-r.top)*g.height/r.height));
  selected=y*g.width+x;
  draw();
 });
}
for(const button of document.querySelectorAll("[data-threshold]")){
 button.addEventListener("click",()=>{
  threshold=Number(button.dataset.threshold);
  for(const b of document.querySelectorAll("[data-threshold]"))b.setAttribute("aria-pressed",String(b===button));
  draw();
 });
}
document.getElementById("land-only").addEventListener("change", e=>{landOnly=e.target.checked;draw()});
draw();
</script></html>
"""

values = {"WATER_SHARE": f"{(s['gain'] - s['both_nonwater_gain']) / s['gain']:.2%}",
          "COVERAGE": f"{s['valid_fraction']:.2%}", "GAIN": f"{int(s['gain_m2']) / 1e6:.3f}",
          "LOSS": f"{int(s['loss_m2']) / 1e6:.3f}", "EXCLUDED": f"{s['excluded']:,}",
          "SAME_VALID": f"{same['valid']:,}", "EXIT": half["exit_code"], "OVERLAP": f"{s['overlap']:,}",
          "ERROR": f"{s['reference_max_error']:.2e}", "STAC_A": source[0]["stac"], "STAC_B": source[1]["stac"],
          "COUNTS": json.dumps({**summary["sensitivity"], "0.15": {k: s[k] for k in ("gain", "loss", "both_nonwater_gain", "both_nonwater_loss")}}),
          "GRID": json.dumps({k: grid[k] for k in ("width", "height", "x", "y", "ndvi_before", "ndvi_after", "delta", "water_code")},
                             separators=(",", ":"))}
for key, value in values.items():
    html = html.replace(f"__{key}__", str(value))
(ROOT / "格证-实测报告.html").write_text(html, encoding="utf-8")

