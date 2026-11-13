import Foundation
import JavaScriptCore

@MainActor
final class SalaryEngine {
    private let context: JSContext
    private var exception: String?
    init() throws {
        guard let c = JSContext() else { throw ClipError("无法初始化计算器") }; context = c
        context.exceptionHandler = { [weak self] _, value in self?.exception = value?.toString() }
        for name in ["salary", "salary-bridge"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "js") else { throw ClipError("缺少工资计算资源") }
            context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
            if exception != nil { throw ClipError("工资计算资源初始化失败") }
        }
    }
    func call(_ function: String, args: [Any] = []) throws -> JSONValue {
        exception = nil
        guard let string = context.objectForKeyedSubscript("NativeSalary")?.objectForKeyedSubscript(function)?.call(withArguments: args)?.toString(), exception == nil else {
            throw ClipError(exception?.replacingOccurrences(of: "Error: ", with: "") ?? "工资计算失败")
        }
        return try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
    }
    func compute(_ data: JSONValue) throws -> JSONValue {
        try call("compute", args: [String(decoding: try JSONEncoder().encode(data), as: UTF8.self)])
    }
    func marginal(_ data: JSONValue, delta: Double) throws -> JSONValue {
        try call("marginal", args: [String(decoding: try JSONEncoder().encode(data), as: UTF8.self), delta])
    }
    func bonusTrap(_ bonus: Double) throws -> JSONValue { try call("bonusTrap", args: [bonus]) }
}

struct SalaryPreset: Identifiable, Equatable, Codable {
    let name: String
    let desc: String
    let data: JSONValue
    var id: String { name }
}

enum SalaryPresets {
    static func builtIn(_ defaults: JSONValue) -> [SalaryPreset] {
        func make(_ name: String, _ desc: String, _ changes: [String: JSONValue]) -> SalaryPreset {
            var data = defaults
            for (key, value) in changes { data[key] = value }
            return SalaryPreset(name: name, desc: desc, data: data)
        }
        return [
            SalaryPreset(name: "上海 · 一娃租房", desc: "月薪 32,000 · 年终奖 6 万 · 公积金 7%", data: defaults),
            make("北京 · 双娃房贷", "月薪 45,000 · 年终奖 12 万 · 公积金 12%",
                 ["city": .string("beijing"), "gross": .number(45000), "fundRate": .number(12), "bonus": .number(120000),
                  "children": .integer(2), "elder": .string("share"), "housing": .string("loan"), "pension": .number(1000)]),
            make("深圳 · 应届入职", "月薪 18,000 · 7 月入职 · 仅租房扣除",
                 ["city": .string("shenzhen"), "gross": .number(18000), "fundRate": .number(5), "bonus": .number(20000),
                  "children": .integer(0), "elder": .string("none"), "housing": .string("rent"), "rentTier": .integer(0), "startMonth": .integer(7)]),
            make("杭州 · 扣除用满", "月薪 25,000 · 个人养老金 1,000",
                 ["city": .string("hangzhou"), "gross": .number(25000), "fundRate": .number(12), "bonus": .number(40000),
                  "children": .integer(1), "infants": .integer(1), "elder": .string("only"), "housing": .string("loan"),
                  "study": .bool(true), "pension": .number(1000)]),
            make("成都 · 低收入并入更划算", "月薪 8,000 · 年终奖 2 万",
                 ["city": .string("chengdu"), "gross": .number(8000), "fundRate": .number(12), "bonus": .number(20000),
                  "children": .integer(1), "elder": .string("only"), "housing": .string("rent"), "rentTier": .integer(1)])
        ]
    }
}