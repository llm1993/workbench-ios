#if DEBUG
import Foundation

/// In-memory 有数 service for design previews only. Never opens a connection or persists data.
/// These synthetic calculations are NOT a production metrics implementation: production views
/// must continue to display the metrics returned by workbench/backend/app/metrics.py.
enum AssetsPreviewFixtures {
    private static let lock = NSLock()
    private static var state = State(today: Display.today, failFirstMutation: false)

    /// One reset per preview launch; the date and all IDs stay stable until the next reset.
    static func reset(today: String = Display.today,
                      failFirstMutation: Bool = ProcessInfo.processInfo.arguments.contains("--assets-save-failure")) {
        lock.withLock { state = State(today: today, failFirstMutation: failFirstMutation) }
    }

    static func response(_ request: URLRequest) -> (Int, Data)? {
        guard let url = request.url, url.host == "example.invalid" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.first == "api", parts.count >= 2,
              ["assets", "categories", "stats", "reminders", "wishes", "export"].contains(parts[1]) else { return nil }
        // Do not claim other modules' statistics if the shared transport grows more fixtures.
        if parts[1] == "stats", !["dashboard", "overview", "portfolio-trend", "review", "waste"].contains(parts.last ?? "") { return nil }
        let method = request.httpMethod ?? "GET"
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let raw = PreviewTransport.requestBody(request)
        let payload: JSONValue
        if raw.isEmpty { payload = .object([:]) }
        else if let value = try? JSONDecoder().decode(JSONValue.self, from: raw), case .object = value { payload = value }
        else { return failure("预览请求格式错误", status: 422) }
        return lock.withLock {
            if state.failFirstMutation, ["POST", "PATCH", "DELETE"].contains(method),
               ["assets", "reminders", "wishes"].contains(parts[1]) {
                state.failFirstMutation = false
                return failure("预览保存失败，请重试", status: 503)
            }
            return state.respond(parts, method: method, query: query, payload: payload)
        }
    }

