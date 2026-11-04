import SwiftUI
import Charts

/// Decimal values returned by FastAPI may be JSON strings; retain their original representation.
enum JSONValue: Codable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), integer(Int), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let x = try? c.decode(Bool.self) { self = .bool(x) }
        else if let x = try? c.decode(String.self) { self = .string(x) }
        else if let x = try? c.decode(Int.self) { self = .integer(x) }
        else if let x = try? c.decode(Double.self) { self = .number(x) }
        else if let x = try? c.decode([String: JSONValue].self) { self = .object(x) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let x): try c.encode(x)
        case .array(let x): try c.encode(x)
        case .string(let x): try c.encode(x)
        case .integer(let x): try c.encode(x)
        case .number(let x): try c.encode(x)
        case .bool(let x): try c.encode(x)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> JSONValue {
        get { if case .object(let x) = self { return x[key] ?? .null }; return .null }
        set { var x = object; x[key] = newValue; self = .object(x) }
    }
    subscript(_ index: Int) -> JSONValue {
        get { array.indices.contains(index) ? array[index] : .null }
        set { var x = array; if x.indices.contains(index) { x[index] = newValue; self = .array(x) } }
    }
    var object: [String: JSONValue] { if case .object(let x) = self { return x }; return [:] }
    var array: [JSONValue] { if case .array(let x) = self { return x }; return [] }
    var text: String {
        switch self { case .string(let x): return x; case .integer(let x): return String(x); case .number(let x): return String(format: "%.12g", x)
        case .bool(let x): return x ? "true" : "false"; default: return "" }
    }
    var numeric: Double? { guard let value = Double(text), value.isFinite else { return nil }; return value }
    var double: Double { numeric ?? 0 }
    var int: Int { guard let d = numeric, d >= Double(Int.min), d < Double(Int.max) else { return 0 }; return Int(d) }
    var flag: Bool { if case .bool(let x) = self { return x }; return text == "true" }
    var isNull: Bool { self == .null }
    static func strings(_ x: [String]) -> Self { .array(x.map(Self.string)) }
}

extension ClipAPI {
    func document(_ path: String, method: String = "GET", payload: JSONValue? = nil) async throws -> JSONValue {
        try await request(path, method: method, body: try payload.map { try JSONEncoder().encode($0) })
    }
    static func path(_ path: String, query: [String: String]) -> String {
        var c = URLComponents(); c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return path + "?" + (c.percentEncodedQuery ?? "")
    }
}

enum Display {
    static func money(_ x: JSONValue) -> String { guard let n = x.numeric else { return "—" }; return n.formatted(.number.precision(.fractionLength(2))) }
    static func percent(_ x: JSONValue) -> String { guard let n = x.numeric else { return "—" }; return (n * 100).formatted(.number.precision(.fractionLength(1))) + "%" }
    static var today: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

struct NativeCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(20).panelSurface(radius: 20)
    }
}

struct NativeFailure: View {
    let message: String
    var body: some View { Label(message, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).padding(.vertical, 8) }
}

