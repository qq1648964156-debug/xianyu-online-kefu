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
                    Menu {
                        Button {
                            state.markAllRead()
                        } label: {
                            Label("全部标为已读", systemImage: "checkmark.circle")
                        }
                        Button {
                            Task { await state.reloadAll() }
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
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

    /// 标题优先显示**店铺名**（后端 account_id 就是店铺名，如「成都惠生活」），
    /// display_name 只是闲鱼昵称，卖家用它分不清店铺
    private var accountTitle: String {
        guard let acc = state.selectedAccount else { return "消息" }
        return acc.accountId.isEmpty ? acc.displayName : acc.accountId
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
                        ConversationRow(conversation: conv,
                                    isRead: state.isRead(conv),
                                    orderTag: state.orderTag(for: conv))
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
    /// 已读判定（渲染层再压一次，防止刷新流程漏掉 apply 时红点复现）
    var isRead: Bool = false
    /// 买家订单状态（有订单才显示，对齐网页版"已发货/交易成功"标签）
    var orderTag: ConversationOrderTag?

    private static func chipColor(_ status: String) -> Color {
        switch status {
        case "refunding": return .orange
        case "refunded": return .gray
        case "pending_payment": return .red
        case "pending_ship", "pending", "paid": return .orange
        case "shipped": return .blue
        case "completed": return .green
        case "cancelled": return .gray
        default: return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(url: conversation.otherUserAvatar, name: conversation.otherUserName, size: 46)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(conversation.otherUserName.isEmpty ? "买家" : conversation.otherUserName)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    if let tag = orderTag {
                        Text(tag.chatLabel)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .foregroundColor(Self.chipColor(tag.status))
                            .background(Self.chipColor(tag.status).opacity(0.12))
                            .cornerRadius(4)
                            .fixedSize()
                    }
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
            if conversation.unreadCount > 0 && !isRead {
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
                Section {
                    HStack(spacing: 6) {
                        Image(systemName: "storefront").font(.caption)
                        Text("共 \(state.accounts.count) 个店铺 · 已连接 \(state.accounts.filter { $0.connected }.count) 个")
                            .font(.caption)
                        Spacer()
                        if state.loadingAccounts {
                            ProgressView().scaleEffect(0.7)
                        }
                    }
                    .foregroundColor(.secondary)
                }

                Section("点一个切换为当前店铺") {
                    ForEach(state.accounts) { acc in
                        Button {
                            Task {
                                await state.select(account: acc)
                                isPresented = false
                            }
                        } label: {
                            HStack(spacing: 10) {
                                // 状态点
                                Circle()
                                    .fill(acc.connected ? Color.green : Color.gray.opacity(0.35))
                                    .frame(width: 8, height: 8)

                                VStack(alignment: .leading, spacing: 3) {
                                    // 店铺名（account_id）
                                    Text(acc.accountId)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.primary)
                                    HStack(spacing: 6) {
                                        if !acc.displayName.isEmpty, acc.displayName != acc.accountId {
                                            Text(acc.displayName)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        if !acc.remark.isEmpty {
                                            Text(acc.remark)
                                                .font(.caption2)
                                                .padding(.horizontal, 5).padding(.vertical, 1)
                                                .background(Color.orange.opacity(0.15))
                                                .foregroundColor(.orange)
                                                .cornerRadius(4)
                                        }
                                        Text(acc.connected ? "IM 已连接" : "IM 未连接")
                                            .font(.caption2)
                                            .foregroundColor(acc.connected ? .green : .secondary)
                                    }
                                }
                                Spacer()
                                if state.selectedAccount?.accountId == acc.accountId {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.accent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await state.loadAccounts() }
            .navigationTitle("切换店铺")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        Task { await state.loadAccounts() }
                    } label: { Image(systemName: "arrow.clockwise") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { isPresented = false }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
