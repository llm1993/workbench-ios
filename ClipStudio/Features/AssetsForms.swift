import SwiftUI
import UniformTypeIdentifiers

struct PendingMutation: Identifiable {
    let id = UUID()
    let title: String
    let path: String
    var method = "DELETE"
    var payload: JSONValue? = nil
}

struct TextExport: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

enum AssetForms {
    static func fields(_ categories: [JSONValue]) -> [FormField] {
        [FormField(id: "name", title: "物品名称", required: true),
         FormField(id: "purchase_price", title: "购入单价（元）", kind: .number, required: true, min: 0),
         FormField(id: "purchase_date", title: "购入日期", kind: .date, required: true),
         FormField(id: "category_id", title: "品类", kind: .choice([FormChoice(id: "", title: "未分类")] + categories.map { FormChoice(id: $0["id"].text, title: $0["name"].text) })),
         FormField(id: "quantity", title: "数量", kind: .number, required: true, min: Decimal(string: "0.00000001")),
         FormField(id: "valuation_method", title: "估值方式", kind: .choice(choices([("manual", "手动估值"), ("depreciation", "折旧"), ("market", "市场估值")]))),
         FormField(id: "current_value", title: "当前估值（元，可空）", kind: .number, help: "未知时留空，不会按零元处理。估值是整件/整批物品的价值，不是单价。", min: 0),
         FormField(id: "expected_life_days", title: "预期寿命（天，可空）", kind: .integer, min: 1),
         FormField(id: "salvage_rate", title: "残值比例（0–1，可空）", kind: .number, min: 0, max: 1),
         FormField(id: "target_daily_cost", title: "目标日均成本（元，可空）", kind: .number, min: 0),
         FormField(id: "tags_input", title: "标签（逗号分隔）"),
         FormField(id: "note", title: "备注")]
    }

    static func initial(_ asset: JSONValue = .null) -> JSONValue {
        if asset.isNull {
            return .object(["quantity": .string("1"), "purchase_price": .string(""), "purchase_date": .string(Display.today), "valuation_method": .string("manual"), "category_id": .string("")])
        }
        var value = asset
        value["category_id"] = .string(asset["category_id"].text)
        value["tags_input"] = .string(asset["tags"].array.map(\.text).joined(separator: ", "))
        return value
    }

    static func payload(_ value: JSONValue) throws -> JSONValue {
        guard value["purchase_date"].text <= Display.today else { throw ClipError("购入日期不能晚于今天") }
        var payload = value.object
        payload["category_id"] = value["category_id"].text.isEmpty ? .null : value["category_id"]
        let tags = value["tags_input"].text.replacingOccurrences(of: "，", with: ",").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        payload["tags"] = .strings(Array(NSOrderedSet(array: tags).array as? [String] ?? []))
        payload.removeValue(forKey: "tags_input")
        return .object(payload)
    }

    @MainActor static func editor(_ model: AssetsModel, asset: JSONValue = .null, created: (@MainActor (Int) -> Void)? = nil) -> FormRequest {
        let all = fields(model.categories), expected = model.session
        let path = asset.isNull ? "/api/assets" : "/api/assets/\(asset["id"].int)"
        return FormRequest(title: asset.isNull ? "新增一件物品" : "编辑物品", fields: Array(all.prefix(4)), initial: initial(asset), additionalFields: Array(all.dropFirst(4))) { value in
            let saved = try await model.write(path, method: asset.isNull ? "POST" : "PATCH", payload: payload(value), expected: expected)
            if asset.isNull, saved["id"].int > 0 { await created?(saved["id"].int) }
        }
    }

    @MainActor static func valuation(_ asset: JSONValue, model: AssetsModel) -> FormRequest {
        let expected = model.session
        return FormRequest(title: "更新估值", fields: [
            FormField(id: "current_value", title: "当前估值（元）", kind: .number, required: true,
                      help: "\(asset["name"].text) · 保存为当前手动估值，自动保留估值快照。其他估值方式可在编辑物品中设置。", min: 0)
        ], initial: .object(["current_value": asset["metrics"]["residual_value"]])) { value in
            var payload = value
            payload["valuation_method"] = .string("manual")
            _ = try await model.write("/api/assets/\(asset["id"].int)", method: "PATCH", payload: payload, expected: expected)
        }
    }

    @MainActor static func ledger(_ key: String, id: Int, model: AssetsModel) -> FormRequest {
        let valuation = key == "valuations", expected = model.session
        var fields = [FormField(id: valuation ? "as_of" : "occurred_on", title: "日期", kind: .date, required: true),
                      FormField(id: valuation ? "value" : "amount", title: "金额（元）", kind: .number, required: true, min: 0)]
        if valuation {
            fields.append(FormField(id: "source", title: "来源", kind: .choice(choices([("manual", "手动"), ("market", "市场"), ("depreciation", "折旧")]))))
        } else {
            fields.append(FormField(id: "kind", title: "类型", kind: .choice(choices(key == "costs" ? [("repair", "维修"), ("accessory", "配件"), ("consumable", "耗材"), ("subscription", "订阅"), ("other", "其他")] : [("rental", "出租"), ("order", "接单"), ("cashback", "返现"), ("other", "其他")]))))
        }
        fields.append(FormField(id: "note", title: "备注"))
        return FormRequest(title: valuation ? "新增估值快照" : key == "costs" ? "记一笔成本" : "记一笔收益", fields: fields,
                           initial: .object([valuation ? "as_of" : "occurred_on": .string(Display.today), valuation ? "source" : "kind": .string(valuation ? "manual" : "other")])) { value in
            _ = try await model.write("/api/assets/\(id)/\(key)", payload: value, expected: expected)
        }
    }

