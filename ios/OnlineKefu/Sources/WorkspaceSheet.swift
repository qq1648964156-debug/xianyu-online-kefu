import SwiftUI

/// 工作区（融合版）
///
/// 网页端是「会话 / 聊天 / 工作区」三个并列 Tab，手机上一屏放不下三个并列视图。
/// 这里改成**分层**：
///   - 会话列表 → 聊天页的上一层（返回即见，不需要 Tab）
///   - 聊天      → 主界面（消息流 + 输入框）
///   - 工作区    → 从底部弹出的这个面板（短语 / 商品 / 订单三段 + 更多功能入口）
/// 一屏内完成"看看买家问了什么、有没有下单、要不要发货、发什么话"，不用来回切 Tab。
struct WorkspaceSheet: View {
    enum Segment: String, CaseIterable, Identifiable {
        case phrases = "短语"
        case item = "商品"
        case orders = "买家订单"
        case allOrders = "全部订单"
        var id: String { rawValue }
    }

    let conversation: Conversation
    let accountId: String
    var initial: Segment = .phrases
    /// 点短语时回填到输入框
    var onPickPhrase: ((String) -> Void)? = nil

    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var segment: Segment = .phrases
    @State private var item: ConsultItem?
    @State private var orders: [CustomerOrder] = []
    @State private var loading = true
    @State private var errorText: String?
    // 全部订单
    @State private var allOrders: [OrderItem] = []
    @State private var allOrdersPage = 1
    @State private var allOrdersHasMore = true
    @State private var allOrdersLoading = false
    @State private var statusFilter = ""

    init(conversation: Conversation, accountId: String,
         initial: Segment = .phrases,
         onPickPhrase: ((String) -> Void)? = nil) {
        self.conversation = conversation
        self.accountId = accountId
        self.initial = initial
        self.onPickPhrase = onPickPhrase
        _segment = State(initialValue: initial)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("", selection: $segment) {
                    ForEach(Segment.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        switch segment {
                        case .phrases: phrasesSection
                        case .item: itemSection
                        case .orders: ordersSection
                        case .allOrders: allOrdersSection
                        }
                        moreSection
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 20)
                }
            }
            .navigationTitle(conversation.otherUserName.isEmpty ? "工作区" : conversation.otherUserName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
        .navigationViewStyle(.stack)
        .task { await load() }
    }

    /// 跳到网页版在线聊天的指定工作区面板（带账号/会话，落地即对）
    private func openWebWorkspace(work: String) {
        // 传原始中文，交给 URLComponents 编码（手写百分号会双重编码 → 页面报网络错误）
        state.openInWeb("/online-chat-new", query: [
            "account_id": state.selectedAccount?.accountId ?? "",
            "cid": conversation.cid,
            "tab": "tools",
            "work": work,
        ])
        dismiss()
    }

    // MARK: - 快捷短语

