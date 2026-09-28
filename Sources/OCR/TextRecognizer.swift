import CoreGraphics
import Foundation
import Vision

/// 一段识别出来的文字。
struct RecognizedText: Equatable {
    let text: String
    /// 文字外框，**画布坐标**（点，左下原点）
    let box: CGRect
}

/// 本地文字识别（Apple Vision）。
///
/// 用系统自带的 `VNRecognizeTextRequest`：**完全离线、免费、不需要账号**，而且返回
/// 「文字 + 外框坐标」两样东西 —— 坐标能直接变成画布上的矩形，所以它是后面
/// 「智能脱敏」（M6）可以直接复用的地基。
///
/// 换算与排序都抽成不依赖 Vision 的纯函数（`canvasRect` / `readingOrder`），
/// 因为这两处错了都不会报错、只会给出"看起来对但读起来莫名其妙"的结果。
enum TextRecognizer {

    // MARK: - 坐标

    /// Vision 归一化框（单位正方形）→ 画布矩形（点）。
    ///
    /// ⚠️ **两套坐标都是左下原点，所以这里没有 Y 翻转** ——
    /// 这和「选区裁剪」「打码取像素」都不一样（那两处的图像像素是左上原点）。
    /// 顺手多加一次翻转的话，识别框会整体跑到上下颠倒的位置，而文字还是对的，
    /// 极容易以为是"Vision 识别不准"。
    ///
    /// （Vision 的 `boundingBox` 文档明确是 "origin at the image's lower-left corner"；
    /// 我们给它的 `CGImage` 方向是 `.up`，画布又是左下原点，于是直接等比缩放即可。）
    static func canvasRect(fromNormalized box: CGRect, canvasSize: CGSize) -> CGRect {
        CGRect(x: box.minX * canvasSize.width,
               y: box.minY * canvasSize.height,
               width: box.width * canvasSize.width,
               height: box.height * canvasSize.height)
    }

    // MARK: - 阅读顺序

    /// 按阅读顺序排列：先上后下，同一行内先左后右。
    ///
    /// Vision 返回的顺序**没有保证**（实测同一张图多次调用结果稳定，但它并不等于
    /// 阅读顺序）。直接按数组顺序拼接，拼出来的句子会莫名其妙地前后跳。
    static func readingOrder(_ items: [RecognizedText]) -> [RecognizedText] {
        // 先按竖直中心从上到下排，再**用锚点贪心聚成行**：每行以该行第一个元素的
        // 竖直中心为锚点，判断后续元素是否属于本行。
        //
        // 不能把"半行高容差"直接写成 sorted(by:) 的比较器 —— 那个关系不可传递
        // （A~B 同行、B~C 同行，但 A 与 C 可能差了一整个行高），
        // 于是谓词不满足严格弱序，Swift 的排序结果取决于内部比较顺序，
        // 属于未定义行为（同一份输入可能给出不同结果）。
        // 用锚点聚类得到的行划分是确定的，再对每行按 x 排序，整体就是一个全序。
        let topDown = items.sorted { $0.box.midY > $1.box.midY }
        var lines: [[RecognizedText]] = []

        for item in topDown {
            if let anchor = lines.last?.first {
                let tolerance = max(min(anchor.box.height, item.box.height) * 0.5, 1)
                if abs(anchor.box.midY - item.box.midY) <= tolerance {
                    lines[lines.count - 1].append(item)
                    continue
                }
            }
            lines.append([item])
        }

        return lines.flatMap { $0.sorted { $0.box.minX < $1.box.minX } }
    }

    /// 拼成整段文本（按阅读顺序，每段一行）
    static func joinedText(_ items: [RecognizedText]) -> String {
        readingOrder(items).map(\.text).joined(separator: "\n")
    }

    // MARK: - 识别

    /// 识别画布底图里的文字。
    ///
    /// `VNImageRequestHandler.perform` 是**同步阻塞**的，一张整屏截图在 `.accurate`
    /// 档下通常要几百毫秒 —— 放在主线程会卡住整个界面，所以这里挪到后台队列，
    /// 结果回主线程。`completion` 一定在主线程调用。
    ///
    /// 返回 `Result` 而不是 `[RecognizedText]`：以前失败时把错误吞成空数组，
    /// 于是"识别引擎报错"和"这张图里确实没有文字"在界面上完全一样 ——
    /// 用户看到的是「未识别到文字」，会以为是自己图的问题，实际是引擎失败了。
    static func recognize(in image: CGImage,
                          canvasSize: CGSize,
                          completion: @escaping (Result<[RecognizedText], Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            // 只请求系统确实支持的语言。塞进一个不支持的标识会让**整个请求报错**，
            // 表现是"OCR 完全不能用"，而不是"少认一种语言" —— 这种失败方式很难查。
            if let supported = try? request.supportedRecognitionLanguages() {
                let usable = ["zh-Hans", "en-US"].filter { supported.contains($0) }
                if !usable.isEmpty { request.recognitionLanguages = usable }
            }

            var found: [RecognizedText] = []
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                for observation in request.results ?? [] {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    found.append(RecognizedText(
                        text: text,
                        box: canvasRect(fromNormalized: observation.boundingBox,
                                        canvasSize: canvasSize)))
                }
            } catch {
                // 失败要如实上报，不能吞成"没有文字"（两者在界面上必须能分开）
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            DispatchQueue.main.async { completion(.success(found)) }
        }
    }
}
