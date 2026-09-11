import Cocoa

// 取色器的验证。三个容易错、且错了很难发现的地方：
//   1. 画布坐标 → 像素坐标的 Y 翻转（画布左下原点 vs 图像左上原点）
//   2. 缩放倍率的反推（Retina 上点与像素差 2 倍）
//   3. HEX 文本（前导零、大小写、越界夹取）
// 取色偏几十像素时，屏幕上相邻区域往往颜色相近，肉眼基本看不出来 —— 只能靠断言。
//
// 链接**真实的**全部源文件（除 main.swift）。

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { passed += 1; print("  ✅ \(name)\(detail.isEmpty ? "" : "  [\(detail)]")") }
    else { failed += 1; print("  ❌ \(name)\(detail.isEmpty ? "" : "  [\(detail)]")") }
}

_ = NSApplication.shared

func makeCGImage(width: Int, height: Int,
                 _ fill: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let buf = ctx.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b) = fill(x, y)
            let i = (y * width + x) * 4
            buf[i] = r; buf[i + 1] = g; buf[i + 2] = b; buf[i + 3] = 255
        }
    }
    return ctx.makeImage()!
}

func components(_ color: NSColor) -> (Int, Int, Int) {
    let c = color.usingColorSpace(.sRGB) ?? color
    return (Int((c.redComponent * 255).rounded()),
            Int((c.greenComponent * 255).rounded()),
            Int((c.blueComponent * 255).rounded()))
}

// MARK: - 1. HEX / RGB 文本

print("=== 1. HEX 与 RGB 文本 ===")
do {
    check("纯红 → #FF0000", ImagePixelSampler.hex(r: 255, g: 0, b: 0) == "#FF0000",
          ImagePixelSampler.hex(r: 255, g: 0, b: 0))
    check("纯黑 → #000000（前导零不能丢）",
          ImagePixelSampler.hex(r: 0, g: 0, b: 0) == "#000000",
          ImagePixelSampler.hex(r: 0, g: 0, b: 0))
    check("(1,2,3) → #010203（每段都补零）",
          ImagePixelSampler.hex(r: 1, g: 2, b: 3) == "#010203",
          ImagePixelSampler.hex(r: 1, g: 2, b: 3))
    check("十六进制用大写", ImagePixelSampler.hex(r: 171, g: 205, b: 239) == "#ABCDEF",
          ImagePixelSampler.hex(r: 171, g: 205, b: 239))
    check("越界值被夹住（不会出现 #1FF0000）",
          ImagePixelSampler.hex(r: 300, g: -20, b: 255) == "#FF00FF",
          ImagePixelSampler.hex(r: 300, g: -20, b: 255))
    check("rgbText 也用夹取后的值",
          ImagePixelSampler.rgbText(r: -5, g: 128, b: 999) == "R 0  G 128  B 255",
          ImagePixelSampler.rgbText(r: -5, g: 128, b: 999))
}

// MARK: - 2. 坐标换算

