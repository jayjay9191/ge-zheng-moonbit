
# 格证 · Landsat 遥感变化质检

在计算植被指数变化前，先检查两期栅格是否落在同一网格，再剔除云、阴影、雪、饱和和无数据像元。输出共同有效率、阈值上下的变化面积、逐像元差值以及排除原因。首版面向北向、30 米、同一 WGS84 UTM 分区的 Landsat 8/9 Collection 2 Level-2 裁片。

## 开始

1. 双击 **格证-实测报告.html** 查看两期 NDVI、变化分类、三组验证和像元查询。可切换 0.10、0.15、0.20 三档阈值，也可以只看两期 QA 均未标水的区域。报告可以离线打开。
2. 双击 **试跑.cmd** 重跑全部用例。需要 Node.js 22.3+ 与 Python 3.10+。样例已随包提供，复跑无须下载数据或安装第三方 Python 包。
3. 比较自备的同规格裁片，用编译产物执行：

```console
node gezheng.js data/scene-1.json data/scene-2.json 0.15
```

输入格式按样例 JSON，包含两个波段、QA_PIXEL、QA_RADSAT、影像日期及左上角投影坐标。四个波段数组按从上到下、行内从左到右展平。转换脚本验证原始 COG 的方向和分辨率，使用裁片原值。CLI 要求填入真实网格元数据，输入 JSON 自身不保留旋转参数。错误输入或无法比较时返回非零退出码并说明原因。

## 实测

安徽巢湖附近，Landsat 9 轨道/行号 121/038，分别于 2024-04-18、2024-10-11 获取。每期裁片 128×128，像元 30 米，共 16,384 个。来源链接、资产窗口坐标与 SHA-256 见 **data/sources.json**。

| 实验 | 可复现结果 |
| --- | --- |
| 同景对照，2024-04-18 与自己相比 | 14,226 个共同有效像元，最大绝对 NDVI 差为 0 |
| 半像元错位，保持真实第 1 期波段并把网格起点向东移动 15 米 | 拒绝计算面积，退出码 2。该人为构造用例验证坐标检查 |
| 两期变化，阈值 \|ΔNDVI\| ≥ 0.15 | 14,224 个共同有效像元（86.82%）；10,703 个上升、94 个下降、3,427 个在阈值内、2,160 个排除 |
| 独立核对 | 用精确分数计算复核全部 16,384 个像元的掩膜和分类。0.15 档最大差值误差 7.08×10⁻¹⁶，三档阈值的分类均一致 |

0.15 档估算 NDVI 上升面积 **9.6327 km²**、下降面积 **0.0846 km²**。这是跨季节的 NDVI 指标变化和投影平面面积。图只覆盖所取样区，无法凭这两期数据归因或认定土地利用变化。当前按 USGS 公开范围过滤反射率，QA 同像元多种问题时按填充、云、阴影、雪、饱和、反射率异常顺序计首项。面积仅统计两期均有效的像元。

另一个关键发现：在 10,703 个上升像元中，10,647 个（99.48%）至少一期被 QA_PIXEL 第 7 位标为水体。两期均未标水的 1,141 个有效像元中，56 个上升（0.0504 km²）、82 个下降（0.0738 km²）。水体标记来自卫星产品 QA，不能单独作为地面水域边界的认定。


## 肥东陆地对照

2024-09-09 与 2024-09-25 的 Landsat 9 影像同轨同网格，时间相隔 16 天。QA 质检后共同有效像元中，99.60% 两期均未标水。两种模式均检查网格并使用相同反射率处理、30 米像元和 0.15 阈值。直接算模式只跳过 QA_PIXEL/QA_RADSAT 筛选。

| 口径 | 有效像元 | 上升 | 下降 |
| --- | ---: | ---: | ---: |
| 直接算 | 16,377 | 2,058 | 973 |
| QA 质检后 | 11,257（68.71%） | 86 | 577 |

额外排除 5,120 个像元，其中 2,368 个在直接算中超过阈值。保留下来的像元在两种模式中的差值和分类逐个相同。独立整数分数复算覆盖两种模式的全部 16,384 个像元。被筛掉的区域留作未知，两期都保留的指数差异也不能独自证明地面成因。

打开 **格证-肥东对照报告.html** 并点“定位一处被筛除的像元”，查看第 10 行、第 14 列。该像元直接算为 +0.7849，第一期 QA 标云后排除。用 python scripts/replay_land.py 和 python scripts/render_land.py 离线复跑。原始产品链接、窗口及哈希见 **data/feidong/sources.json**。

## 实现与验证

MoonBit 执行网格校验、求交、QA 位运算、反射率换算、NDVI、分类和面积统计。Node.js 负责命令行输入输出。Python 下载裁片、用分数独立验算并渲染报告。可用 MoonBit 编译器重新构建：

```console
moon test
moon build --release --target js
```

编译产物位于 _build/js/release/build/cmd/main/main.js，用它替换 gezheng.js 后重跑。重新获取官方原始影像裁片时，在独立 Python 环境安装 requirements-fetch.txt，然后运行 python scripts/fetch_landsat.py。该步骤需要访问 Planetary Computer 及其公共 Landsat 资产，不影响已打包的离线复跑。

参考 [USGS Landsat QA 波段](https://www.usgs.gov/landsat-missions/landsat-collection-2-quality-assessment-bands)、[USGS 反射率换算](https://www.usgs.gov/faqs/how-do-i-use-a-scale-factor-landsat-level-2-science-products)、[Planetary Computer 的 Landsat 数据集](https://planetarycomputer.microsoft.com/dataset/landsat-c2-l2)。


### 共同有效覆盖门槛

CLI 可用 `--min-coverage 0.70` 设门槛。肥东样例的共同有效覆盖为 68.71%，设 0.70 时会停止输出面积。门槛由用户按任务设定，默认只要求有共同有效像元。

### 追溯一个像元

运行 `node gezheng.js data/feidong/scene-1.json data/feidong/scene-2.json 0.15 --inspect 10 14`。按共同网格的 1 起算行列输出投影坐标、两期 B4/B5、QA 位值、每期去留原因和差值。已排除的差值为 JSON null。

### 导入 GIS 软件

使用已安装 requirements-fetch.txt 的 Python，运行 `python scripts/export_geotiff.py results/feidong/screened.json results/feidong/gis`。两张 GeoTIFF 保留共同网格坐标，排除像元写 NoData。分类为 -1 下降、0 阈值内、1 上升，另一张保存实际 NDVI 差值。GeoTIFF 仅封装 MoonBit 输出。

### 分析本地 Landsat 裁片

使用 `python scripts/pack_local_tiffs.py --help` 查看如何把本地 SR_B4、SR_B5、QA_PIXEL、QA_RADSAT 变成输入 JSON。应来自同一 Landsat 8/9 Collection 2 Level-2 场景，使用原始 UInt16 值。脚本检查四个 TIFF 的 CRS、分辨率、原点、方向和尺寸，拒绝不一致的波段，保留原始像元。

### 轻量汇总

批处理只看变化面积、覆盖和剔除项时，CLI 加 `--summary`。MoonBit 不保留逐像元数组，汇总口径保持一致。导出地图或追溯像元时使用完整输出。
