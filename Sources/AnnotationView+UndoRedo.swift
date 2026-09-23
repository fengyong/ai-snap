import Cocoa

// MARK: - Undo / Redo

/// 撤销 / 重做。
///
/// 拆到独立文件的原因：它是**唯一**同时改动对象表、z 序与附着关系的逻辑，
/// 而且两个方向（undo / redo）互为镜像 —— 放在一起 review 更容易看出对应关系，
/// 也避免以后改一边忘另一边。
///
/// `.add` / `.delete` 都带 `zOrderBefore` 与 `zOrderAfter`：
/// undo 总是回到 before，redo 总是去到 after。**不再**靠「对象是否还在表里」
/// 反推操作方向 —— 那种写法在加新对象类型或嵌套撤销时会静默出错。
extension AnnotationView {

    func performUndo() {
        guard let action = undoStack.popLast() else { return }
        selectedKey = nil

        switch action {
        case .add(let added, let zOrderBefore, let zOrderAfter):
            for (key, _) in added {
                objects.removeValue(forKey: key)
            }
            zOrder = zOrderBefore
            redoStack.append(.add(objects: added,
                                  zOrderBefore: zOrderBefore,
                                  zOrderAfter: zOrderAfter))

        case .delete(let deleted, let zOrderBefore, let zOrderAfter):
            for (key, obj) in deleted {
                objects[key] = obj
            }
            zOrder = zOrderBefore
            redoStack.append(.delete(objects: deleted,
                                     zOrderBefore: zOrderBefore,
                                     zOrderAfter: zOrderAfter))

        case .move(let colorKey, let delta, let detached):
            if let obj = objects[colorKey] {
                let reverseDelta = CGVector(dx: -delta.dx, dy: -delta.dy)
                obj.move(by: reverseDelta)
                // 撤销移动时把当初被解除的附着关系一并还原
                restoreDetachedAttachments(detached)
                updateAttachedArrows(forParent: colorKey)
                redoStack.append(.move(colorKey: colorKey, delta: delta, detached: detached))
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
        case .add(let added, let zOrderBefore, let zOrderAfter):
            for (key, obj) in added {
                objects[key] = obj
            }
            zOrder = zOrderAfter
            undoStack.append(.add(objects: added,
                                  zOrderBefore: zOrderBefore,
                                  zOrderAfter: zOrderAfter))

        case .delete(let deleted, let zOrderBefore, let zOrderAfter):
            for (key, _) in deleted {
                objects.removeValue(forKey: key)
            }
            zOrder = zOrderAfter
            undoStack.append(.delete(objects: deleted,
                                     zOrderBefore: zOrderBefore,
                                     zOrderAfter: zOrderAfter))

        case .move(let colorKey, let delta, let detached):
            if let obj = objects[colorKey] {
                obj.move(by: delta)
                // 重做这次移动 = 再次解除附着（与当初拖拽的效果保持一致）
                if detached != nil, let arrow = obj as? Arrow {
                    arrow.startAttachment = nil
                    arrow.endAttachment = nil
                }
                updateAttachedArrows(forParent: colorKey)
                undoStack.append(.move(colorKey: colorKey, delta: delta, detached: detached))
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
