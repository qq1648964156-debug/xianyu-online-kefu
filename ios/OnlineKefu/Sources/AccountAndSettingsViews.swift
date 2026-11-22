import SwiftUI

struct AccountListView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationView {
            Group {
                if state.loadingAccounts && state.accounts.isEmpty {
                    ProgressView("加载账号…")
                } else if state.accounts.isEmpty {
                    EmptyHint(icon: "person.2.slash",
                              title: "没有可用账号",
                              subtitle: "请先在网页端登录闲鱼账号，并确保账号带有效 cookie")
                } else {
                    List {
                        Section {
                            ForEach(state.accounts) { acc in
                                HStack(spacing: 12) {
                                    AvatarView(url: "", name: acc.displayName.isEmpty ? acc.accountId : acc.displayName, size: 40)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(acc.title).font(.system(size: 15, weight: .medium))
                                        Text(acc.accountId)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 3) {
                                        Text(acc.connected ? "已连接" : "未连接")
                                            .font(.caption2)
                                            .foregroundColor(acc.connected ? .green : .secondary)
                                        if state.selectedAccount?.accountId == acc.accountId {
                                            Text("当前")
                                                .font(.caption2)
                                                .foregroundColor(Theme.accent)
                                        }
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    Task {
                                        await state.select(account: acc)
                                    }
                                }
                            }
                        } header: {
                            Text("点一个账号切换为当前会话列表")
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable { await state.loadAccounts() }
                }
            }
            .navigationTitle("账号")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await state.loadAccounts() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .task {
            if state.accounts.isEmpty { await state.loadAccounts() }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var server = AppSettings.serverURL.absoluteString
    @State private var saved = false
    @State private var showLogoutConfirm = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("服务地址")) {
                    TextField("http://192.168.1.10:9000", text: $server)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    Button("保存地址") {
                        let raw = server.trimmingCharacters(in: .whitespaces)
                        Task {
                            await state.setServer(raw)
                            saved = true
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            saved = false
                        }
                    }
                    if saved {
                        Text("已保存，重新登录后生效").font(.caption).foregroundColor(.green)
                    }
                }

                Section(header: Text("当前登录")) {
                    HStack {
                        Text("用户")
                        Spacer()
                        Text(state.username ?? "-").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("当前账号")
                        Spacer()
                        Text(state.selectedAccount?.displayName ?? "未选择").foregroundColor(.secondary)
                    }
                    // 「账号」Tab 已合并掉：这里给一行概况就够，切换入口在消息页左上角
                    HStack {
                        Text("账号概况")
                        Spacer()
                        Text("\(state.accounts.count) 个 · 已连接 \(state.accounts.filter { $0.connected }.count) 个")
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: Text("已读记录"), footer: Text("进过的会话会记一条已读水位，靠它压住红点（后端没有已读接口）。数字一直不增长说明记录没写入，告我。")) {
                    HStack {
                        Text("已记录会话")
                        Spacer()
                        Text("\(ReadStore.count()) 条").foregroundColor(.secondary)
                    }
                    Button(role: .destructive) {
                        ReadStore.clearAll()
                    } label: {
                        Text("清空已读记录")
                    }
                }

                Section(header: Text("输入"), footer: Text("开启后，聊天输入框会出现麦克风按钮，说话直接转成文字。属于实验功能：若开启后出现卡顿，请关闭本开关。")) {
                    Toggle("语音输入（实验）", isOn: Binding(
                        get: { AppSettings.speechEnabled },
                        set: { AppSettings.speechEnabled = $0 }
                    ))
                }

                Section(header: Text("关于")) {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(appVersion).foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Bundle ID")
                        Spacer()
                        Text(Bundle.main.bundleIdentifier ?? "-")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text("未签名构建，供 TrollStore（巨魔）安装；登录态与网页端各自独立。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Section {
                    Button(role: .destructive) {
                        showLogoutConfirm = true
                    } label: {
                        Text("退出登录").frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("设置")
            .confirmationDialog("确认退出登录？", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
                Button("退出", role: .destructive) { state.logout() }
                Button("取消", role: .cancel) {}
            }
        }
        .navigationViewStyle(.stack)
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
