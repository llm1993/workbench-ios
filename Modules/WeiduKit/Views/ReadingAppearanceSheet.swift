import SwiftUI

struct ReadingAppearanceSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    ReadingPreview(settings: store.settings)
                    SettingsCard(title: "排版", icon: "textformat") {
                        ChoiceControl(title: "字体", values: ReadingFont.allCases,
                                      selection: $store.settings.readingFont, label: { $0.label })
                        ChoiceControl(title: "正文字号", values: AppSettings.readingSizes,
                                      selection: $store.settings.readingSize, label: { "\($0)" })
                        ChoiceControl(title: "左右留白", values: AppSettings.readingMargins,
                                      selection: $store.settings.readingMargin, label: { "\($0)" })
                    }
                }.padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("阅读排版")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .tint(Theme.accent)
        .presentationDetents([.large])
    }
}
