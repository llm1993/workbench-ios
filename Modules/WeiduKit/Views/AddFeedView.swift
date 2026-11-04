import SwiftUI

struct AddFeedView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var busyTitle = ""
    @State private var errorText = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label("从喜欢的网站开始", systemImage: "dot.radiowaves.left.and.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("粘贴网站首页或 RSS 地址，未读会自动寻找可订阅的内容。")
                        .font(.system(size: 13)).foregroundStyle(Theme.text2).lineSpacing(4)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("网站或订阅地址")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.text2)

                        HStack(spacing: 8) {
                            Image(systemName: "link").foregroundStyle(Theme.accent)
                            TextField("https://example.com", text: $input)
                                .font(.system(size: 15))
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focused)
                                .submitLabel(.go)
                                .onSubmit { Task { await addManual() } }
                            if !input.isEmpty {
                                Button {
                                    input = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(Theme.text3)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 50)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Button {
                            Task { await addManual() }
                        } label: {
                            HStack(spacing: 8) {
                                if !busyTitle.isEmpty {
                                    ProgressView().controlSize(.small).tint(Theme.background)
                                }
                                Text(busyTitle.isEmpty ? "添加订阅" : "正在识别…")
                            }
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.surface)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Theme.accent.opacity(busyTitle.isEmpty ? 1 : 0.65))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(busyTitle != "" || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if !errorText.isEmpty {
                            Text(errorText)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Color(hex: 0xD9705F))
                        }
                    }
                    .padding(.bottom, 10)

                    VStack(alignment: .leading, spacing: 0) {
                        Text("发现值得关注的声音")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.text3)
                            .tracking(0.6)
                            .padding(.bottom, 4)

                        ForEach(Recommendations.all) { item in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.system(size: 14.5))
                                        .foregroundStyle(Theme.text)
                                    Text(Format.host(item.url))
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.text3)
                                }
                                Spacer()
                                if store.isSubscribed(item.url) {
                                    Text("已订阅")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.text3)
                                } else {
                                    Button {
                                        Task { await addRecommended(item) }
                                    } label: {
                                        Text(busyTitle == item.title ? "添加中…" : "添加")
                                            .padding(.horizontal, 12)
                                            .frame(minHeight: 40)
                                            .background(Theme.accentSoft, in: Capsule())
                                    }
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.accent)
                                    .buttonStyle(.plain)
                                    .disabled(!busyTitle.isEmpty)
                                }
                            }
                            .padding(.vertical, 12)
                            Divider().overlay(Theme.line)
                        }
                    }
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("添加订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .tint(Theme.accent)
        .interactiveDismissDisabled(!busyTitle.isEmpty)
    }

    private func addManual() async {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, busyTitle.isEmpty else { return }
        busyTitle = value
        errorText = ""
        do {
            _ = try await store.addFeed(value)
            dismiss()
        } catch {
            errorText = (error as? WeiduError)?.errorDescription ?? error.localizedDescription
            busyTitle = ""
        }
    }

    private func addRecommended(_ item: RecommendedFeed) async {
        guard busyTitle.isEmpty else { return }
        busyTitle = item.title
        errorText = ""
        do {
            _ = try await store.addFeed(item.url, directTitle: item.title)
            dismiss()
        } catch {
            errorText = (error as? WeiduError)?.errorDescription ?? error.localizedDescription
            busyTitle = ""
        }
    }
}
