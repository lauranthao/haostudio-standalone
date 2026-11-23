# 启动动画 #4 规格（Splash Animation #4）

来源：旧 Swift 工程的启动动画实现（`layoutSplashOverlays`、
`runSplashAnimation`，旧代码已从 master 工作区删除，仅作规格参考；旧工程只读位置
`~/workspace/deploy/standalone-app/`）。参考视频：
`~/workspace/standalone-logo-options/media-generation-splash-anim-4-float-0-71a01f12-493a-429d-b474-6fc4500a1a37.mp4`。
总时长约 1.5 秒，背景白色，logo 为标准美术资产（`Logo.imageset/logo.png`，
md5 `887bad72295b82bdcac2b0686ee90d99`，白底、黑色 3D 音符 + 黑色播放三角 + 红色小球）。

## 初始状态（动画开始前）

- logo：`alpha = 0`，`transform = translate(0, 22pt) + scale 0.97`
- logo 下方柔和阴影：`alpha = 0`（动画中放大到正常尺寸）
- 红点覆盖层：直径 `d = 0.069 × logo 宽度`，圆心在 logo 方形区域的
  `(0.678W, 0.409H)`，颜色 `RGB(0.96, 0.20, 0.20)`，`alpha = 0`，初始缩放 0.6
- 红色光晕：尺寸 `g = 0.22 × logo 宽度`，同一圆心，径向渐变
  （红色 `maxAlpha 0.85` → 透明），`alpha = 0`，位于红点下层；
  光晕图由代码生成（中心到边缘的径向渐变，宽大于高时垂直压扁成椭圆），不需要额外素材
- 加载转圈 + 副标题：`alpha = 0`（仅在 1.5 秒时仍未就绪才显示）

## 时间线

| 时间 | 动作 |
|---|---|
| 0.0–1.0s | logo 从白底淡入（alpha 0→1），同时上浮 22pt 回原位、缩放到 1.0（ease-out） |
| 0.15–1.0s | logo 下方阴影长出来（alpha →1，缩放回正常，0.85s，ease-out） |
| 0.7–1.0s | 红点淡入并缩放到正常（0.3s，ease-out） |
| 0.9–1.5s | 红点呼吸一次：缩放 1 → 1.12，光晕 alpha → 0.55（0.6s，ease-in-out） |
| 1.5s | 动画结束：已就绪则整页淡出进 app；未就绪则显示转圈 + 副标题（0.25s 淡入）并等待 |

## 2.0 原生实现注意

- 用 SwiftUI 实现（配合 `Animation.easeOut` / `easeInOut`，时序与上表一致），
  不要把旧 UIKit 的 `UIView.animate` 代码直译过来。
- 红点位置必须按 logo 实际尺寸的比例算（0.678W / 0.409H，直径 0.069W），
  不要写死点数。
- 光晕用代码生成的径向渐变（SwiftUI `RadialGradient` 即可），不要加图片素材。
- 动画结束后的淡出进 app 与旧版一致：1.5 秒是动画本身，淡出另外算。
