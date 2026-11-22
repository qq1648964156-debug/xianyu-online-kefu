import SwiftUI

struct ConversationListView: View {
    @EnvironmentObject var state: AppState
    @State private var keyword = ""
    @State private var showAccountPicker = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if let err = state.errorText {
                    ErrorBanner(text: err, onDismiss: { state.clearError() }).padding(.top, 6)
                }
                content
            }
            .navigationTitle(accountTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showAccountPicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.left.arrow.right.circle")
                            Text("切换").font(.footnote)
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await state.reloadAll() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showAccountPicker) {
                AccountPickerSheet(isPresented: $showAccountPicker)
                    .environmentObject(state)
            }
        }
        .navigationViewStyle(.stack)
        .task { await state.ensureReady() }
    }

    private var accountTitle: String {
        guard let acc = state.selectedAccount else { return "消息" }
        return acc.displayName.isEmpty ? acc.accountId : acc.displayName
    }

    private var filtered: [Conversation] {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return state.conversations }
        return state.conversations.filter {
            $0.otherUserName.contains(kw) || $0.lastMessageSummary.contains(kw) || $0.itemTitle.contains(kw)
        }
    }

    @ViewBuilder
    private var content: some View {
        if state.selectedAccount == nil {
            EmptyHint(icon: "person.crop.circle.badge.questionmark",
                      title: "还没有选择账号",
                      subtitle: "点左上角「切换」选一个已登录的闲鱼账号")
                .frame(maxHeight: .infinity)
        } else if state.loadingConversations && state.conversations.isEmpty {
            ProgressView("加载会话…").frame(maxHeight: .infinity)
        } else if state.conversations.isEmpty {
            EmptyHint(icon: "tray",
                      title: "暂无会话",
                      subtitle: "该账号还没有买家消息，下拉可刷新")
                .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(filtered) { conv in
                    NavigationLink(destination: ChatView(conversation: conv)) {
                        ConversationRow(conversation: conv)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .onAppear {
                        if conv.cid == filtered.last?.cid {
                            Task { await state.loadMoreConversations() }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $keyword, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索昵称 / 内容 / 商品")
            .refreshable { await state.reloadConversations() }
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(url: conversation.otherUserAvatar, name: conversation.otherUserName, size: 46)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(conversation.otherUserName.isEmpty ? "买家" : conversation.otherUserName)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(conversation.lastMessageTime.chatTimeText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Text(conversation.lastMessageSummary)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                if !conversation.itemTitle.isEmpty {
                    Text(conversation.itemTitle)
                        .font(.caption2)
                        .foregroundColor(Theme.accent)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.1))
                        .cornerRadius(4)
                }
            }
            if conversation.unreadCount > 0 {
                Text("\(conversation.unreadCount)")
                    .font(.caption2.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red)
                    .clipShape(Capsule())
            }
        }
    }
}

struct AccountPickerSheet: View {
    @EnvironmentObject var state: AppState
    @Binding var isPresented: Bool

    var body: some View {
        NavigationView {
            List {
                ForEach(state.accounts) { acc in
                    Button {
                        Task {
                            await state.select(account: acc)
                            isPresented = false
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(acc.title).font(.system(size: 15, weight: .medium))
                                Text(acc.connected ? "IM 已连接" : "IM 未连接")
                                    .font(.caption2)
                                    .foregroundColor(acc.connected ? .green : .secondary)
                            }
                            Spacer()
                            if state.selectedAccount?.accountId == acc.accountId {
                                Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.accent)
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { isPresented = false }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
