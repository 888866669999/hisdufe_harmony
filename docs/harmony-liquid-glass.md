# 鸿蒙端「液态玻璃」调研结论与方案

> 调研依据：直接读本机 SDK 的 `.d.ts` 声明（最权威），
> 并核对了真机设备的 API 等级。不是从文档/博客推测的。
>
> **2026-09-18 更新**：本文件原先的结论是「真·液态玻璃在本机不可用」。
> 该结论**已被推翻** —— 引入第三方库 `com.hm.appleui.hw` 后，
> 本机（API 24）已能做出真正的液态玻璃（边缘折射 + 色散 + 中心看穿）。
> 见文末第 6 节。下表保留，用于说明「系统原生能力」的边界。

---

## 1. 系统原生能力的三个档位

| 档位 | 能力 | 需要的 API | 本机可用 | 观感 |
|---|---|---|---|---|
| **A. 原生 Immersive Material** | 系统级玻璃材质（含光照、交互反馈、5 档厚度） | **API 26** | ❌ **设备仅 API 24** | 与 iOS 26 最接近 |
| **B. 模糊材质** | 背景模糊 + 饱和度 + 亮度 + 灰度噪声 | API 11–14 | ✅ 可用 | 磨砂玻璃，外观接近 A 的静态部分 |
| **C. 前后景模糊样式** | 系统预设 13 档 `BlurStyle` | API 9–12 | ✅ 可用 | 与系统风格一致，参数最少 |

**关键事实**：鸿蒙在 **API 26 才引入系统级的液态玻璃 API**
（`@ohos.arkui.uiMaterial`，2025–2026 年的新能力），
而本机设备（SLG-W60，HarmonyOS 6.1.0）**API 等级是 24** ——
所以 A 档在这台机器上**编译能过、运行无效**（`@since 26.0.0`）。

---

## 2. A 档：API 26 的原生 Immersive Material（未来可升级）

SDK 里的 `@ohos.arkui.uiMaterial.d.ts` 提供了完整的玻璃材质体系：

```ts
// 5 档厚度：ULTRA_THIN / THIN / REGULAR / THICK / ULTRA_THICK
class ImmersiveMaterial extends Material {
  constructor(options?: ImmersiveOptions);
}
interface ImmersiveOptions {
  style?: ImmersiveStyle;          // 厚度档位
  materialColor?: ResourceColor;   // 材质叠加色
  colorInvert?: boolean;           // 子树上颜色随背景自动反转（THIN/ULTRA_THIN 生效）
  applyShadow?: boolean;           // 是否带材质阴影（默认 true）
  interactive?: boolean;           // 是否响应交互
  lightEffect?: LightEffectOptions | null;  // 手势光效反馈（这就是「动态」的来源）
}
```

应用方式：`CommonMethod.systemMaterial(material)` ——
**挂在 `CommonMethod` 上，意味着任意组件都能用**（不只是弹窗）：

```ts
Column() { /* ... */ }
  .systemMaterial(new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.REGULAR,
    interactive: true,
    lightEffect: { color: Color.White },
  }))
```

还支持查询/批量开关（`getMaterialInfo()`、`MaterialState.ENABLE/DISABLE`），
以及给 `bindSheet` / `bindPopup` / `bindMenu` 指定 `systemMaterial`。

**升级条件**：`compatibleSdkVersion` 提到 26 且目标设备的 API ≥ 26。
当前项目 `targetSdkVersion` 已是 `26.0.0`，但 `compatibleSdkVersion` 是
`6.0.0(20)`、设备是 24 —— 需要设备升级才能真正跑起来。

---

## 3. B 档：现在就能做的方案（推荐）

SDK 提供 `backgroundEffect(BackgroundEffectOptions)`（@since 12），
参数足以做出玻璃质感：

