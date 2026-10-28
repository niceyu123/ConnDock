# ConnDock 应用图标

2026-10-28 按用户新附件替换为蓝底白色云朵终端图案。原图逐字节保存于 `AppIcon-original.png`。

- `AppIcon-macOS.png`：蓝色圆角底板、白色云朵终端图案，外沿透明。
- `AppIcon-iOS.png`：不透明满幅蓝底图案，由 iPhone/iPad 系统应用圆角。
- `BrandIcon.png`：去除蓝色底板的单色透明云朵终端符号，仅用于应用内。

平台适配和单色提取通过内置 imagegen 工具完成；可能有细微像素差异，不宣称逐像素复制。固定母版纳入项目资源；日常构建不调用图像服务。运行 `scripts/generate-app-icons.sh` 使用 macOS 自带 sips 重建 AppIcon 和共享 BrandAssets。应用内通过 `BrandIcon` 与 SwiftPM `Bundle.module` 读取单色模板，使用语义前景色随浅色/深色外观切换，装饰图像不重复进入无障碍朗读。

## macIconPrompt

Use case: background-extraction. Edit target: provided exact blue ConnDock icon. Make macOS application icon: remove ONLY the exterior white presentation canvas outside the blue rounded-square tile, replace with real transparency. Preserve blue rounded tile, exact vivid azure blue coloring, subtle cyan rim, soft translucent outer shadow, exact white cloud outline and terminal chevron and underscore, their shapes, thick strokes, positions, scale and composition. Do not redraw or redesign artwork. Keep framing and original tile width approximately 88% of square canvas. Cloud and terminal stay opaque white, blue stays opaque. No text, no added objects.

## iosIconPrompt

Use case: precise-object-edit. Edit target: provided exact blue ConnDock app icon. Adapt ONLY the exterior for a production iPhone/iPad app icon. Remove the white exterior presentation canvas, baked rounded tile silhouette and shadow; zoom blue tile to fill full square canvas, extend same vivid azure blue background cleanly to every square corner. Preserve EXACT white cloud outline and white terminal chevron and underscore, their shapes, thick strokes, positions relative to blue tile, composition, gentle existing blue texture. Do not redraw, redesign, add text, add objects or add rounded corners. Full opaque square blue background, system will apply the corner mask. Keep whole white drawing and balanced margins.

## brandIconPrompt

Use case: precise-object-edit. Edit target: attached blue cloud-terminal icon. Extract and convert ONLY the white cloud outline, chevron and underscore to SOLID BLACK strokes on TRANSPARENT background. It is a small monochrome UI glyph. Use PURE BLACK (#000000), NOT WHITE, for all three strokes. Remove entire blue square and all shadows/background. Exactly three disconnected clean stroke shapes: open cloud arch, > chevron, horizontal underscore. Smooth rounded ends. No texture, no noise, no residual speckles or fragments. Preserve exact original silhouette and relative geometry. Center drawing with 5% margins. Black glyph, transparent surroundings.
