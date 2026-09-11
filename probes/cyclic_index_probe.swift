// CyclicIndex 的真实行为测试（链接真实 Models.swift）
import Cocoa

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("  \(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : "  → \(detail)")")
    if !ok { failures += 1 }
}

let N = 7   // 工具栏工具数

print("=== 1. 正向步进（末位应回绕到 0）===\n")
check("0 → 1", CyclicIndex.step(0, count: N) == 1, "\(CyclicIndex.step(0, count: N))")
check("5 → 6", CyclicIndex.step(5, count: N) == 6, "\(CyclicIndex.step(5, count: N))")
check("6 → 0（回绕）", CyclicIndex.step(6, count: N) == 0, "\(CyclicIndex.step(6, count: N))")

print("\n=== 2. 反向步进（0 应回绕到末位，这是最容易写错的一格）===\n")
check("1 → 0", CyclicIndex.step(1, count: N, reverse: true) == 0,
      "\(CyclicIndex.step(1, count: N, reverse: true))")
check("0 → 6（反向回绕）", CyclicIndex.step(0, count: N, reverse: true) == 6,
      "\(CyclicIndex.step(0, count: N, reverse: true))")
print("    （Swift 的 % 对负数返回负数：-1 % 7 == -1，所以必须先加 count 再取模）")

print("\n=== 3. current 为 nil（当前工具不在列表里）===\n")
check("nil 正向 → 0", CyclicIndex.step(nil, count: N) == 0)
check("nil 反向 → 末位", CyclicIndex.step(nil, count: N, reverse: true) == N - 1,
      "\(CyclicIndex.step(nil, count: N, reverse: true))")

print("\n=== 4. 全量遍历：正向走 N 步应回到起点 ===\n")
var idx = 0
for _ in 0..<N { idx = CyclicIndex.step(idx, count: N) }
check("N 步后回到 0", idx == 0, "\(idx)")

idx = 0
for _ in 0..<N { idx = CyclicIndex.step(idx, count: N, reverse: true) }
check("反向 N 步后回到 0", idx == 0, "\(idx)")

print("\n=== 5. 边界：count 为 0 或 1 ===\n")
check("count = 0 → 0（不崩）", CyclicIndex.step(0, count: 0) == 0,
      "\(CyclicIndex.step(0, count: 0))")
check("count = 1 正向 → 0", CyclicIndex.step(0, count: 1) == 0)
check("count = 1 反向 → 0", CyclicIndex.step(0, count: 1, reverse: true) == 0)

print("\n=== 6. 越界入参（防御性）===\n")
check("current 远超 count 仍落在合法区间",
      (0..<N).contains(CyclicIndex.step(100, count: N)),
      "\(CyclicIndex.step(100, count: N))")
check("current 为负仍落在合法区间",
      (0..<N).contains(CyclicIndex.step(-3, count: N)),
      "\(CyclicIndex.step(-3, count: N))")

print("\n=== 结果 ===")
if failures == 0 { print("全部通过") } else { print("\(failures) 项失败"); exit(1) }