    private static func json(_ value: JSONValue, status: Int = 200) -> (Int, Data) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (status, (try? encoder.encode(value)) ?? Data())
    }
    private static func failure(_ detail: String, status: Int = 404) -> (Int, Data) {
        json(.object(["detail": .string(detail)]), status: status)
    }
    private static var empty: (Int, Data) { (204, Data()) }
    private static let leadDays: JSONValue = .object(["warranty": .integer(30), "renewal": .integer(3), "consumable": .integer(3)])
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
    // Used only while holding lock (including State construction/reset).
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        return f
    }()
    private static func validDate(_ value: JSONValue) -> Bool {
        let f = dateFormatter
        guard let date = f.date(from: value.text) else { return false }
        return f.string(from: date) == value.text
    }
    private static func day(_ date: String, plus offset: Int) -> String {
        let f = dateFormatter
        guard let base = f.date(from: date), let result = calendar.date(byAdding: .day, value: offset, to: base) else { return date }
        return f.string(from: result)
    }
    private static func distance(_ from: String, _ to: String) -> Int {
        let f = dateFormatter
        guard let start = f.date(from: from), let end = f.date(from: to) else { return 0 }
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }
    private static func decimal(_ value: JSONValue) -> Decimal? {
        guard !value.isNull, value.numeric != nil else { return nil }
        return Decimal(string: value.text, locale: Locale(identifier: "en_US_POSIX"))
    }
    private static func number(_ value: JSONValue) -> Decimal { decimal(value) ?? 0 }
    private static func rounded(_ value: Decimal, places: Int = 2) -> Decimal {
        var input = value, result = Decimal()
        NSDecimalRound(&result, &input, places, .plain)
        return result
    }
    private static func money(_ value: Decimal?, places: Int = 2) -> JSONValue {
        guard let value else { return .null }
        let text = NSDecimalNumber(decimal: rounded(value, places: places)).stringValue
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        let fraction = pieces.count == 2 ? String(pieces[1]) : ""
        return .string(String(pieces[0]) + "." + fraction + String(repeating: "0", count: max(0, places - fraction.count)))
    }
    private static func sum(_ rows: [JSONValue], _ key: String) -> Decimal {
        rows.reduce(Decimal.zero) { $0 + number($1[key]) }
    }
    private static func append(_ row: JSONValue, to key: String, in value: inout JSONValue) {
        value[key] = .array(value[key].array + [row])
    }
    private static func ledger(id: Int, on: String, kind: String, amount: Int, note: String) -> JSONValue {
        .object(["id": .integer(id), "occurred_on": .string(on), "kind": .string(kind), "amount": money(Decimal(amount)), "note": .string(note)])
    }
    private static func valuation(id: Int, on: String, value: Decimal, source: String = "manual", note: String) -> JSONValue {
        .object(["id": .integer(id), "as_of": .string(on), "value": money(value), "source": .string(source), "note": .string(note)])
    }
    private static func cleanTags(_ value: JSONValue) -> JSONValue {
        var tags: [String] = []
        for tag in value.array {
            let text = tag.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, !tags.contains(text) { tags.append(text) }
        }
        return .strings(tags)
    }

    private struct State {
        let today: String
        var failFirstMutation: Bool
        var assets: [JSONValue] = []
        var reminders: [JSONValue] = []
        var wishes: [JSONValue] = []
        // Independent, monotonically increasing table IDs; deleting a row never reuses its ID.
        var nextAsset = 8, nextCost = 9, nextIncome = 5, nextValuation = 15
        var nextReminder = 7, nextWish = 3, nextDeposit = 4
        let categories: [JSONValue]

        init(today: String, failFirstMutation: Bool) {
            self.today = today; self.failFirstMutation = failFirstMutation
            let definitions: [(Int, String, String, Int, String)] = [
                (1, "数码设备", "digital", 10, "0.1500"), (2, "电脑办公", "digital", 20, "0.1500"),
                (3, "摄影器材", "digital", 30, "0.2500"), (4, "硬通货", "hard", 40, "0.9000"),
                (5, "非标收藏", "soft", 50, "0.4000"), (6, "交通工具", "other", 60, "0.2000"),
                (7, "服务订阅", "soft", 70, "0.0000"), (42, "阅读装备", "other", 80, "0.2500"),
                (8, "其他", "other", 900, "0.3000")
            ]
            categories = definitions.map { id, name, kind, sort, rate in
                .object(["id": .integer(id), "name": .string(name), "kind": .string(kind), "sort": .integer(sort), "default_salvage_rate": .string(rate)])
            }
            func asset(_ id: Int, _ name: String, _ category: Int, _ price: Int, _ age: Int,
                       value: Int?, life: Int, target: Int, tags: [String], note: String) -> JSONValue {
                let purchased = day(today, plus: -age)
                return .object([
                    "id": .integer(id), "name": .string(name), "category_id": .integer(category),
                    "purchase_price": money(Decimal(price)), "purchase_date": .string(purchased), "quantity": .string("1"),
                    "expected_life_days": .integer(life), "target_daily_cost": money(Decimal(target)),
                    "status": .string("in_service"), "valuation_method": .string("manual"),
                    "current_value": money(value.map { Decimal($0) }), "salvage_rate": .null,
                    "sold_price": .null, "sold_date": .null, "sold_channel": .null, "cover_path": .null,
                    "tags": .strings(tags), "note": .string(note),
                    "created_at": .string(purchased + "T09:00:00+08:00"), "updated_at": .string(today + "T09:00:00+08:00"),
                    "costs": .array([]), "incomes": .array([]),
                    "valuations": .array([valuation(id: id, on: purchased, value: Decimal(price), note: "购入初始估值")])
                ])
            }
            assets = [
                asset(1, "MacBook Pro 14", 2, 18999, 365, value: 12800, life: 1825, target: 12, tags: ["工作", "数码"], note: "工作主力电脑，手动记录二手参考价。"),
                asset(2, "iPhone 15 Pro", 1, 7999, 680, value: nil, life: 1095, target: 8, tags: ["随身", "数码"], note: "每天随身使用，按预期寿命折旧。"),
                asset(3, "Sony α7 IV 相机", 3, 16999, 540, value: 10800, life: 1825, target: 10, tags: ["摄影", "副业"], note: "周末拍摄，也记录接单和出租收益。"),
                asset(4, "Trek 公路自行车", 6, 6299, 210, value: 3800, life: 2555, target: 10, tags: ["骑行", "通勤"], note: "周末骑行，也用来短途通勤。"),
                asset(5, "德龙咖啡机", 8, 3299, 120, value: 1900, life: 1825, target: 8, tags: ["日常", "咖啡"], note: "早晨的一杯咖啡；滤芯更换已到期。"),
                asset(6, "AirPods Pro", 1, 1999, 980, value: nil, life: 1095, target: 1, tags: ["随身", "闲置"], note: "旧耳机已经退役，尚未询价；估值未知，不按购入价或零元伪造。"),
                asset(7, "Kindle Oasis", 42, 2599, 760, value: nil, life: 1460, target: 3, tags: ["阅读", "已出"], note: "使用一段时间后转让；自定义品类为阅读装备。")
            ]
            assets[1]["valuation_method"] = .string("depreciation")
            assets[5]["status"] = .string("retired")
            assets[6]["status"] = .string("sold"); assets[6]["sold_price"] = money(1850)
            assets[6]["sold_date"] = .string(day(today, plus: -35)); assets[6]["sold_channel"] = .string("闲鱼")
            assets[0]["costs"] = .array([
                ledger(id: 1, on: day(today, plus: -300), kind: "accessory", amount: 299, note: "扩展坞"),
                ledger(id: 2, on: day(today, plus: -25), kind: "subscription", amount: 28, note: "云盘订阅"),
                ledger(id: 3, on: day(today, plus: -55), kind: "subscription", amount: 28, note: "云盘订阅")
            ])
            assets[1]["costs"] = .array([ledger(id: 4, on: day(today, plus: -180), kind: "repair", amount: 699, note: "更换电池")])
            assets[2]["costs"] = .array([ledger(id: 5, on: day(today, plus: -320), kind: "accessory", amount: 680, note: "备用电池与存储卡")])
            assets[2]["incomes"] = .array([
                ledger(id: 1, on: day(today, plus: -100), kind: "order", amount: 1800, note: "人像拍摄"),
                ledger(id: 2, on: day(today, plus: -15), kind: "order", amount: 2400, note: "活动跟拍"),
                ledger(id: 3, on: day(today, plus: -60), kind: "rental", amount: 600, note: "周末出租")
            ])
            assets[3]["costs"] = .array([ledger(id: 6, on: day(today, plus: -180), kind: "accessory", amount: 360, note: "头盔与车灯")])
            assets[4]["costs"] = .array([ledger(id: 7, on: day(today, plus: -45), kind: "consumable", amount: 128, note: "净水滤芯")])
            assets[6]["costs"] = .array([ledger(id: 8, on: day(today, plus: -700), kind: "accessory", amount: 299, note: "保护套与阅读灯")])
            assets[6]["incomes"] = .array([ledger(id: 4, on: day(today, plus: -750), kind: "cashback", amount: 100, note: "购机返现")])
            let snapshots: [(Int, Int, Int, Int)] = [(0, 8, -180, 15200), (0, 9, -15, 12800), (2, 10, -90, 12000), (2, 11, -7, 10800), (3, 12, -30, 3800), (4, 13, -10, 1900), (6, 14, -35, 1850)]
            for (index, id, offset, value) in snapshots {
                append(valuation(id: id, on: day(today, plus: offset), value: Decimal(value), note: index == 6 ? "卖出成交价" : "二手参考估值"), to: "valuations", in: &assets[index])
            }
            func reminder(_ id: Int, _ asset: Int, _ kind: String, _ title: String, _ offset: Int,
                          _ unit: String, _ n: Int, _ amount: Int?, active: Bool = true) -> JSONValue {
                let due = day(today, plus: offset)
                return .object(["id": .integer(id), "asset_id": .integer(asset), "kind": .string(kind), "title": .string(title),
                                "due_on": .string(due), "cycle_unit": .string(unit), "cycle_n": .integer(n),
                                "amount": money(amount.map { Decimal($0) }), "active": .bool(active),
                                "lead_days": leadDays[kind], "anchor_day": .integer(Int(due.suffix(2)) ?? 1)])
            }
            reminders = [
                reminder(1, 5, "consumable", "净水滤芯", -3, "day", 60, 128),
                reminder(2, 2, "renewal", "iCloud 200GB", 1, "month", 1, 21),
                reminder(3, 1, "warranty", "AppleCare+", 18, "none", 1, nil),
                reminder(4, 1, "renewal", "云盘订阅", 45, "month", 1, 28),
                reminder(5, 5, "consumable", "咖啡豆补充", 12, "day", 30, 98, active: false),
                reminder(6, 6, "warranty", "保修", -10, "none", 1, nil)
            ]
            wishes = [
                .object(["id": .integer(1), "name": .string("下一次旅行"), "target_amount": money(12000),
                         "target_date": .string(day(today, plus: 120)), "status": .string("active"), "note": .string("先攒好预算，再慢慢出发。"),
                         "deposits": .array([
                            .object(["id": .integer(1), "occurred_on": .string(day(today, plus: -30)), "amount": money(1800), "note": .string("本月结余")]),
                            .object(["id": .integer(2), "occurred_on": .string(day(today, plus: -3)), "amount": money(1800), "note": .string("副业收入留存")])])]),
                .object(["id": .integer(2), "name": .string("人体工学椅"), "target_amount": money(4500), "target_date": .null,
                         "status": .string("active"), "note": .string("没有截止日期，按自己的节奏攒。"),
                         "deposits": .array([.object(["id": .integer(3), "occurred_on": .string(day(today, plus: -12)), "amount": money(1200), "note": .null])])])
            ]
        }

        mutating func respond(_ parts: [String], method: String, query: [URLQueryItem], payload: JSONValue) -> (Int, Data) {
            func parameter(_ name: String) -> String { query.first { $0.name == name }?.value ?? "" }
            switch parts[1] {
            case "categories" where parts.count == 2 && method == "GET": return json(.object(["items": .array(categories)]))
            case "assets": return assetResponse(Array(parts.dropFirst(2)), method: method, query: query, payload: payload)
            case "reminders": return reminderResponse(Array(parts.dropFirst(2)), method: method, within: parameter("within"), payload: payload)
            case "wishes": return wishResponse(Array(parts.dropFirst(2)), method: method, status: parameter("wish_status"), payload: payload)
            case "stats" where method == "GET" && parts.count == 3:
                switch parts[2] {
                case "dashboard": return json(.object(["overview": overview(months: Int(parameter("months")) ?? 12), "trend": portfolio(points: Int(parameter("points")) ?? 60)]))
                case "overview": return json(overview(months: Int(parameter("months")) ?? 12))
                case "portfolio-trend": return json(portfolio(points: Int(parameter("points")) ?? 60))
                case "review":
                    let rows = assets.filter { $0["status"].text == "sold" }.map { assetOut($0) }.sorted { number($0["metrics"]["real_pnl"]) < number($1["metrics"]["real_pnl"]) }
                    let total = rows.reduce(Decimal.zero) { $0 + number($1["metrics"]["real_pnl"]) }
                    return json(.object(["count": .integer(rows.count), "total_real_pnl": money(total), "items": .array(rows)]))
                case "waste": return json(waste())
                default: break
                }
            case "export" where method == "GET" && parts.count == 2: return export()
            default: break
            }
            return failure("No assets preview fixture")
        }

        private func assetValidation(_ payload: JSONValue, creating: Bool) -> String? {
            if creating || payload.object["name"] != nil {
                if payload["name"].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写物品名称" }
            }
            if creating || payload.object["purchase_date"] != nil {
                if !validDate(payload["purchase_date"]) || payload["purchase_date"].text > today { return "购入日期不能晚于今天" }
            }
            for key in ["purchase_price", "current_value", "salvage_rate", "target_daily_cost", "quantity", "expected_life_days"] {
                if payload[key].isNull {
                    if (creating && key == "purchase_price") || (payload.object[key] != nil && ["purchase_price", "quantity"].contains(key)) { return "请填写有效金额或数量" }
                    continue
                }
                guard let value = decimal(payload[key]), value >= 0 else { return "金额不能为负数" }
                if ["quantity", "expected_life_days"].contains(key), value <= 0 { return "数量和寿命必须大于零" }
                if key == "expected_life_days", value != rounded(value, places: 0) { return "寿命必须为整数" }
                if key == "salvage_rate", value > 1 { return "残值比例应在 0–1 之间" }
            }
            if !payload["category_id"].isNull, !categories.contains(where: { $0["id"].int == payload["category_id"].int }) { return "品类不存在" }
            if !payload["valuation_method"].isNull, !["manual", "market", "depreciation"].contains(payload["valuation_method"].text) { return "估值方式非法" }
            if !payload["status"].isNull, !["in_service", "retired"].contains(payload["status"].text) { return "标记卖出请使用卖出操作" }
            return nil
        }

        private mutating func assetResponse(_ path: [String], method: String, query: [URLQueryItem], payload: JSONValue) -> (Int, Data) {
            if path.isEmpty {
                if method == "GET" {
                    func parameter(_ name: String) -> String { query.first { $0.name == name }?.value ?? "" }
                    let status = parameter("status"), category = parameter("category_id"), q = parameter("q"), tag = parameter("tag")
                    let order = parameter("order").isEmpty ? "desc" : parameter("order")
                    if !status.isEmpty, !["in_service", "retired", "sold"].contains(status) { return failure("status 取值非法", status: 400) }
                    if !["asc", "desc"].contains(order) { return failure("order 取值非法", status: 422) }
                    if !category.isEmpty, Int(category) == nil { return failure("category_id 取值非法", status: 422) }
                    var rows = assets.filter {
                        (status.isEmpty || $0["status"].text == status) &&
                        (category.isEmpty || Int(category) == 0 || $0["category_id"].int == Int(category)) &&
                        (q.isEmpty || $0["name"].text.range(of: q, options: .caseInsensitive) != nil) &&
                        (tag.isEmpty || $0["tags"].array.contains(.string(tag)))
                    }.map { assetOut($0) }
                    let sort = parameter("sort")
                    rows.sort { lhs, rhs in
                        let comparison: ComparisonResult
                        if ["name", "purchase_date"].contains(sort) {
                            comparison = lhs[sort].text.compare(rhs[sort].text)
                        } else {
                            let key = sort == "value" ? "book_cost" : sort == "hold_days" ? "hold_days" : "gross_daily_cost"
                            let a = number(lhs["metrics"][key]), b = number(rhs["metrics"][key])
                            comparison = a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
                        }
                        // Backend starts with descending IDs, then performs a stable sort.
                        if comparison == .orderedSame { return lhs["id"].int > rhs["id"].int }
                        return order == "asc" ? comparison == .orderedAscending : comparison == .orderedDescending
                    }
                    return json(.object(["total": .integer(rows.count), "items": .array(rows)]))
                }
                if method == "POST" {
                    if let detail = assetValidation(payload, creating: true) { return failure(detail, status: 422) }
                    var asset: JSONValue = .object([
                        "id": .integer(nextAsset), "quantity": .string("1"), "status": .string("in_service"), "valuation_method": .string("manual"),
                        "category_id": .null, "expected_life_days": .null, "target_daily_cost": .null, "current_value": .null, "salvage_rate": .null,
                        "sold_price": .null, "sold_date": .null, "sold_channel": .null, "cover_path": .null, "tags": .array([]), "note": .null,
                        "created_at": .string(today + "T09:00:00+08:00"), "updated_at": .string(today + "T09:00:00+08:00"),
                        "costs": .array([]), "incomes": .array([]), "valuations": .array([])
                    ])
                    applyAssetFields(payload, to: &asset)
                    append(valuation(id: nextValuation, on: asset["purchase_date"].text, value: number(asset["purchase_price"]) * number(asset["quantity"]), note: "购入初始估值"), to: "valuations", in: &asset)
                    nextAsset += 1; nextValuation += 1; assets.append(asset)
                    return json(assetOut(asset, detail: true), status: 201)
                }
                return failure("Unsupported fixture action", status: 405)
            }
            guard let id = Int(path[0]), let index = assets.firstIndex(where: { $0["id"].int == id }) else { return failure("资产不存在") }
            var asset = assets[index]
            if path.count == 1 {
                if method == "GET" { return json(assetOut(asset, detail: true)) }
                if method == "DELETE" {
                    assets.remove(at: index); reminders.removeAll { $0["asset_id"].int == id }
                    return empty
                }
                if method == "PATCH" {
                    if let detail = assetValidation(payload, creating: false) { return failure(detail, status: 400) }
                    let oldValue = asset["current_value"]
                    applyAssetFields(payload, to: &asset)
                    if payload.object["current_value"] != nil, asset["current_value"] != oldValue, !asset["current_value"].isNull {
                        append(valuation(id: nextValuation, on: today, value: number(asset["current_value"]), source: asset["valuation_method"].text, note: "手动更新估值"), to: "valuations", in: &asset)
                        nextValuation += 1
                    }
                    assets[index] = asset
                    return json(assetOut(asset, detail: true))
                }
            }
            if path.count == 2, path[1] == "retire", method == "POST" {
                if asset["status"].text == "sold" { return failure("已卖出的资产不能改为退役", status: 400) }
                asset["status"] = .string("retired"); touch(&asset); assets[index] = asset
                return json(assetOut(asset, detail: true))
            }
            if path.count == 2, path[1] == "sell", method == "POST" {
                guard let price = decimal(payload["sold_price"]), price >= 0, validDate(payload["sold_date"]) else { return failure("请填写成交价和卖出日期", status: 422) }
                if payload["sold_date"].text < asset["purchase_date"].text { return failure("卖出日期不能早于购入日期", status: 400) }
                asset["status"] = .string("sold"); asset["sold_price"] = money(price); asset["sold_date"] = payload["sold_date"]; asset["sold_channel"] = payload["sold_channel"]
                if !payload["note"].text.isEmpty { asset["note"] = .string((asset["note"].text.isEmpty ? "" : asset["note"].text + "\n") + "[卖出] " + payload["note"].text) }
                append(valuation(id: nextValuation, on: payload["sold_date"].text, value: price, note: "卖出成交价"), to: "valuations", in: &asset)
                nextValuation += 1; touch(&asset); assets[index] = asset
                return json(assetOut(asset, detail: true))
            }
            if path.count == 2, path[1] == "reminders" {
                if method == "GET" {
                    let rows = reminders.filter { $0["asset_id"].int == id }.sorted {
                        if $0["active"].flag != $1["active"].flag { return $0["active"].flag }
                        return reminderOrder($0, $1)
                    }.map { reminderOut($0, asset: asset) }
                    return json(.object(["items": .array(rows), "defaults": .object(["lead_days": leadDays])]))
                }
                if method == "POST" { return createReminder(asset: asset, payload: payload) }
            }
            if path.count == 2, method == "GET", path[1] == "daily-cost-series" {
                return json(.object(["asset_id": .integer(id), "name": asset["name"], "points": .array(trend(asset))]))
            }
            if path.count == 2, method == "GET", path[1] == "timeline" { return json(timeline(asset)) }
            if path.count >= 2, ["costs", "incomes", "valuations"].contains(path[1]) {
                let key = path[1], isValuation = key == "valuations"
                if path.count == 3, method == "DELETE", let rowID = Int(path[2]) {
                    guard asset[key].array.contains(where: { $0["id"].int == rowID }) else { return failure("记录不存在") }
                    asset[key] = .array(asset[key].array.filter { $0["id"].int != rowID }); assets[index] = asset
                    // As on the backend, deleting a snapshot does not rewrite current_value.
                    return empty
                }
                if path.count == 2, method == "POST" {
                    let dateKey = isValuation ? "as_of" : "occurred_on", amountKey = isValuation ? "value" : "amount"
                    guard validDate(payload[dateKey]), let amount = decimal(payload[amountKey]), amount >= 0 else { return failure("日期或金额无效", status: 422) }
                    var row = payload; row[amountKey] = money(amount); row["note"] = payload["note"]
                    if isValuation {
                        let source = payload["source"].isNull ? "manual" : payload["source"].text
                        guard ["manual", "market", "depreciation"].contains(source) else { return failure("估值来源非法", status: 422) }
                        row["source"] = .string(source)
                        if let existing = asset[key].array.firstIndex(where: { $0["as_of"] == payload["as_of"] }) {
                            // The real endpoint updates the same-date row without changing current_value.
                            row["id"] = asset[key][existing]["id"]; asset[key][existing] = row
                        } else {
                            row["id"] = .integer(nextValuation); nextValuation += 1
                            let latest = asset[key].array.map { $0["as_of"].text }.max() ?? payload["as_of"].text
                            if payload["as_of"].text >= latest { asset["current_value"] = money(amount); asset["valuation_method"] = .string(source); touch(&asset) }
                            append(row, to: key, in: &asset)
                        }
                    } else {
                        let kind = payload["kind"].isNull ? "other" : payload["kind"].text
                        let allowed = key == "costs" ? ["repair", "accessory", "consumable", "subscription", "other"] : ["rental", "order", "cashback", "other"]
                        guard allowed.contains(kind) else { return failure("台账类型非法", status: 422) }
                        row["kind"] = .string(kind); row["id"] = .integer(key == "costs" ? nextCost : nextIncome)
                        if key == "costs" { nextCost += 1 } else { nextIncome += 1 }
                        append(row, to: key, in: &asset)
                    }
                    assets[index] = asset
                    return json(row, status: 201)
                }
            }
            return failure("Unsupported fixture action", status: 405)
        }

        private func touch(_ asset: inout JSONValue) { asset["updated_at"] = .string(today + "T09:00:00+08:00") }
        private func applyAssetFields(_ payload: JSONValue, to asset: inout JSONValue) {
            let fields = ["name", "category_id", "purchase_price", "purchase_date", "quantity", "expected_life_days", "target_daily_cost", "status", "valuation_method", "current_value", "salvage_rate", "cover_path", "tags", "note"]
            for key in fields where payload.object[key] != nil {
                if key == "tags" { asset[key] = cleanTags(payload[key]) }
                else if ["purchase_price", "target_daily_cost", "current_value"].contains(key) { asset[key] = money(decimal(payload[key])) }
                else if key == "salvage_rate" { asset[key] = money(decimal(payload[key]), places: 4) }
                else if ["category_id", "expected_life_days"].contains(key), !payload[key].isNull { asset[key] = .integer(payload[key].int) }
                else if key == "quantity" { asset[key] = .string(NSDecimalNumber(decimal: number(payload[key])).stringValue) }
                else { asset[key] = payload[key] }
            }
            touch(&asset)
        }

        // Synthetic, DEBUG-only metric responses, kept in the same shapes as serializers.asset_out.
        private func metrics(_ asset: JSONValue, on: String? = nil) -> JSONValue {
            let historical = on != nil, date = on ?? today
            let costs = asset["costs"].array.filter { !historical || $0["occurred_on"].text <= date }
            let incomes = asset["incomes"].array.filter { !historical || $0["occurred_on"].text <= date }
            let end = !historical && asset["status"].text == "sold" ? asset["sold_date"].text : date
            let days = max(1, distance(asset["purchase_date"].text, end) + 1), divisor = Decimal(days)
            let price = rounded(number(asset["purchase_price"])), quantity = number(asset["quantity"])
            let purchase = rounded(price * quantity), extra = rounded(sum(costs, "amount")), income = rounded(sum(incomes, "amount")), book = purchase + extra
            var residual: Decimal?, source = "unknown"
            if asset["status"].text == "sold", let sold = decimal(asset["sold_price"]) { residual = rounded(sold); source = "sold" }
            else if asset["valuation_method"].text == "depreciation" {
                let category = categories.first { $0["id"] == asset["category_id"] } ?? .null
                let rate = min(1, max(0, decimal(asset["salvage_rate"]) ?? decimal(category["default_salvage_rate"]) ?? Decimal(string: "0.20")!))
                let life = max(1, asset["expected_life_days"].isNull ? 1095 : asset["expected_life_days"].int)
                residual = rounded(purchase - purchase * (1 - rate) * min(1, divisor / Decimal(life))); source = "depreciation"
            } else if historical {
                let snapshot = asset["valuations"].array.filter { $0["as_of"].text > asset["purchase_date"].text && $0["as_of"].text <= date }.sorted { $0["as_of"].text < $1["as_of"].text }.last
                residual = snapshot.flatMap { decimal($0["value"]) }
                if residual != nil { source = asset["valuation_method"].text }
            } else if let value = decimal(asset["current_value"]) { residual = rounded(value); source = asset["valuation_method"].text }
            let net = residual.map { rounded((book - income - $0) / divisor) }
            let sold = asset["status"].text == "sold" ? decimal(asset["sold_price"]) : nil
            var breakdown: [String: JSONValue] = ["purchase": money(purchase)]
            for cost in costs { let key = cost["kind"].text; breakdown[key] = money(number(breakdown[key] ?? .null) + number(cost["amount"])) }
            let target = decimal(asset["target_daily_cost"])
            return .object([
                "asset_id": asset["id"], "name": asset["name"], "status": asset["status"], "currency": .string("CNY"),
                "hold_days": .integer(days), "quantity": asset["quantity"], "purchase_price": money(price), "purchase_total": money(purchase),
                "extra_cost": money(extra), "income": money(income), "book_cost": money(book), "residual_value": money(residual), "residual_source": .string(source),
                "gross_daily_cost": money(book / divisor), "net_daily_cost": money(net), "payback_ratio": money(book == 0 ? 0 : income / book, places: 4),
                "value_recovery_ratio": money(residual.flatMap { book == 0 ? nil : (income + $0) / book }, places: 4),
                "time_progress": money(asset["expected_life_days"].int > 0 ? divisor / Decimal(asset["expected_life_days"].int) : nil, places: 4),
                "is_on_target": target.flatMap { target in net.map { .bool($0 <= rounded(target)) } } ?? .null,
                "pnl": money(sold.map { $0 - purchase }), "real_pnl": money(sold.map { $0 - book + income }),
                "retention": money(sold.flatMap { purchase == 0 ? nil : $0 / purchase }, places: 4), "waste": money(sold.map { book - income - $0 }),
                "cost_breakdown": .object(breakdown), "warnings": .strings(residual == nil ? ["未填当前估值，真实日耗与价值回收率无法计算"] : [])
            ])
        }
        private func assetOut(_ asset: JSONValue, detail: Bool = false) -> JSONValue {
            var result = asset.object
            result["category_name"] = categories.first { $0["id"] == asset["category_id"] }?["name"] ?? .null
            result["metrics"] = metrics(asset)
            if detail {
                for key in ["costs", "incomes"] { result[key] = .array(asset[key].array.sorted { $0["occurred_on"].text > $1["occurred_on"].text }) }
                result["valuations"] = .array(asset["valuations"].array.sorted { $0["as_of"].text < $1["as_of"].text })
                result["trend"] = .array(trend(asset))
            } else { for key in ["costs", "incomes", "valuations"] { result.removeValue(forKey: key) } }
            return .object(result)
        }
        private func sample(_ days: Int, limit: Int) -> [Int] {
            let step = max(1, (days + limit - 1) / limit)
            var result = Array(stride(from: 1, through: days, by: step))
            if result.last != days { result.append(days) }
            return result
        }
        private func trend(_ asset: JSONValue) -> [JSONValue] {
            let current = metrics(asset), days = current["hold_days"].int
            return sample(days, limit: 40).map { index in
                let on = day(asset["purchase_date"].text, plus: index - 1)
                let m = index == days ? current : metrics(asset, on: on)
                return .object(["on": .string(on), "day": .integer(index), "invested": m["book_cost"], "income": m["income"],
                                "residual": m["residual_value"], "gross": m["gross_daily_cost"], "net": m["net_daily_cost"]])
            }
        }
        private func timeline(_ asset: JSONValue) -> JSONValue {
            let dates = Set(asset["valuations"].array.map { $0["as_of"].text } + asset["incomes"].array.map { $0["occurred_on"].text }).sorted()
            let points: [JSONValue] = dates.map { on in
                let snapshot = asset["valuations"].array.last { $0["as_of"].text == on }
                return .object(["date": .string(on), "value": snapshot?["value"] ?? .null,
                                "cum_income": money(sum(asset["incomes"].array.filter { $0["occurred_on"].text <= on }, "amount"))])
            }
            return .object(["asset_id": asset["id"], "name": asset["name"], "purchase_date": asset["purchase_date"], "purchase_total": metrics(asset)["purchase_total"], "points": .array(points)])
        }

        private func overview(months: Int) -> JSONValue {
            let computed = assets.map { (asset: $0, metric: metrics($0)) }
            var book = Decimal.zero, value = Decimal.zero, income = Decimal.zero, gross = Decimal.zero, net = Decimal.zero
            var buckets: [String: JSONValue] = [:]
            for (asset, m) in computed {
                let b = number(m["book_cost"]), v = decimal(m["residual_value"]) ?? b, i = number(m["income"])
                book += b; value += v; income += i
                if asset["status"].text == "in_service" { gross += number(m["gross_daily_cost"]); net += number(m["net_daily_cost"]) }
                let key = asset["status"].text, old = buckets[key] ?? .null
                buckets[key] = .object(["count": .integer(old["count"].int + 1), "book_cost": money(number(old["book_cost"]) + b),
                                        "value": money(number(old["value"]) + v), "income": money(number(old["income"]) + i)])
            }
            var monthly: [JSONValue] = []
            let f = dateFormatter, first = String(today.prefix(7)) + "-01"
            if let base = f.date(from: first) {
                for offset in (1 - min(36, max(1, months)))...0 {
                    guard let date = calendar.date(byAdding: .month, value: offset, to: base), let next = calendar.date(byAdding: .month, value: 1, to: date) else { continue }
                    let start = f.string(from: date), end = f.string(from: next)
                    var amortized = Decimal.zero, invested = Decimal.zero
                    for (asset, m) in computed {
                        let purchased = asset["purchase_date"].text, last = asset["status"].text == "sold" ? asset["sold_date"].text : today
                        let lower = max(purchased, start), upper = min(last, day(end, plus: -1))
                        if lower <= upper { amortized += number(m["gross_daily_cost"]) * Decimal(distance(lower, upper) + 1) }
                        if start <= purchased, purchased < end { invested += number(m["purchase_total"]) }
                        invested += sum(asset["costs"].array.filter { start <= $0["occurred_on"].text && $0["occurred_on"].text < end }, "amount")
                        invested -= sum(asset["incomes"].array.filter { start <= $0["occurred_on"].text && $0["occurred_on"].text < end }, "amount")
                    }
                    monthly.append(.object(["month": .string(String(start.prefix(7))), "amortized": money(amortized), "invested": money(invested)]))
                }
            }
            let top = computed.filter { $0.asset["status"].text != "sold" }.sorted {
                let a = number($0.metric["gross_daily_cost"]), b = number($1.metric["gross_daily_cost"])
                return a == b ? $0.asset["id"].int < $1.asset["id"].int : a > b
            }.prefix(10).map { assetOut($0.asset) }
            return .object(["as_of": .string(today), "net_value": money(value), "book_cost": money(book), "income_total": money(income),
                            "unrealized": money(value - book), "asset_count": .integer(assets.count), "daily_burn": money(gross), "daily_net_burn": money(net),
                            "monthly_burn": money(gross * 30), "by_status": .object(buckets), "top_daily_cost": .array(top), "monthly": .array(monthly),
                            "pending_valuation": .array(computed.filter { $0.metric["residual_value"].isNull }.map { .object(["id": $0.asset["id"], "name": $0.asset["name"]]) })])
        }
        private func portfolio(points: Int) -> JSONValue {
            guard let start = assets.map({ $0["purchase_date"].text }).min() else { return .object(["as_of": .string(today), "points": .array([])]) }
            let days = max(1, distance(start, today) + 1)
            var dates = Set(sample(days, limit: min(200, max(8, points))).map { day(start, plus: $0 - 1) })
            for asset in assets {
                dates.insert(asset["purchase_date"].text)
                if !asset["sold_date"].isNull, asset["sold_date"].text <= today { dates.insert(asset["sold_date"].text) }
            }
            let rows: [JSONValue] = dates.sorted().map { on in
                var book = Decimal.zero, value = Decimal.zero, gross = Decimal.zero, net = Decimal.zero
                var count = 0, burning = 0, known = false
                for asset in assets where asset["purchase_date"].text <= on {
                    let m = on == today ? metrics(asset) : metrics(asset, on: on), b = number(m["book_cost"])
                    count += 1; book += b; value += decimal(m["residual_value"]) ?? b
                    let active = asset["status"].text == "in_service" || (asset["status"].text == "sold" && on <= asset["sold_date"].text)
                    if active {
                        burning += 1; gross += number(m["gross_daily_cost"])
                        if let n = decimal(m["net_daily_cost"]) { net += n; known = true }
                    }
                }
                return .object(["on": .string(on), "day": .integer(distance(start, on) + 1), "asset_count": .integer(count), "burning_count": .integer(burning),
                                "value": money(value), "book_cost": money(book), "gross_daily": money(gross), "net_daily": money(known ? net : nil)])
            }
            return .object(["as_of": .string(today), "points": .array(rows)])
        }
        private func waste() -> JSONValue {
            var alerts: [JSONValue] = []
            for asset in assets {
                let m = metrics(asset), name = asset["name"].text
                func alert(_ level: String, _ kind: String, _ title: String, _ detail: String, _ amount: JSONValue) -> JSONValue {
                    .object(["level": .string(level), "kind": .string(kind), "asset_id": asset["id"], "title": .string(title), "detail": .string(detail), "amount": amount])
                }
                if m["is_on_target"] == .bool(false) { alerts.append(alert("warn", "over_target", name + " 日耗超出目标", "真实日耗 \(m["net_daily_cost"].text) 元 > 目标 \(asset["target_daily_cost"].text) 元", m["net_daily_cost"])) }
                if m["residual_value"].isNull, asset["status"].text != "sold" { alerts.append(alert("info", "missing_valuation", name + " 缺当前估值", "补一个残值才能算出真实日耗", .null)) }
                if asset["status"].text == "retired" {
                    let tied = number(m["book_cost"]) - number(m["income"])
                    alerts.append(alert(tied > 0 ? "warn" : "info", "retired_not_sold", name + " 已退役但未卖出", "仍占压账面 \(m["book_cost"].text) 元，考虑出掉回收", money(tied)))
                }
                let subs = asset["costs"].array.filter { $0["kind"].text == "subscription" }
                if subs.count >= 2, let latest = subs.map({ $0["occurred_on"].text }).max(), distance(latest, today) <= 45 {
                    let total = money(sum(subs, "amount"))
                    alerts.append(alert("info", "subscription", name + " 订阅仍在续", "已累计订阅支出 \(total.text) 元，共 \(subs.count) 笔", total))
                }
                if let pnl = decimal(m["real_pnl"]), pnl < 0 { alerts.append(alert("bad", "loss", name + " 卖出后净亏 \(money(-pnl).text) 元", "持有 \(m["hold_days"].text) 天，真实日耗 \(m["net_daily_cost"].text) 元/天", money(pnl))) }
            }
            let rank = ["bad": 0, "warn": 1, "info": 2]
            alerts.sort {
                let a = rank[$0["level"].text] ?? 9, b = rank[$1["level"].text] ?? 9
                return a == b ? $0["title"].text < $1["title"].text : a < b
            }
            return .object(["total": .integer(alerts.count), "alerts": .array(alerts)])
        }

        private func reminderOrder(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
            lhs["due_on"].text == rhs["due_on"].text ? lhs["id"].int < rhs["id"].int : lhs["due_on"].text < rhs["due_on"].text
        }
        private func nextDue(_ reminder: JSONValue, doneOn: String) -> JSONValue {
            let unit = reminder["cycle_unit"].text, kind = reminder["kind"].text, n = reminder["cycle_n"].int
            if kind == "warranty" || unit == "none" { return .null }
            let base = kind == "renewal" ? reminder["due_on"].text : doneOn
            if unit == "day" { return .string(day(base, plus: n)) }
            let f = dateFormatter
            guard let date = f.date(from: base), let first = calendar.date(from: calendar.dateComponents([.year, .month], from: date)),
                  let shifted = calendar.date(byAdding: .month, value: unit == "year" ? 12 * n : n, to: first),
                  let days = calendar.range(of: .day, in: .month, for: shifted) else { return .null }
            let anchor = kind == "renewal" ? reminder["anchor_day"].int : calendar.component(.day, from: date)
            return .string(day(f.string(from: shifted), plus: min(max(1, anchor), days.count) - 1))
        }
        private func reminderOut(_ reminder: JSONValue, asset: JSONValue) -> JSONValue {
            var result = reminder.object; result.removeValue(forKey: "anchor_day")
            let left = distance(today, reminder["due_on"].text), kind = reminder["kind"].text
            let costKind = kind == "renewal" ? "subscription" : kind == "consumable" ? "consumable" : ""
            let title = reminder["title"].text, name = asset["name"].text + (title.isEmpty ? "" : " " + title)
            let when = left == 0 ? "今天" : left == 1 ? "明天" : left == 2 ? "后天" : "\(left) 天后"
            let text: String
            if left < 0 { text = kind == "warranty" ? "保修已过期 \(-left) 天" : kind == "renewal" ? "续费已过 \(-left) 天" : "该换了，已过 \(-left) 天" }
            else { text = when + (kind == "warranty" ? "到期" : kind == "renewal" ? "续费" : "该换了") }
            result["asset_name"] = asset["name"]; result["asset_status"] = asset["status"]
            result["name"] = .string(name); result["text"] = .string(text); result["days_left"] = .integer(left); result["overdue"] = .bool(left < 0)
            result["cost_kind"] = costKind.isEmpty ? .null : .string(costKind); result["next_due"] = nextDue(reminder, doneOn: today); result["notified_stage"] = .integer(0)
            let last = asset["costs"].array.filter { $0["kind"].text == costKind }.sorted {
                $0["occurred_on"] == $1["occurred_on"] ? $0["id"].int < $1["id"].int : $0["occurred_on"].text < $1["occurred_on"].text
            }.last
            result["last_amount"] = last?["amount"] ?? .null
            return .object(result)
        }
        private func reminderValidation(_ payload: JSONValue, creating: Bool) -> String? {
            if creating, !["warranty", "renewal", "consumable"].contains(payload["kind"].text) { return "提醒类型非法" }
            if creating || !payload["due_on"].isNull, !validDate(payload["due_on"]) { return "到期日无效" }
            if !payload["cycle_unit"].isNull, !["none", "day", "month", "year"].contains(payload["cycle_unit"].text) { return "提醒周期非法" }
            for (key, lower, upper) in [("cycle_n", 1, 3650), ("lead_days", 0, 366)] where !payload[key].isNull {
                guard let n = decimal(payload[key]), n >= Decimal(lower), n <= Decimal(upper), n == rounded(n, places: 0) else { return "提醒周期或提前天数无效" }
            }
            if !payload["amount"].isNull {
                guard let amount = decimal(payload["amount"]), amount >= 0, amount <= 1000000000 else { return "提醒金额无效" }
            }
            return nil
        }
        private func normalize(_ reminder: inout JSONValue) {
            if reminder["kind"].text == "warranty" { reminder["cycle_unit"] = .string("none"); reminder["cycle_n"] = .integer(1) }
            reminder["anchor_day"] = .integer(Int(reminder["due_on"].text.suffix(2)) ?? 1)
        }
        private mutating func createReminder(asset: JSONValue, payload: JSONValue) -> (Int, Data) {
            if let detail = reminderValidation(payload, creating: true) { return failure(detail, status: 422) }
            var reminder = payload
            reminder["id"] = .integer(nextReminder); reminder["asset_id"] = asset["id"]; reminder["active"] = .bool(true)
            reminder["title"] = payload["title"].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .null : .string(payload["title"].text.trimmingCharacters(in: .whitespacesAndNewlines))
            reminder["cycle_unit"] = payload["cycle_unit"].isNull ? .string("none") : payload["cycle_unit"]
            reminder["cycle_n"] = payload["cycle_n"].isNull ? .integer(1) : .integer(payload["cycle_n"].int)
            reminder["lead_days"] = payload["lead_days"].isNull ? leadDays[payload["kind"].text] : .integer(payload["lead_days"].int)
            reminder["amount"] = payload["kind"].text == "warranty" ? .null : money(decimal(payload["amount"]))
            normalize(&reminder); reminders.append(reminder); nextReminder += 1
            return json(reminderOut(reminder, asset: asset), status: 201)
        }
        private mutating func reminderResponse(_ path: [String], method: String, within: String, payload: JSONValue) -> (Int, Data) {
            if path.isEmpty, method == "GET" {
                let days = within.isEmpty ? 30 : (Int(within) ?? -1)
                guard (0...366).contains(days) else { return failure("within 取值非法", status: 422) }
                let rows = reminders.filter { reminder in
                    reminder["active"].flag && reminder["due_on"].text <= day(today, plus: days) && assets.contains { $0["id"] == reminder["asset_id"] && $0["status"].text == "in_service" }
                }.sorted(by: reminderOrder).compactMap { reminder -> JSONValue? in
                    guard let asset = assets.first(where: { $0["id"] == reminder["asset_id"] }) else { return nil }
                    return reminderOut(reminder, asset: asset)
                }
                return json(.object(["items": .array(rows), "push": .object(["configured": .bool(false), "server": .null, "hour": .integer(9)]),
                                     "last_check": .string(today + "T09:00:00+08:00"), "defaults": .object(["lead_days": leadDays]), "today": .string(today)]))
            }
            guard let first = path.first, let id = Int(first), let index = reminders.firstIndex(where: { $0["id"].int == id }),
                  let assetIndex = assets.firstIndex(where: { $0["id"] == reminders[index]["asset_id"] }) else { return failure("提醒不存在") }
            var reminder = reminders[index], asset = assets[assetIndex]
            if path.count == 1 {
                if method == "GET" { return json(reminderOut(reminder, asset: asset)) }
                if method == "DELETE" { reminders.remove(at: index); return empty }
                if method == "PATCH" {
                    if let detail = reminderValidation(payload, creating: false) { return failure(detail, status: 422) }
                    var changed = false
                    for key in ["due_on", "cycle_unit", "cycle_n", "active"] where !payload[key].isNull {
                        let value: JSONValue = key == "cycle_n" ? .integer(payload[key].int) : payload[key]
                        if value != reminder[key] { reminder[key] = value; changed = true }
                    }
                    if !payload["title"].isNull { let text = payload["title"].text.trimmingCharacters(in: .whitespacesAndNewlines); reminder["title"] = text.isEmpty ? .null : .string(text) }
                    if payload["clear_amount"].flag { reminder["amount"] = .null }
                    else if !payload["amount"].isNull, reminder["kind"].text != "warranty" { reminder["amount"] = money(decimal(payload["amount"])) }
                    if !payload["lead_days"].isNull { reminder["lead_days"] = .integer(payload["lead_days"].int) }
                    if changed { normalize(&reminder) }
                    reminders[index] = reminder
                    return json(reminderOut(reminder, asset: asset))
                }
            }
            if path.count == 2, path[1] == "stop", method == "POST" {
                if payload["retire_asset"].flag, asset["status"].text == "sold" { return failure("已卖出的资产不能改为退役", status: 400) }
                reminder["active"] = .bool(false)
                if payload["retire_asset"].flag { asset["status"] = .string("retired"); touch(&asset) }
                reminders[index] = reminder; assets[assetIndex] = asset
                return json(.object(["reminder": reminderOut(reminder, asset: asset), "asset": assetOut(asset)]))
            }
            if path.count == 2, path[1] == "done", method == "POST" {
                guard validDate(payload["due_on"]), payload["occurred_on"].isNull || validDate(payload["occurred_on"]) else { return failure("提醒日期无效", status: 422) }
                if let detail = reminderValidation(.object(["amount": payload["amount"]]), creating: false) { return failure(detail, status: 422) }
                if !reminder["active"].flag || reminder["due_on"] != payload["due_on"] { return json(.object(["already": .bool(true), "reminder": reminderOut(reminder, asset: asset), "cost": .null])) }
                let on = payload["occurred_on"].isNull ? today : payload["occurred_on"].text
                let next = nextDue(reminder, doneOn: on), kind = reminder["kind"].text
                var cost = JSONValue.null
                if kind != "warranty", let amount = decimal(payload["amount"]), amount > 0 {
                    let note = payload["note"].text.trimmingCharacters(in: .whitespacesAndNewlines)
                    cost = .object(["id": .integer(nextCost), "occurred_on": .string(on), "kind": .string(kind == "renewal" ? "subscription" : "consumable"),
                                    "amount": money(amount), "note": .string(note.isEmpty ? "到期提醒：" + reminderOut(reminder, asset: asset)["name"].text : note)])
                    nextCost += 1; append(cost, to: "costs", in: &asset)
                }
                if next.isNull { reminder["active"] = .bool(false) } else { reminder["due_on"] = next }
                reminders[index] = reminder; assets[assetIndex] = asset
                return json(.object(["already": .bool(false), "reminder": reminderOut(reminder, asset: asset), "cost": cost, "asset": assetOut(asset)]))
            }
            return failure("Unsupported fixture action", status: 405)
        }

        private func wishOut(_ wish: JSONValue) -> JSONValue {
            var result = wish.object; result.removeValue(forKey: "deposits")
            let saved = sum(wish["deposits"].array, "amount"), target = number(wish["target_amount"]), remaining = max(0, target - saved)
            let left = wish["target_date"].isNull ? nil : distance(today, wish["target_date"].text)
            result["saved_amount"] = money(saved); result["remaining"] = money(remaining); result["progress"] = money(target > 0 ? saved / target : 0, places: 4)
            result["days_left"] = left.map { .integer($0) } ?? .null
            result["daily_needed"] = money(left.flatMap { $0 > 0 && remaining > 0 ? remaining / Decimal($0) : nil })
            return .object(result)
        }
        private mutating func wishResponse(_ path: [String], method: String, status: String, payload: JSONValue) -> (Int, Data) {
            if path.isEmpty {
                if method == "GET" {
                    let rows = wishes.filter { status.isEmpty || $0["status"].text == status }.sorted { $0["id"].int > $1["id"].int }.map { wishOut($0) }
                    return json(.object(["total": .integer(rows.count), "items": .array(rows)]))
                }
                if method == "POST" {
                    guard !payload["name"].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let amount = decimal(payload["target_amount"]), amount > 0,
                          payload["target_date"].isNull || validDate(payload["target_date"]) else { return failure("请填写心愿名称和有效目标金额、日期", status: 422) }
                    let wish: JSONValue = .object(["id": .integer(nextWish), "name": payload["name"], "target_amount": money(amount),
                                                   "target_date": payload["target_date"], "status": .string("active"), "note": payload["note"], "deposits": .array([])])
                    nextWish += 1; wishes.append(wish)
                    return json(wishOut(wish), status: 201)
                }
            }
            guard let first = path.first, let id = Int(first), let index = wishes.firstIndex(where: { $0["id"].int == id }) else { return failure("心愿不存在") }
            if path.count == 1, method == "DELETE" { wishes.remove(at: index); return empty }
            if path.count == 2, path[1] == "deposits", method == "POST" {
                guard let amount = decimal(payload["amount"]), amount >= 0, validDate(payload["occurred_on"]) else { return failure("攒钱日期或金额无效", status: 422) }
                let deposit: JSONValue = .object(["id": .integer(nextDeposit), "occurred_on": payload["occurred_on"], "amount": money(amount), "note": payload["note"]])
                append(deposit, to: "deposits", in: &wishes[index]); nextDeposit += 1
                return json(wishOut(wishes[index]), status: 201)
            }
            return failure("Unsupported fixture action", status: 405)
        }
        private func export() -> (Int, Data) {
            var lines: [JSONValue] = [.object(["kind": .string("meta"), "exported_at": .string(today + "T09:00:00+08:00"), "app_version": .string("DEBUG-preview")])]
            // The backend's category record uses `kind` for the category's own type, too.
            for category in categories { var row = category.object; row["kind"] = category["kind"]; lines.append(.object(row)) }
            let assetFields = ["id", "name", "category_id", "purchase_price", "purchase_date", "quantity", "expected_life_days", "target_daily_cost", "status", "valuation_method", "current_value", "salvage_rate", "sold_price", "sold_date", "sold_channel", "tags", "note", "costs", "incomes", "valuations"]
            for asset in assets {
                var row: [String: JSONValue] = ["kind": .string("asset")]
                for key in assetFields { row[key] = asset[key] }
                for key in ["costs", "incomes", "valuations"] { row[key] = .array(asset[key].array.map { var entry = $0.object; entry.removeValue(forKey: "id"); return .object(entry) }) }
                lines.append(.object(row))
            }
            for wish in wishes {
                var row = wish.object; row["kind"] = .string("wish")
                row["deposits"] = .array(wish["deposits"].array.map { var entry = $0.object; entry.removeValue(forKey: "id"); return .object(entry) })
                lines.append(.object(row))
            }
            var data = Data()
            for line in lines { data.append(json(line).1); data.append(0x0A) }
            return (200, data)
        }
    }
}
#endif
