import SwiftUI

struct ModuleTabs: View {
    @Binding var selection: String
    let items: [FormChoice]
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items) { item in
                        Button { selection = item.id } label: {
                            Text(item.title).font(.subheadline.weight(selection == item.id ? .semibold : .regular))
                                .foregroundStyle(selection == item.id ? Theme.accent : Theme.text2)
                                .padding(.horizontal, 16).frame(minHeight: 38)
                                .background(selection == item.id ? Theme.accentSoft : .clear, in: Capsule())
                        }.buttonStyle(.plain).id(item.id)
                            .accessibilityAddTraits(selection == item.id ? .isSelected : [])
                    }
                }.padding(.horizontal, 20).padding(.vertical, 8)
            }.onChange(of: selection) { _, value in proxy.scrollTo(value, anchor: .center) }
        }.background(GlassBar())
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(Theme.text2)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.text)
                .minimumScaleFactor(0.7).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
