import SwiftUI

struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    var caption: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 18, content: content)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line, lineWidth: 0.5))
            if let caption {
                Text(caption).font(.system(size: 12)).foregroundStyle(Theme.text3)
                    .lineSpacing(3).padding(.horizontal, 4)
            }
        }
    }
}

struct ChoiceControl<Value: Hashable>: View {
    let title: String
    let values: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    var identifierPrefix: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
            HStack(spacing: 3) {
                ForEach(values, id: \.self) { value in
                    Button { selection = value } label: {
                        Text(label(value))
                            .font(.system(size: 12, weight: selection == value ? .semibold : .regular))
                            .foregroundStyle(selection == value ? Theme.accent : Theme.text2)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(selection == value ? Theme.accentSoft : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title)，\(label(value))")
                    .accessibilityIdentifier("\(identifierPrefix ?? title)-\(String(describing: value))")
                    .accessibilityAddTraits(selection == value ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct AccentPicker: View {
    @Binding var selection: AccentTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("主题色").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
            HStack(spacing: 10) {
                ForEach(AccentTheme.allCases) { accent in
                    Button { selection = accent } label: {
                        ZStack {
                            if selection == accent {
                                Circle()
                                    .stroke(accent.color.opacity(0.45), lineWidth: 2)
                                    .frame(width: 38, height: 38)
                            }
                            Circle()
                                .fill(accent.color)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    if selection == accent {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(Theme.surface)
                                    }
                                }
                        }
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("主题色，\(accent.label)")
                    .accessibilityIdentifier("accent-\(accent.rawValue)")
                    .accessibilityAddTraits(selection == accent ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct ReadingPreview: View {
    let settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("阅读预览").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.accent)
            Text("把时间留给值得读的文字")
                .font(.system(size: 17, weight: .semibold,
                              design: settings.readingFont == .serif ? .serif : .default))
                .foregroundStyle(Theme.text)
            Text("收藏喜欢的来源，慢慢阅读。让每一篇好文章，都有一个安静的位置。")
                .font(.system(size: CGFloat(settings.readingSize) * 0.8,
                              design: settings.readingFont == .serif ? .serif : .default))
                .lineSpacing(5).foregroundStyle(Theme.text2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CGFloat(settings.readingMargin))
        .padding(.vertical, 20)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