struct PlotPoint: Identifiable, Equatable {
    let index: Int; let label: String; let value: Double; let series: String
    var id: String { "\(series)-\(index)" }
}
struct NativeTrend: View, Equatable {
    let title: String
    let points: [PlotPoint]
    @State private var selectedIndex: Int?
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.title == rhs.title && lhs.points == rhs.points }
    private var selected: [PlotPoint] {
        guard let selectedIndex, let nearest = points.min(by: { abs($0.index - selectedIndex) < abs($1.index - selectedIndex) }) else { return [] }
        return points.filter { $0.index == nearest.index }
    }
    var body: some View {
        NativeCard {
            Text(title).font(.headline)
            if points.isEmpty { Text("暂无可绘制的数据").font(.caption).foregroundStyle(.secondary) }
            else {
                Chart {
                  ForEach(points) { p in
                    LineMark(x: .value("时间", p.index), y: .value("数值", p.value))
                        .foregroundStyle(by: .value("系列", p.series))
                        .accessibilityLabel("\(p.label)，\(p.series)").accessibilityValue(p.value.formatted())
                  }
                  if let first = selected.first { RuleMark(x: .value("所选时间", first.index)).foregroundStyle(.secondary.opacity(0.4)) }
                }.frame(height: 190).chartXAxis(.hidden).chartXSelection(value: $selectedIndex)
                if let first = selected.first {
                    Text(first.label).font(.caption.weight(.medium))
                    ForEach(selected) { item in LabeledContent(item.series, value: item.value.formatted(.number.precision(.fractionLength(2)))).font(.caption) }
                }
                HStack { Text(points.first?.label ?? ""); Spacer(); Text(points.last?.label ?? "") }
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct FormChoice: Identifiable { let id: String; let title: String }
struct FormField: Identifiable {
    enum Kind { case text, number, integer, date, secret, choice([FormChoice]), toggle }
    let id: String; let title: String; var kind: Kind = .text; var required = false
    var help: String?; var min: Decimal?; var max: Decimal?
}

struct FormRequest: Identifiable {
    let id = UUID()
    let title: String; let fields: [FormField]; var initial: JSONValue = .object([:])
    var additionalFields: [FormField] = []
    let save: (JSONValue) async throws -> Void

    func validated(_ value: JSONValue) throws -> JSONValue {
        var payload: [String: JSONValue] = [:]
        for field in fields + additionalFields {
            let x = value[field.id], raw = x.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if field.required && raw.isEmpty { throw ClipError("请填写\(field.title)") }
            switch field.kind {
            case .number, .integer:
                if raw.isEmpty { payload[field.id] = .null; continue }
                guard raw.range(of: "^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?$", options: .regularExpression) != nil,
                      let number = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")), !number.isNaN else { throw ClipError("\(field.title)必须是有效数字") }
                if let min = field.min, number < min { throw ClipError("\(field.title)低于允许值") }
                if let max = field.max, number > max { throw ClipError("\(field.title)超过允许值") }
                if case .integer = field.kind, raw.range(of: "^[+-]?[0-9]+$", options: .regularExpression) == nil { throw ClipError("\(field.title)必须是整数") }
                payload[field.id] = .string(raw)
            case .date:
                if raw.isEmpty { payload[field.id] = .null; continue }
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
                guard let date = formatter.date(from: raw), formatter.string(from: date) == raw else { throw ClipError("\(field.title)格式应为 YYYY-MM-DD") }
                payload[field.id] = .string(raw)
            case .toggle: payload[field.id] = .bool(x.flag)
            case .secret: payload[field.id] = .string(x.text)
            default: payload[field.id] = .string(raw)
            }
        }
        return .object(payload)
    }
}

struct NativeForm: View {
    let request: FormRequest
    @Environment(\.dismiss) private var dismiss
    @State private var value: JSONValue
    @State private var saving = false
    @State private var failure: String?
    init(_ request: FormRequest) { self.request = request; _value = State(initialValue: request.initial) }
    var body: some View {
        NavigationStack {
            Form {
                ForEach(request.fields) { field in
                    Section {
                        control(field).accessibilityIdentifier("form-field-" + field.id)
                    } footer: { if let help = field.help { Text(help) } }
                }
                if !request.additionalFields.isEmpty {
                    Section {
                        DisclosureGroup {
                            ForEach(request.additionalFields) { field in
                                VStack(alignment: .leading, spacing: 6) {
                                    control(field).accessibilityIdentifier("form-field-" + field.id)
                                    if let help = field.help { Text(help).font(.caption).foregroundStyle(.secondary) }
                                }.padding(.vertical, 4)
                            }
                        } label: {
                            Text("更多信息").accessibilityIdentifier("form-additional-fields")
                        }
                    }
                }
                if let failure { NativeFailure(message: failure).accessibilityIdentifier("form-failure") }
            }.navigationTitle(request.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saving ? "保存中…" : "保存") { Task { await save() } }.disabled(saving).accessibilityIdentifier("native-form-save")
                    }
                }.interactiveDismissDisabled(saving)
        }
    }
    private func text(_ key: String) -> Binding<String> {
        Binding(get: { value[key].text }, set: { value[key] = .string($0) })
    }
    @ViewBuilder private func control(_ f: FormField) -> some View {
        switch f.kind {
        case .toggle:
            Toggle(f.title, isOn: Binding(get: { value[f.id].flag }, set: { value[f.id] = .bool($0) }))
        case .choice(let choices):
            Picker(f.title, selection: text(f.id)) { ForEach(choices) { Text($0.title).tag($0.id) } }
        case .secret: SecureField(f.title, text: text(f.id)).textInputAutocapitalization(.never)
        case .date:
            TextField(f.title + "（YYYY-MM-DD）", text: text(f.id)).keyboardType(.numbersAndPunctuation)
        case .number: TextField(f.title, text: text(f.id)).keyboardType(.decimalPad)
        case .integer: TextField(f.title, text: text(f.id)).keyboardType(.numberPad)
        case .text: TextField(f.title, text: text(f.id), axis: .vertical)
        }
    }
    private func save() async {
        guard !saving else { return }; saving = true; failure = nil; defer { saving = false }
        do {
            try await request.save(request.validated(value)); dismiss()
        } catch { failure = error.localizedDescription }
    }
}

func choices(_ pairs: [(String, String)]) -> [FormChoice] { pairs.map { FormChoice(id: $0.0, title: $0.1) } }