print("\n=== 2. 画布点 → 像素坐标（缩放 + Y 翻转）===")
do {
    let canvas = CGSize(width: 100, height: 60)
    let pixel = CGSize(width: 200, height: 120)      // 2× Retina

    // 画布左下角 → 图像左下角 → 像素坐标里 y 最大处
    // （边界必须能取到色：换算出的像素号等于高度，键实现会把它当越界丢掉）
    let bottomLeft = ImagePixelSampler.pixelCoordinate(
        canvasPoint: CGPoint(x: 0, y: 0), canvasSize: canvas, pixelSize: pixel)
    check("画布左下 (0,0) → 像素 (0,119)（边界能取到）",
          bottomLeft?.x == 0 && bottomLeft?.y == 119,
          "\(String(describing: bottomLeft))")

    // 画布右下角同理
    let bottomRight = ImagePixelSampler.pixelCoordinate(
        canvasPoint: CGPoint(x: 100, y: 0), canvasSize: canvas, pixelSize: pixel)
    check("画布右下 (100,0) → 像素 (199,119)",
          bottomRight?.x == 199 && bottomRight?.y == 119,
          "\(String(describing: bottomRight))")

    // 画布左上角 → 像素 (0,0)
    let topLeft = ImagePixelSampler.pixelCoordinate(
        canvasPoint: CGPoint(x: 0, y: 60), canvasSize: canvas, pixelSize: pixel)
    check("画布左上 (0,60) → 像素 (0,0)", topLeft?.x == 0 && topLeft?.y == 0,
          "\(String(describing: topLeft))")

    // 画布正中 (50,30) → 像素 (100,60)
    let middle = ImagePixelSampler.pixelCoordinate(
        canvasPoint: CGPoint(x: 50, y: 30), canvasSize: canvas, pixelSize: pixel)
    check("画布中心 (50,30) → 像素 (100,60)",
          middle?.x == 100 && middle?.y == 60, "\(String(describing: middle))")

    // 边界：画布内的点必须都能取到色；画布外的点返回 nil
    check("x 超出右边界 → nil",
          ImagePixelSampler.pixelCoordinate(canvasPoint: CGPoint(x: 100.5, y: 30),
                                            canvasSize: canvas, pixelSize: pixel) == nil)
    check("y 为负 → nil",
          ImagePixelSampler.pixelCoordinate(canvasPoint: CGPoint(x: 50, y: -0.5),
                                            canvasSize: canvas, pixelSize: pixel) == nil)
    check("退化尺寸（0 宽）→ nil",
          ImagePixelSampler.pixelCoordinate(canvasPoint: .zero, canvasSize: canvas,
                                            pixelSize: CGSize(width: 0, height: 120)) == nil)

    // 非整数倍率：150 像素 / 100 点 = 1.5
    let oneAndHalf = ImagePixelSampler.pixelCoordinate(
        canvasPoint: CGPoint(x: 10, y: 50), canvasSize: canvas,
        pixelSize: CGSize(width: 150, height: 90))
    check("1.5 倍：画布 (10,50) → 像素 (15,15)",
          oneAndHalf?.x == 15 && oneAndHalf?.y == 15, "\(String(describing: oneAndHalf))")

    // 1:1 时点与像素一一对应
    let unit = ImagePixelSampler.pixelCoordinate(
        canvasPoint: CGPoint(x: 7, y: 12), canvasSize: CGSize(width: 100, height: 60),
        pixelSize: CGSize(width: 100, height: 60))
    check("1:1 倍率下不偏移", unit?.x == 7 && unit?.y == 48,
          "\(String(describing: unit))")
}

// MARK: - 3. 采样