```ts
.backgroundEffect({
  radius: 18,            // 模糊半径：玻璃的「磨砂」程度
  saturation: 1.5,       // 饱和度：透出的颜色不发灰
  brightness: 1.05,      // 亮度微提
  color: '#3DFFFFFF',    // 玻璃自身底色（极淡）
  adaptiveColor: AdaptiveColor.AVERAGE,  // 按背景自适应取色
  blurOptions: { grayscale: [20, 60] },  // 灰度区间：**做磨砂质感的关键**
  policy: BlurStyleActivePolicy.ALWAYS_ACTIVE,
})
```

另有更省事的 `backgroundBlurStyle(BlurStyle.X, options)`，
其中 `BlurStyle` 有 13 档：

- `Thin / Regular / Thick`（9+，应用内材质）
- `BACKGROUND_THIN / REGULAR / THICK / ULTRA_THICK`（3+，背景材质）
- **`COMPONENT_ULTRA_THIN / THIN / REGULAR / THICK / ULTRA_THICK`（8–12，组件材质）** ← 最接近 A 档的分档语义

### 建议用法（与 Flutter 端保持一致的信息层次）

| 位置 | 建议 | 理由 |
|---|---|---|
| 侧边 dock / 顶部栏 / 底部栏 | `COMPONENT_REGULAR` + 低透明度底色 | 与 Flutter 端同为「浮层」 |
| 弹窗（课程编辑 / 重新验证 / 校历） | `COMPONENT_THICK` + `backgroundEffect` 提饱和 | 弹窗上内容多，需要更强的实体感 |
| 设置页分组卡片 | `COMPONENT_THIN` | 卡片是次级层次，淡一些 |
| **课表网格内的课程卡** | **不做玻璃** | 与 Flutter 端同一决策：实心彩卡是内容载体，加玻璃既冲突又费 GPU |

### 需要注意的两点

1. **`backgroundEffect` 是「背景模糊」，不是「前景折射」。**
   它把组件**背后**的内容模糊后透出，但没有 A 档那种光线折射/边缘高光。
   想要高光可叠加 `border({ width: 1, color: '#33FFFFFF' })` 模拟玻璃边缘。
2. **性能**：华为官方对 `backgroundEffect` 也有性能提示 ——
   大面积、多层叠加会明显增加 GPU 负载。
   鸿蒙端应**比 Flutter 端更保守**（鸿蒙设备的 GPU 调度更紧），
   建议只用在导航栏与弹窗这两类小面积浮层上。

---

## 4. 落地步骤（若要做）

1. 在 `theme/Theme.ets` 旁新增 `theme/GlassKit.ets`，集中定义
   「一处参数、多处复用」的玻璃样式（与 Flutter 端 `glass_kit.dart` 对应）。
2. 从侧边 dock 与顶部栏开始（改动最小、最容易看出效果）。
3. **必须在真机上验证**：
   - 该设备 API 24 只支持 B 档，确认 `backgroundEffect` 生效；
   - 观察滚动/切页时是否掉帧；
   - 深色模式下降低模糊、提高底色不透明度（深色下模糊过强会发灰发浑）。
4. 加入 `canIUse('SystemCapability.ArkUI.ArkUI.Full')` 之类的兜底：
   低端或老设备上退化为纯色面板，**绝不因为玻璃而让界面显示不出来**。

---

## 5. 与 Flutter 端的能力对比（为何两端观感会有差异）

| 维度 | Flutter (`liquid_glass_widgets`) | 鸿蒙 B 档 (`backgroundEffect`) |
|---|---|---|
| 技术手段 | 自研 **fragment shader** | 系统合成器（Skia/RenderService） |
| 折射 / 色散 | ✅ 有（`refractiveIndex` / `chromaticAberration`） | ❌ 无 |
| 边缘高光 | ✅ 有（`fresnelStrength` / `lightAngle`） | ⚠️ 只能用 1px 边框模拟 |
| 手势光效 | ✅ 有（`isInteractive` / `glowIntensity`） | ❌ 无（A 档才有 `lightEffect`） |
| 模糊+饱和度 | ✅ 有 | ✅ 有 |
| 设备门槛 | Impeller（本机满足） | API 11+（本机满足） |

