import SwiftUI

struct ChatView: View {
    let conversation: Conversation
    @EnvironmentObject var state: AppState

    @State private var draft = ""
    @State private var showQuickPhrases = false
    @State private var showInfo = false
    @State private var showPhraseManager = false
    @State private var showWorkspace = false
    @StateObject private var speech = SpeechRecognizer()
    /// 开始说话前输入框里已有的内容（识别文本追加在后面）
    @State private var draftBeforeSpeech = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !conversation.itemTitle.isEmpty {
                Button {
                    showInfo = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "shippingbox.fill").font(.caption2)
                        Text(conversation.itemTitle)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .foregroundColor(Theme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.accent.opacity(0.08))
                }
                .buttonStyle(.plain)
            }
            messageList
            if let err = state.errorText {
                ErrorBanner(text: err, onDismiss: { state.clearError() })
            }
            composer
        }
        .navigationTitle(conversation.otherUserName.isEmpty ? "聊天" : conversation.otherUserName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        Task { await state.loadMessages(conversation: conversation) }
                    } label: {
                        Label("刷新消息", systemImage: "arrow.clockwise")
                    }
                    Button {
                        UIPasteboard.general.string = conversation.itemTitle
                    } label: {
                        Label("复制商品标题", systemImage: "doc.on.doc")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showInfo) {
            WorkspaceSheet(conversation: conversation,
                           accountId: state.selectedAccount?.accountId ?? "",
                           initial: .item)
                .environmentObject(state)
        }
        .sheet(isPresented: $showPhraseManager) {
            QuickPhrasesManageView().environmentObject(state)
        }
        .sheet(isPresented: $showWorkspace) {
            WorkspaceSheet(conversation: conversation,
                           accountId: state.selectedAccount?.accountId ?? "",
                           initial: .phrases,
                           onPickPhrase: { draft = $0 })
                .environmentObject(state)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPhraseManager)) { _ in
            showPhraseManager = true
        }
        .onChange(of: speech.transcript) { text in
            guard speech.isRecording else { return }
            draft = draftBeforeSpeech + (draftBeforeSpeech.isEmpty ? "" : " ") + text
        }
        .onChange(of: speech.isRecording) { recording in
            if !recording { draftBeforeSpeech = "" }
        }
        .task {
            state.markRead(conversation)          // 红点随打开消失，和网页端一致
            await state.loadMessages(conversation: conversation)
            await state.loadQuickPhrasesIfNeeded()
        }
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if state.messages.isEmpty && state.loadingMessages {
                        ProgressView().padding(.top, 40)
                    }
                    Button {
                        Task { await state.loadOlderMessages(conversation: conversation) }
                    } label: {
                        Text(state.loadingMessages ? "加载中…" : "加载更早的消息")
                            .font(.caption)
                    }
                    .padding(.top, 8)

                    ForEach(state.messages) { msg in
                        MessageBubble(message: msg)
                            .id(msg.messageId)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(Color(uiColor: .systemBackground))
            .onChange(of: state.messages.count) { _ in
                if let last = state.messages.last {
                    withAnimation { proxy.scrollTo(last.messageId, anchor: .bottom) }
                }
            }
            .onAppear {
                if let last = state.messages.last {
                    proxy.scrollTo(last.messageId, anchor: .bottom)
                }
            }
        }
    }

    private func sendDraft() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        Task { await state.send(text: text, to: conversation) }
    }

    // MARK: - 输入区

    private var composer: some View {
        VStack(spacing: 6) {
            if !state.quickPhrases.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button {
                            showPhraseManager = true
                        } label: {
                            Label("管理", systemImage: "slider.horizontal.3")
                                .font(.caption)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color(uiColor: .secondarySystemBackground))
                                .clipShape(Capsule())
                        }
                        ForEach(state.quickPhrases) { phrase in
                            Button {
                                draft = phrase.content
                            } label: {
                                Text(phrase.title)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Theme.accent.opacity(0.1))
                                    .foregroundColor(Theme.accent)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.top, 6)
            }

            HStack(alignment: .bottom, spacing: 8) {
                // 不用 axis: .vertical（iOS 16+），保持 iOS 15 可编译
                TextField("输入回复…", text: $draft, onCommit: sendDraft)
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .cornerRadius(18)

                // 语音转文字：点一下开始说，再点一下停；识别文本实时追加到输入框
                Button {
                    if !speech.isRecording {
                        draftBeforeSpeech = draft
                    }
                    speech.toggle()
                } label: {
                    Image(systemName: speech.isRecording ? "waveform.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(speech.isRecording ? .red : Theme.accent)
                }
                .accessibilityLabel(speech.isRecording ? "停止语音输入" : "语音转文字")

                Button(action: sendDraft) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(draft.isEmpty ? .gray.opacity(0.5) : Theme.accent)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.sending)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(Color(uiColor: .systemBackground))
        .overlay(Divider(), alignment: .top)
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if message.isSelf { Spacer(minLength: 40) }

            VStack(alignment: message.isSelf ? .trailing : .leading, spacing: 3) {
                if !message.isSelf && !message.senderName.isEmpty {
                    Text(message.senderName)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                content
                Text(message.time.chatTimeText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            if !message.isSelf { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: message.isSelf ? .trailing : .leading)
    }

    @ViewBuilder
    private var content: some View {
        if message.isImage {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(message.images, id: \.self) { url in
                    AsyncImage(url: URL(string: url)) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(uiColor: .tertiarySystemFill))
                            .frame(width: 160, height: 120)
                    }
                    .frame(maxWidth: 200, maxHeight: 240)
                    .cornerRadius(10)
                }
            }
        } else {
            Text(message.text)
                .font(.system(size: 15))
                .foregroundColor(message.isSelf ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(message.isSelf ? Theme.bubbleSelf : Theme.bubbleOther)
                .cornerRadius(14)
        }
    }
}
