import SwiftUI

/// 快捷短语管理：列表 + 新增 + 编辑 + 删除
///
/// 以前原生只能"用"短语，不能改（网页端才可以）。这里补齐增删改。
struct QuickPhrasesManageView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var phrases: [QuickPhrase] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var editing: QuickPhrase?
    @State private var showEditor = false
    @State private var draftTitle = ""
    @State private var draftContent = ""

    var body: some View {
        NavigationView {
            List {
                if let errorText {
                    Section { Text(errorText).font(.footnote).foregroundColor(.red) }
                }
                Section {
                    ForEach(phrases) { p in
                        Button {
                            editing = p
                            draftTitle = p.title
                            draftContent = p.content
                            showEditor = true
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.title).font(.system(size: 14, weight: .medium))
                                Text(p.content).font(.caption).foregroundColor(.secondary).lineLimit(2)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await remove(p) }
                            } label: { Label("删除", systemImage: "trash") }
                        }
                    }
                    if loading {
                        HStack { ProgressView(); Text("加载中…").font(.footnote) }
                    } else if phrases.isEmpty {
                        Text("还没有快捷短语，点右上角 + 新增").font(.footnote).foregroundColor(.secondary)
                    }
                } header: {
                    Text("点击编辑，左滑删除")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("快捷短语")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        editing = nil
                        draftTitle = ""
                        draftContent = ""
                        showEditor = true
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showEditor) {
                editorSheet
            }
        }
        .navigationViewStyle(.stack)
        .task { await load() }
    }

    private var editorSheet: some View {
        NavigationView {
            Form {
                Section("标题（聊天页上方按钮显示的文字）") {
                    TextField("例如：开门时间", text: $draftTitle)
                }
                Section("内容（点一下填进输入框）") {
                    // 不用 TextField(axis: .vertical)（iOS 16+），保持最低 iOS 15
                    TextEditor(text: $draftContent)
                        .frame(minHeight: 120)
                }
            }
            .navigationTitle(editing == nil ? "新增短语" : "编辑短语")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { showEditor = false }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { Task { await save() } }
                        .disabled(draftTitle.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  draftContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            phrases = try await APIClient.shared.quickPhrases()
            errorText = nil
        } catch {
            errorText = (error as? APIError)?.message ?? error.localizedDescription
        }
    }

    private func save() async {
        let title = draftTitle.trimmingCharacters(in: .whitespaces)
        let content = draftContent.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let editing {
                _ = try await APIClient.shared.updateQuickPhrase(id: editing.id, title: title, content: content)
            } else {
                _ = try await APIClient.shared.createQuickPhrase(title: title, content: content)
            }
            showEditor = false
            await load()
            await state.loadQuickPhrases()   // 聊天页上方那排同步刷新
        } catch {
            errorText = (error as? APIError)?.message ?? error.localizedDescription
        }
    }

    private func remove(_ p: QuickPhrase) async {
        do {
            try await APIClient.shared.deleteQuickPhrase(id: p.id)
            await load()
            await state.loadQuickPhrases()
        } catch {
            errorText = (error as? APIError)?.message ?? error.localizedDescription
        }
    }
}