**结论**：Flutter 端能做到「真·液态玻璃」（有折射与高光），
鸿蒙端靠系统原生能力在当前设备上只能做到「磨砂玻璃」（模糊+饱和度）。
**要拿到折射与色散，必须走第 5 节的第三方库路线，而不是等 API 26。**

---

## 6. 真正的液态玻璃：`com.hm.appleui.hw`（已落地）

上述「等 API 26」的结论只适用于**系统原生**能力。引入第三方库后本机已能做出
真正的液态玻璃，且**已在真机（API 24）验证通过**。

### 选型

| 项 | 值 |
|---|---|
| 包名 | `com.hm.appleui.hw` |
| 版本 | `^2.1.0` |
| `compatibleSdkVersion` | **20**（本机 API 24 可用，无需升级系统） |
| 原理 | `XComponent(TEXTURE)` + 原生 EGL / OpenGL ES 3.0，独立渲染线程 |
| 依赖 | `libliquidglass.so`（仅 `arm64-v8a`） |

安装：`ohpm install com.hm.appleui.hw`（依赖写入根 `oh-package.json5`）。

它实时截取**紧邻下层**的背景做透镜：中心区域保持纯透明可看穿，只在边缘做
径向折射、RGB 色散与切向正弦扭曲 —— 这正是与「磨砂玻璃」的本质区别。

### 两个必须知道的约束（都踩过）

**① 透镜四周必须留出 ≥ 30vp 的空隙。**

该库把画布向透镜四周各外扩 30vp（源码 `padVp`）以容纳边缘采样点，并按**画布**
而非透镜去截取背景。玻璃离父层边缘不足 30vp 时，外扩区越出父层边界，
截帧被判越界：

```
W AceComponentSnapshot: Snapshot reigon out of range.
E AppleUI: snapshot fail 401
```

**玻璃会完全不渲染**，只剩全透明 —— 不崩溃、不抛异常，界面看起来只是
「没有玻璃效果」，极难察觉。因此 `Index.ets` 里 dock 的左右边距与底部留白
都由 `DOCK_PAD = 30` 推出（`DOCK_MARGIN = 34`、`DOCK_BOTTOM = 36`）。

**② 玻璃必须与它要折射的内容层同处一个 Stack、且作为后序兄弟。**

该库从自身出发沿父链「向前找最近一个与自身可见区域重叠的兄弟层」，
中间多夹一层容器同样会导致截帧区域越界。

### 怎么确认玻璃真的在渲染

**不要只看截图** —— 「全透明」与「未渲染」外观完全一样。可靠办法是清空日志缓冲
后重跑，再数错误条数：

```bash
hdc shell "hilog -r"
hdc shell "aa force-stop com.sdufe.jwclient"
hdc shell "aa start -b com.sdufe.jwclient -a EntryAbility"
hdc shell "hilog -x" | grep -c "AppleUI.*snapshot fail"   # 期望 0
```

### 落地范围

目前用在**手机端（窄屏）底部 dock**：`Index.ets` 的 `dockGlass()`（玻璃）与
`dockTabs()`（图标文字，叠于其上）。dock 是浮层，内容从玻璃下面滚过，
所以各页面滚动内容需按 `Theme.bottomInset()` 补一段底部空白
（值由 `Index` 按当前布局写入 `AppStorage`，平板无底部 dock 时为 0）。

---

## 7. 建议

- **手机端 dock 用 AppleUI**（已落地）：这是唯一能拿到折射/色散的方案。
- **其余大面积容器仍用 B 档磨砂**：`backgroundEffect` 成本低、无新依赖，
  且玻璃**不适合**满屏铺开（详见 Flutter 端同款结论：玻璃是承载层不是包裹层）。
- **不与 API 26 的 `uiMaterial` 混用**：等设备升级后再评估统一，避免两套玻璃语言。
- **不做**：课表网格与长列表不加玻璃（两端同一决策）。
