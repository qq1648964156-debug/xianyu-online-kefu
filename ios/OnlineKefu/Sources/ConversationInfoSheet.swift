import SwiftUI

/// 会话信息：客户咨询的商品 + 该买家订单 + 常用功能入口
///
/// 为什么需要：原生聊天页只有"回消息"，看不到买家问的是哪个商品、有没有下单、要不要发货，
/// 等于半残。这里把网页端右侧面板的核心信息聚合进来，并给出跳转到网页版管理页的入口
/// （订单管理 / 商品管理 / 智能客服 / 发货设置都跳网页版，避免在手机上重写一遍）。
struct ConversationInfoSheet: View {
    let conversation: Conversation
    let accountId: String

    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var item: ConsultItem?
    @State private var orders: [CustomerOrder] = []
    @State private var loading = true
    @State private var errorText: String?

    var body: some View {
        NavigationView {
            List {
                if let errorText {
                    Section { Text(errorText).font(.footnote).foregroundColor(.red) }
                }

                // MARK: 咨询商品
                Section("客户咨询的商品") {
                    if loading {
                        HStack { ProgressView(); Text("加载中…").font(.footnote).foregroundColor(.secondary) }
                    } else if let item {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 10) {
                                if !item.image.isEmpty, let url = URL(string: item.image) {
                                    AsyncImage(url: url) { img in
                                        img.resizable().scaledToFill()
                                    } placeholder: {
                                        RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .tertiarySystemFill))
                                    }
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).font(.system(size: 14, weight: .medium)).lineLimit(3)
                                    HStack(spacing: 8) {
                                        Text("¥\(item.price)").font(.system(size: 14, weight: .semibold)).foregroundColor(.red)
                                        if let q = item.quantity, !q.isEmpty {
                                            Text("库存 \(q)").font(.caption2).foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                            if !item.skus.isEmpty {
                                ForEach(item.skus.prefix(8)) { sku in
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
                                ForEach(item.specLines.prefix(6), id: \.self) { line in
                                    Text(line).font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        Text("没有识别到咨询商品").font(.footnote).foregroundColor(.secondary)
                    }
                }

                // MARK: 订单
                Section("该买家订单（\(orders.count)）") {
                    if orders.isEmpty {
                        Text(loading ? "加载中…" : "暂无订单")
                            .font(.footnote).foregroundColor(.secondary)
                    } else {
                        ForEach(orders) { order in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(order.itemTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Spacer()
                                    Text("¥\(order.amount)").font(.system(size: 13, weight: .semibold)).foregroundColor(.red)
                                }
                                HStack(spacing: 6) {
                                    Text(order.statusText)
                                        .font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.1))
                                        .foregroundColor(.blue)
                                        .cornerRadius(4)
                                    if !order.skuInfo.isEmpty {
                                        Text(order.skuInfo).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(order.placedAt).font(.caption2).foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = order.orderNo
                                } label: { Label("复制订单号", systemImage: "doc.on.doc") }
                            }
                        }
                    }
                }

                // MARK: 功能入口（跳网页版，避免手机上重写管理页）
                Section("更多功能") {
                    entryRow("订单管理", "shippingbox", "/orders")
                    entryRow("商品管理", "square.grid.2x2", "/items")
                    entryRow("智能客服", "sparkles", "/cs-agent")
                    entryRow("账号管理", "person.2", "/accounts")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("会话信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .task { await load() }
    }

    private func entryRow(_ title: String, _ icon: String, _ path: String) -> some View {
        Button {
            state.openInWeb(path)
            dismiss()
        } label: {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let api = APIClient.shared
        async let itemTask = try? api.consultItem(accountId: accountId, cid: conversation.cid)
        async let ordersTask = try? api.customerOrders(accountId: accountId,
                                                       buyerId: conversation.otherUserId,
                                                       chatId: conversation.cid)
        item = await itemTask
        orders = (await ordersTask) ?? []
        if item == nil && orders.isEmpty {
            errorText = "没有拿到商品/订单数据，可能该会话还没有下单"
        }
    }
}