    private var phrasesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("点一条填入输入框").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button {
                    // 管理入口：新增/编辑/删除
                    dismiss()
                    NotificationCenter.default.post(name: .openPhraseManager, object: nil)
                } label: {
                    Label("管理", systemImage: "slider.horizontal.3").font(.caption)
                }
            }
            if state.quickPhrases.isEmpty {
                Text("还没有快捷短语，点右上角「管理」新增")
                    .font(.footnote).foregroundColor(.secondary)
            } else {
                ForEach(state.quickPhrases) { p in
                    Button {
                        onPickPhrase?(p.content)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(p.title).font(.system(size: 14, weight: .medium))
                            Text(p.content).font(.caption).foregroundColor(.secondary).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 咨询商品

    private var itemSection: some View {
        Group {
            if loading {
                HStack { ProgressView(); Text("加载中…").font(.footnote) }
            } else if let item {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        if !item.image.isEmpty, let url = URL(string: item.image) {
                            AsyncImage(url: url) { img in
                                img.resizable().scaledToFill()
                            } placeholder: {
                                RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .tertiarySystemFill))
                            }
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.system(size: 14, weight: .medium)).lineLimit(3)
                            HStack(spacing: 8) {
                                Text("¥\(item.price)")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.red)
                                if let q = item.quantity, !q.isEmpty {
                                    Text("库存 \(q)").font(.caption2).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    if !item.skus.isEmpty {
                        Divider()
                        ForEach(item.skus.prefix(12)) { sku in
                            HStack {
                                Text(sku.name).font(.caption).lineLimit(1)
                                Spacer()
                                Text("¥\(sku.price)").font(.caption).foregroundColor(.red)
                                if let s = sku.stock, !s.isEmpty {
                                    Text(s).font(.caption2).foregroundColor(.secondary)
                                }
                            }
                        }
                    } else {
                        ForEach(item.specLines.prefix(8), id: \.self) { line in
                            Text(line).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Button {
                        openWebWorkspace(work: "consult")
                    } label: {
                        Label("去商品管理（改价/库存/下架）", systemImage: "square.and.pencil")
                            .font(.footnote)
                    }
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemBackground))
                .cornerRadius(12)
            } else {
                Text("这个会话没识别到咨询商品（可能买家还没点开商品卡）")
                    .font(.footnote).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - 订单

    private var ordersSection: some View {
        Group {
            if loading {
                HStack { ProgressView(); Text("加载中…").font(.footnote) }
            } else if orders.isEmpty {
                Text("该买家还没有订单").font(.footnote).foregroundColor(.secondary)
            } else {
                ForEach(orders) { order in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(order.itemTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Spacer()
                            Text("¥\(order.amount)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.red)
                        }
                        HStack(spacing: 6) {
                            Text(order.statusText)
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.blue.opacity(0.12))
                                .foregroundColor(.blue)
                                .cornerRadius(4)
                            if !order.skuInfo.isEmpty {
                                Text(order.skuInfo).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(order.placedAt).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    .padding(10)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .cornerRadius(10)
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = order.orderNo
                        } label: { Label("复制订单号", systemImage: "doc.on.doc") }
                    }
                }
            }
        }
    }


    // MARK: - 全部订单

    private var allOrdersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $statusFilter) {
                Text("全部").tag("")
                Text("待发货").tag("pending_ship")
                Text("已发货").tag("shipped")
                Text("退款中").tag("refunding")
                Text("已完成").tag("completed")
            }
            .pickerStyle(.segmented)
            .onChange(of: statusFilter) { _ in
                Task { await reloadAllOrders() }
            }

            if allOrdersLoading && allOrders.isEmpty {
                HStack { ProgressView(); Text("加载中…").font(.footnote) }
            } else if allOrders.isEmpty {
                Text("没有订单").font(.footnote).foregroundColor(.secondary)
            } else {
                ForEach(allOrders) { o in
                    Button {
                        // 订单详情/操作只有网页版完整：跳到网页工作区的订单面板
                        openWebWorkspace(work: "allOrders")
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text(o.itemTitle.isEmpty ? "订单 \(o.orderId)" : o.itemTitle)
                                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Spacer()
                                Text("¥\(o.amount)").font(.system(size: 13, weight: .semibold)).foregroundColor(.red)
                            }
                            HStack(spacing: 6) {
                                Text(o.statusLabel)
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .foregroundColor(Theme.accent)
                                    .background(Theme.accent.opacity(0.12))
                                    .cornerRadius(4)
                                if !o.skuInfo.isEmpty {
                                    Text(o.skuInfo).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(o.placedAt).font(.caption2).foregroundColor(.secondary)
                            }
                            HStack(spacing: 6) {
                                Text(o.orderId).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                                if !o.buyerNick.isEmpty {
                                    Text("· \(o.buyerNick)").font(.system(size: 10)).foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { UIPasteboard.general.string = o.orderId } label: {
                            Label("复制订单号", systemImage: "doc.on.doc")
                        }
                    }
                }
                if allOrdersHasMore {
                    Button {
                        Task { await loadAllOrders(next: true) }
                    } label: {
                        HStack {
                            Spacer()
                            if allOrdersLoading { ProgressView().scaleEffect(0.8) }
                            Text("加载更多").font(.footnote)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .task {
            if allOrders.isEmpty { await reloadAllOrders() }
        }
    }

    @MainActor
    private func reloadAllOrders() async {
        allOrdersPage = 1
        allOrdersHasMore = true
        allOrders = []
        await loadAllOrders(next: false)
    }

    @MainActor
    private func loadAllOrders(next: Bool) async {
        guard !allOrdersLoading else { return }
        allOrdersLoading = true
        defer { allOrdersLoading = false }
        do {
            let page = try await APIClient.shared.orders(
                page: next ? allOrdersPage + 1 : 1,
                pageSize: 20,
                status: statusFilter.isEmpty ? nil : statusFilter
            )
            allOrdersPage = next ? allOrdersPage + 1 : 1
            allOrders = next ? allOrders + page.data : page.data
            allOrdersHasMore = allOrders.count < page.total && !page.data.isEmpty
        } catch {
            errorText = (error as? APIError)?.message ?? error.localizedDescription
        }
    }

    // MARK: - 更多功能（跳网页版工作区）

    private var moreSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("网页版工作区（可操作发货/退款/改价）").font(.caption).foregroundColor(.secondary)
            HStack(spacing: 8) {
                workspaceEntry("买家订单", "shippingbox", "orders")
                workspaceEntry("咨询商品", "tag", "consult")
                workspaceEntry("所有订单", "list.bullet.rectangle", "allOrders")
            }
            HStack(spacing: 8) {
                miniEntry("订单管理", "doc.text.magnifyingglass", "/orders")
                miniEntry("商品管理", "square.grid.2x2", "/items")
                miniEntry("智能客服", "sparkles", "/cs-agent")
            }
        }
        .padding(.top, 4)
    }

    private func workspaceEntry(_ title: String, _ icon: String, _ work: String) -> some View {
        Button {
            openWebWorkspace(work: work)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 16))
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Theme.accent.opacity(0.10))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    private func miniEntry(_ title: String, _ icon: String, _ path: String) -> some View {
        Button {
            state.openInWeb(path)
            dismiss()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 16))
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemBackground))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 数据

    private func load() async {
        loading = true
        defer { loading = false }
        let api = APIClient.shared
        await state.loadQuickPhrasesIfNeeded()
        async let itemTask = try? api.consultItem(accountId: accountId, cid: conversation.cid)
        async let ordersTask = try? api.customerOrders(accountId: accountId,
                                                       buyerId: conversation.otherUserId,
                                                       chatId: conversation.cid)
        item = await itemTask
        orders = (await ordersTask) ?? []
    }
}

extension Notification.Name {
    /// 从工作区面板跳到「快捷短语管理」（面板会先关闭）
    static let openPhraseManager = Notification.Name("openPhraseManager")
}