    @MainActor static func sell(_ asset: JSONValue, model: AssetsModel) -> FormRequest {
        let expected = model.session
        return FormRequest(title: "记录卖出", fields: [
            FormField(id: "sold_price", title: "成交价（元）", kind: .number, required: true, min: 0),
            FormField(id: "sold_date", title: "卖出日期", kind: .date, required: true),
            FormField(id: "sold_channel", title: "渠道"), FormField(id: "note", title: "备注")
        ], initial: .object(["sold_date": .string(Display.today)])) { value in
            guard value["sold_date"].text >= asset["purchase_date"].text else { throw ClipError("卖出日期不能早于购入日期") }
            _ = try await model.write("/api/assets/\(asset["id"].int)/sell", payload: value, expected: expected)
        }
    }

    @MainActor static func wish(_ model: AssetsModel, saved: (@MainActor () -> Void)? = nil) -> FormRequest {
        let expected = model.session
        return FormRequest(title: "记下一个心愿", fields: [
            FormField(id: "name", title: "想要什么", required: true),
            FormField(id: "target_amount", title: "目标金额（元）", kind: .number, required: true, min: Decimal(string: "0.01")),
            FormField(id: "target_date", title: "目标日期（可空）", kind: .date), FormField(id: "note", title: "备注")
        ]) { value in
            _ = try await model.write("/api/wishes", payload: value, expected: expected)
            await saved?()
        }
    }

    @MainActor static func deposit(_ wish: JSONValue, model: AssetsModel) -> FormRequest {
        let expected = model.session
        return FormRequest(title: "记一笔攒钱", fields: [
            FormField(id: "amount", title: "这次攒了多少（元）", kind: .number, required: true, help: "只记录攒钱进度，不发生真实转账。", min: 0),
            FormField(id: "occurred_on", title: "日期", kind: .date, required: true), FormField(id: "note", title: "备注")
        ], initial: .object(["occurred_on": .string(Display.today)])) { value in
            _ = try await model.write("/api/wishes/\(wish["id"].int)/deposits", payload: value, expected: expected)
        }
    }

    static var reminderFields: [FormField] {
        [FormField(id: "title", title: "提醒事项"),
         FormField(id: "due_on", title: "到期日", kind: .date, required: true),
         FormField(id: "cycle_unit", title: "周期", kind: .choice(choices([("none", "不重复"), ("day", "天"), ("month", "月"), ("year", "年")]))),
         FormField(id: "cycle_n", title: "每隔几个周期", kind: .integer, required: true, min: 1, max: 3650),
         FormField(id: "amount", title: "参考费用（元，可空）", kind: .number, min: 0),
         FormField(id: "lead_days", title: "提前几天提醒", kind: .integer, required: true, min: 0, max: 366)]
    }

    @MainActor static func reminder(id: Int, model: AssetsModel, existing: JSONValue = .null) -> FormRequest {
        let editing = !existing.isNull, expected = model.session
        let fields = editing ? reminderFields + [FormField(id: "active", title: "启用", kind: .toggle)] : [FormField(id: "kind", title: "类型", kind: .choice(choices([("warranty", "保修"), ("renewal", "续费"), ("consumable", "耗材更换")])))] + reminderFields
        let initial: JSONValue = editing ? existing : .object(["kind": .string("renewal"), "due_on": .string(Display.today), "cycle_unit": .string("month"), "cycle_n": .number(1), "lead_days": .number(7)])
        return FormRequest(title: editing ? "编辑提醒" : "添加提醒", fields: fields, initial: initial) { value in
            var payload = value
            if editing && value["amount"].isNull { payload["clear_amount"] = .bool(true) }
            let path = editing ? "/api/reminders/\(existing["id"].int)" : "/api/assets/\(id)/reminders"
            _ = try await model.write(path, method: editing ? "PATCH" : "POST", payload: payload, expected: expected)
        }
    }

    @MainActor static func completeReminder(_ reminder: JSONValue, model: AssetsModel) -> FormRequest {
        let expected = model.session
        return FormRequest(title: "处理本期提醒", fields: [
            FormField(id: "occurred_on", title: "记账日期", kind: .date, required: true),
            FormField(id: "amount", title: "本次花费（元）", kind: .number, help: "留空或填 0，只完成本期提醒，不新增成本。", min: 0),
            FormField(id: "note", title: "备注")
        ], initial: .object(["occurred_on": .string(Display.today), "amount": reminder["amount"].isNull ? reminder["last_amount"] : reminder["amount"]])) { value in
            var payload = value; payload["due_on"] = reminder["due_on"]
            _ = try await model.write("/api/reminders/\(reminder["id"].int)/done", payload: payload, expected: expected)
        }
    }

    @MainActor static func stopReminder(_ reminder: JSONValue, model: AssetsModel) -> FormRequest {
        let expected = model.session
        return FormRequest(title: "停用提醒", fields: [FormField(id: "retire_asset", title: "同时将这件物品退役", kind: .toggle, help: "默认只停用提醒；勾选后还会将物品退役。")]) { value in
            _ = try await model.write("/api/reminders/\(reminder["id"].int)/stop", payload: value, expected: expected)
        }
    }
}
