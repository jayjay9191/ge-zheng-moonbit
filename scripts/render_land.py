"""Generate the standalone interactive land comparison."""
import json
from pathlib import Path

from replay import ROOT

folder = ROOT / "results/feidong"
summary = json.loads((folder / "summary.json").read_bytes())
direct, screened = (json.loads((folder / f"{key}.json").read_bytes()) for key in ("direct", "screened"))
sources = json.loads((ROOT / "data/feidong/sources.json").read_bytes())
keys = ("width", "height", "classes", "delta", "before_reason", "after_reason")
payload = {"direct": {key: direct[key] for key in keys},
           "screened": {key: screened[key] for key in keys}, "example": summary["example"]}
html = """<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>格证 · 肥东陆地样区</title><link rel="icon" href="data:,">
<style>
:root{font-family:"Microsoft YaHei UI",sans-serif;color:#193434;background:#edf3ee}*{box-sizing:border-box}
body{margin:0}main{max-width:1100px;margin:auto;padding:28px 18px 38px}
header{background:#103938;color:#f2f7ee;padding:34px;border-radius:20px}h1{font-size:clamp(26px,5vw,48px);margin:8px 0}h2{font-size:20px;margin:12px 0}
p{line-height:1.65;margin:7px 0}.eyebrow{font-weight:700;color:#9bd3b7;letter-spacing:.13em}
.results,.maps{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin:16px 0}
.card,.panel{border:1px solid #d6e4db;background:#fff;border-radius:16px;padding:17px;min-width:0}
.results strong{font-size:clamp(22px,3vw,36px);display:block;margin:6px 0}
figure{margin:0}figcaption{margin:0 0 8px;font-weight:700}
canvas{display:block;width:100%;height:auto;image-rendering:pixelated;border-radius:8px;cursor:crosshair}canvas:focus-visible{outline:3px solid #0e6452;outline-offset:3px}
button{background:#164f45;color:white;border:0;border-radius:7px;padding:8px 11px;font:inherit;cursor:pointer}
a{color:#0e6452}.legend{display:flex;flex-wrap:wrap;gap:8px 18px;font-size:13px;margin:10px 0}
.legend span:before{content:"";display:inline-block;width:10px;height:10px;background:var(--c);margin-right:5px}
#cell{background:#e7f1e9;padding:10px;border-radius:8px;min-height:42px}.note{color:#4a625c;font-size:14px}
@media(max-width:560px){header{padding:20px}.card,.panel{padding:11px}.results,.maps{gap:8px}figcaption{font-size:14px}}
</style>
<main><header><div class="eyebrow">格证 · Landsat 遥感变化质检</div>
<h1>云和阴影让“变化”多算了多少？</h1><p>安徽肥东 · Landsat 9 · 2024-09-09 → 2024-09-25 · 间隔 16 天</p></header>
<div class="results">
<section class="card"><h2>直接计算</h2><strong>__DGAIN__ 个上升像元</strong><p>下降 __DLOSS__ 个 · 有效 __DVALID__ 个</p></section>
<section class="card"><h2>QA 质检后</h2><strong>__SGAIN__ 个上升像元</strong><p>下降 __SLOSS__ 个 · 有效 __SVALID__ 个</p></section>
</div>
<section class="panel"><h2>同一网格、同一阈值，只切换 QA</h2>
<p>两次计算均使用 30 米像元、|ΔNDVI| ≥ 0.15。质检另外排除 __REMOVED__ 个像元，其中 __ABOVE__ 个本来会被归入上升或下降。</p>
<div class="maps"><figure><figcaption>直接算 · 不使用 QA 标记</figcaption><canvas id="direct" tabindex="0" aria-label="直接计算分类网格，方向键移动像元"></canvas></figure>
<figure><figcaption>质检后 · 排除云、阴影等</figcaption><canvas id="screened" tabindex="0" aria-label="质检后分类网格，方向键移动像元"></canvas></figure></div>
<div class="legend"><span style="--c:#12836b">上升</span><span style="--c:#c16a3f">下降</span><span style="--c:#dce5d0">阈值内</span><span style="--c:#506177">排除</span></div>
<button id="example" type="button">定位一处被筛除的像元</button><p id="cell" aria-live="polite">点击地图，或聚焦后用方向键查看像元。</p>
<p class="note">质检后的共同有效覆盖 __COVER__，其中两期均未标水的像元占 __LAND__。未标水是 QA 口径。被排除区域不下变化结论，保留的变化仍需结合地面样本解释。</p></section>
<p class="note"><a href="__A__">09-09 影像</a> · <a href="__B__">09-25 影像</a> · <a href="https://www.usgs.gov/landsat-missions/landsat-collection-2-quality-assessment-bands">USGS QA 定义</a></p></main>
<script>
const data=__PAYLOAD__, grid=data.direct;
const palette={1:[18,131,107],0:[220,229,208],"-1":[193,106,63],"-2":[80,97,119]};
let i=null;
const reason = ["有效","填充","云","云阴影","雪","饱和","反射率超出有效范围"];
function paint(){
 for(const key of ["direct","screened"]){
  const canvas=document.getElementById(key), p=data[key];
  canvas.width=p.width;canvas.height=p.height;
  const ctx=canvas.getContext("2d"), image=ctx.createImageData(p.width,p.height);
  p.classes.forEach((v,j)=>image.data.set([...palette[v],255],j*4));
  ctx.putImageData(image,0,0);
  if(i!==null){ctx.strokeStyle="#111";ctx.strokeRect(i%p.width-2,Math.floor(i/p.width)-2,5,5);ctx.strokeStyle="#fff";ctx.strokeRect(i%p.width-1,Math.floor(i/p.width)-1,3,3);}
 }
}
function select(index){
 i=Math.max(0,Math.min(grid.width*grid.height-1,index)); paint();
 const f=v=>v===null?"排除":v.toFixed(4);
 const after=data.screened;
 document.getElementById("cell").textContent="第 "+(1+Math.floor(i/grid.width))+" 行，第 "+(1+i%grid.width)+" 列 · 直接算 "+f(grid.delta[i])+" · 质检后 "+f(after.delta[i])+" · 第一期 "+reason[after.before_reason[i]]+"，第二期 "+reason[after.after_reason[i]];
}
for(const id of ["direct","screened"]){
 const c=document.getElementById(id);
 c.onclick=e=>{const r=c.getBoundingClientRect(), x=Math.floor((e.clientX-r.left)*grid.width/r.width), y=Math.floor((e.clientY-r.top)*grid.height/r.height);select(y*grid.width+x);};
 c.addEventListener("keydown",e=>{
  const step={ArrowLeft:[-1,0],ArrowRight:[1,0],ArrowUp:[0,-1],ArrowDown:[0,1]}[e.key];
  if(!step)return;
  e.preventDefault();
  const current=i??0;
  const x=Math.max(0,Math.min(grid.width-1,current%grid.width+step[0]));
  const y=Math.max(0,Math.min(grid.height-1,Math.floor(current/grid.width)+step[1]));
  select(y*grid.width+x);
 });

}
document.getElementById("example").onclick=()=>select((data.example.row-1)*grid.width+data.example.column-1);
paint();
</script></html>"""
values = {
    "DGAIN": f"{direct['gain']:,}", "DLOSS": f"{direct['loss']:,}", "DVALID": f"{direct['valid']:,}",
    "SGAIN": f"{screened['gain']:,}", "SLOSS": f"{screened['loss']:,}", "SVALID": f"{screened['valid']:,}",
    "REMOVED": f"{summary['qa_removed']:,}", "ABOVE": f"{summary['qa_removed_above_threshold']:,}",
    "COVER": f"{screened['valid_fraction']:.2%}",
    "LAND": f"{screened['both_nonwater_valid'] / screened['valid']:.2%}",
    "A": sources[0]["stac"], "B": sources[1]["stac"],
    "PAYLOAD": json.dumps(payload, separators=(",", ":")),
}
for key, value in values.items():
    html = html.replace(f"__{key}__", value)
(ROOT / "格证-肥东对照报告.html").write_text(html, encoding="utf-8")
