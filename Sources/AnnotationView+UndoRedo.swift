import Cocoa

// MARK: - Undo / Redo

/// 撤销 / 重做。
///
/// 拆到独立文件的原因：它是**唯一**同时改动对象表、z 序与附着关系的逻辑，
/// 而且两个方向（undo / redo）互为镜像 —— 放在一起review 更容易看出对应关系，
/// 也避免以后改一边忘另一边。
///
/// 实现上有一条容易踩的坑，见 `performRedo` 里 `.delete` 分支的说明。
extension AnnotationView {

    func performUndo() {
        guard let action = undoStack.popLast() else { return }
        selectedKey = nil

        switch action {
        case .add(let colorKey):
            // 撤销添加 = 删除该对象
            // 保存当前 zOrder（含该对象）供 redo 恢复用
            if let obj = objects[colorKey] {
                redoStack.append(.delete(objects: [(colorKey, obj)], zOrderSnapshot: zOrder))
            }
            objects.removeValue(forKey: colorKey)
            zOrder.removeAll { $0 == colorKey }

        case .delete(let deletedObjects, let zOrderSnapshot):
            // 撤销删除 = 恢复所有被删除的对象和 z-order
            // 保存当前 zOrder（不含已删除对象）供 redo 重新删除用
            let zOrderWithout = zOrder
            for (key, obj) in deletedObjects {
                objects[key] = obj
            }
            zOrder = zOrderSnapshot
            redoStack.append(.delete(objects: deletedObjects, zOrderSnapshot: zOrderWithout))

        case .move(let colorKey, let delta):
            if let obj = objects[colorKey] {
                let reverseDelta = CGVector(dx: -delta.dx, dy: -delta.dy)
                obj.move(by: reverseDelta)
                updateAttachedArrows(forParent: colorKey)
                redoStack.append(.move(colorKey: colorKey, delta: delta))
            }

        case .rotate(let colorKey, let angle):
            if let obj = objects[colorKey] {
                obj.rotate(by: -angle)
                updateAttachedArrows(forParent: colorKey)
                redoStack.append(.rotate(colorKey: colorKey, angle: angle))
            }

        case .scale(let colorKey, let factor):
            if let obj = objects[colorKey] {
                obj.scale(by: 1.0 / factor)
                updateAttachedArrows(forParent: colorKey)
                redoStack.append(.scale(colorKey: colorKey, factor: factor))
            }

        case .editText(let colorKey, let previous):
            if let shape = objects[colorKey] as? TextShape {
                let current = shape.text
                shape.text = previous
                redoStack.append(.editText(colorKey: colorKey, previous: current))
            }
        }

        hitTestBuffer.redrawAll(objects: objects, zOrder: zOrder)
        refreshDebugView()
        needsDisplay = true
    }

    func performRedo() {
        guard let action = redoStack.popLast() else { return }
        selectedKey = nil

        switch action {
        case .add:
            // .add 不再出现在 redo 栈中，保留以保证 switch 完整
            break

        case .delete(let savedObjects, let savedZOrder):
            // ⚠️ 这里靠「对象当前是否存在」反推操作方向，是历史遗留的脆弱写法：
            // `.delete` 这个 case 被两个方向共用（重做删除 / 重做添加），
            // 光看 case 分不出来。目前能工作是因为「删除」与「添加」恰好互斥。
            // 更稳的做法是给 UndoAction 加一个显式的方向字段 —— 但那会改动
            // 所有 `.delete` 的构造点，属于独立的一项技术债（见路线图的技术债清单）。
            let firstKey = savedObjects[0].0
            if objects[firstKey] != nil {
                // 对象存在 → 重做删除（从 undo .delete 推入）
                undoStack.append(.delete(objects: savedObjects, zOrderSnapshot: zOrder))
                for (key, _) in savedObjects {
                    objects.removeValue(forKey: key)
                }
                zOrder = savedZOrder
            } else {
                // 对象不存在 → 重做添加（从 undo .add 推入）
                for (key, obj) in savedObjects {
                    objects[key] = obj
                }
                zOrder = savedZOrder
                undoStack.append(.add(colorKey: firstKey))
            }

        case .move(let colorKey, let delta):
            if let obj = objects[colorKey] {
                obj.move(by: delta)
                updateAttachedArrows(forParent: colorKey)
                undoStack.append(.move(colorKey: colorKey, delta: delta))
            }

        case .rotate(let colorKey, let angle):
            if let obj = objects[colorKey] {
                obj.rotate(by: angle)
                updateAttachedArrows(forParent: colorKey)
                undoStack.append(.rotate(colorKey: colorKey, angle: angle))
            }

        case .scale(let colorKey, let factor):
            if let obj = objects[colorKey] {
                obj.scale(by: factor)
                updateAttachedArrows(forParent: colorKey)
                undoStack.append(.scale(colorKey: colorKey, factor: factor))
            }

        case .editText(let colorKey, let previous):
            if let shape = objects[colorKey] as? TextShape {
                let current = shape.text
                shape.text = previous
                undoStack.append(.editText(colorKey: colorKey, previous: current))
            }
        }

        hitTestBuffer.redrawAll(objects: objects, zOrder: zOrder)
        refreshDebugView()
        needsDisplay = true
    }
}