print("\n=== 3. 像素采样与放大镜切片 ===")
do {
    // 上半红、下半蓝（像素坐标 y=0 在上）
    let cg = makeCGImage(width: 40, height: 40) { _, y in
        y < 20 ? (255, 0, 0) : (0, 0, 255)
    }
    let sampler = ImagePixelSampler(image: cg)!
    check("尺寸读到 40×40", sampler.pixelWidth == 40 && sampler.pixelHeight == 40,
          "\(sampler.pixelWidth)×\(sampler.pixelHeight)")

    let top = sampler.rgb(atPixelX: 20, y: 5)
    let bottom = sampler.rgb(atPixelX: 20, y: 35)
    check("像素 y=5（上部）→ 红", top?.r == 255 && top?.b == 0, "\(String(describing: top))")
    check("像素 y=35（下部）→ 蓝", bottom?.b == 255 && bottom?.r == 0,
          "\(String(describing: bottom))")

    check("越界取色返回 nil", sampler.rgb(atPixelX: 40, y: 0) == nil
          && sampler.rgb(atPixelX: -1, y: 0) == nil
          && sampler.rgb(atPixelX: 0, y: -1) == nil)

    // 放大镜切片：11×11，中心那格就是被取的颜色
    let tile = sampler.smallImage(centeredAtPixelX: 20, y: 25, side: 11)!
    check("切片尺寸 = 11×11（中心落在正中一格）",
          tile.width == 11 && tile.height == 11, "\(tile.width)×\(tile.height)")

    // 从切片里读中心像素
    let tctx = CGContext(data: nil, width: 11, height: 11, bitsPerComponent: 8,
                         bytesPerRow: 11 * 4, space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    tctx.draw(tile, in: CGRect(x: 0, y: 0, width: 11, height: 11))
    let tb = tctx.data!.bindMemory(to: UInt8.self, capacity: 11 * 11 * 4)
    let centerIndex = ((11 / 2) * 11 + 11 / 2) * 4
    check("切片中心 = 被取的像素色（蓝）",
          Int(tb[centerIndex + 2]) == 255 && Int(tb[centerIndex]) == 0,
          "R=\(tb[centerIndex]) B=\(tb[centerIndex + 2])")

    // 图像边缘的切片不能崩，越界处填深灰而不是透明
    let edge = sampler.smallImage(centeredAtPixelX: 0, y: 0, side: 11)!
    check("在图像角点取切片不崩，尺寸仍是 11×11",
          edge.width == 11 && edge.height == 11)
}

// MARK: - 4. 端到端：在画布上单击取色

print("\n=== 4. 端到端：画布上单击 → 当前颜色被换掉 ===")
do {
    // 图像上半红、下半蓝；NSImage 声明成 100×60 点 → 2× Retina
    let cg = makeCGImage(width: 200, height: 120) { _, y in
        y < 60 ? (255, 0, 0) : (0, 0, 255)
    }
    let image = NSImage(cgImage: cg, size: NSSize(width: 100, height: 60))
    let view = AnnotationView(image: image)
    check("倍率反推出 2×", view.pixelScale == 2, "\(view.pixelScale)")

    view.currentTool = .picker
    check("切到取色器后不产生对象", view.objects.isEmpty)

    // 画布上部（y 大）应取到红
    let upper = NSEvent.mouseEvent(with: .leftMouseDown,
                                   location: CGPoint(x: 50, y: 50),
                                   modifierFlags: [], timestamp: 0, windowNumber: 0,
                                   context: nil, eventNumber: 0, clickCount: 1,
                                   pressure: 1)!
    view.mouseDown(with: upper)
    view.mouseUp(with: NSEvent.mouseEvent(with: .leftMouseUp,
                                          location: CGPoint(x: 50, y: 50),
                                          modifierFlags: [], timestamp: 0, windowNumber: 0,
                                          context: nil, eventNumber: 0, clickCount: 1,
                                          pressure: 1)!)
    let gotUpper = components(view.currentColor)
    check("画布上部取到红（Y 翻转正确的话才是红，反了会取到蓝）",
          gotUpper == (255, 0, 0), "\(gotUpper)")

    // 画布下部应取到蓝
    view.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown,
                                            location: CGPoint(x: 50, y: 10),
                                            modifierFlags: [], timestamp: 0, windowNumber: 0,
                                            context: nil, eventNumber: 0, clickCount: 1,
                                            pressure: 1)!)
    view.mouseUp(with: NSEvent.mouseEvent(with: .leftMouseUp,
                                          location: CGPoint(x: 50, y: 10),
                                          modifierFlags: [], timestamp: 0, windowNumber: 0,
                                          context: nil, eventNumber: 0, clickCount: 1,
                                          pressure: 1)!)
    let gotLower = components(view.currentColor)
    check("画布下部取到蓝", gotLower == (0, 0, 255), "\(gotLower)")

    check("取色全程没有产生对象", view.objects.isEmpty, "\(view.objects.count)")
    check("取色不进入撤销栈", view.undoStack.isEmpty, "\(view.undoStack.count)")
}

print("\n========================================")
print("通过 \(passed) 项，失败 \(failed) 项")
exit(failed == 0 ? 0 : 1)
