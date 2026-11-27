#if LAA_BUILD
import LAAKit
import SwiftUI

struct LAAChatProjectDetail: View {
    let store: LAAChatProjectStore
    let id: UUID
    let runtime: any LAAChatProjectRuntime
    var showsGlassTabBar = false
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var draftRevision: UInt64 = 0
    @State private var live = ""
    private var running: Bool { store.inFlight.contains(id) }
    @State private var issue: LAAChatProjectFailure?
    @State private var showEdit = false
    @State private var showDelete = false
    @State private var tail = "tail"

    var body: some View {
        if let project = store.project(id) {
            VStack(spacing: 0) {
                header(project)
                transcript(project)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: LAASpacing.x2) {
                    if let issue { notice(issue, model: project.model) }
                    if !running, project.pending != nil { recovery }
                    composer(project)
                }
                .background(LAAColor.background)
            }
            .laaTabBarClearance(showsGlassTabBar)
            .background(LAAColor.background.ignoresSafeArea())
            .navigationTitle(project.name)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showEdit) {
                LAAChatProjectEditor(store: store, project: project) { _ in }
            }
            .confirmationDialog(LAACopy.ChatProjects.deleteTitle, isPresented: $showDelete, titleVisibility: .visible) {
                Button(LAACopy.ChatProjects.delete, role: .destructive) {
                    do {
                        try store.delete(id)
                        dismiss()
                    } catch { issue = .init(.localStorage) }
                }
            } message: { Text(verbatim: LAACopy.ChatProjects.deleteHistory) }
            .onAppear {
                if project.pending != nil, !running, issue == nil { issue = .init(.unknownDelivery) }
            }
            .accessibilityIdentifier("laa.chatProject.detail")
        }
    }

    private func header(_ project: LAAChatProject) -> some View {
        HStack(spacing: LAASpacing.x2) {
            LAAModelEffortPickers(model: project.model.rawValue, provider: project.model.provider, effort: project.model.effort,
                                  name: project.model.name, identifier: "laa.chatProject") {
                ForEach(LAAChatProject.Model.choices, id: \.self) { model in
                    Button {
                        do { try store.selectModel(model, in: id); issue = nil }
                        catch { issue = .init(.localStorage) }
                    } label: {
                        if project.model == model { Label(model.name, systemImage: "checkmark") }
                        else { Text(verbatim: model.name) }
                    }
                    .disabled(project.model == model)
                }
            } effortMenu: {
                // The Hermes Projects contract allows one effort per route.
                LAAEffortMenu.Row(effort: project.model.effort, selected: true) {}.disabled(true)
            }
            .disabled(running || project.pending != nil)
            Spacer(minLength: 0)
            Menu {
                Button(LAACopy.ChatProjects.edit) { showEdit = true }
                Button(LAACopy.ChatProjects.delete, role: .destructive) { showDelete = true }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: LAASpacing.minimumTouchTarget, height: LAASpacing.minimumTouchTarget)
                    .foregroundStyle(LAAColor.link)
            }
            .accessibilityLabel(LAACopy.ChatProjects.edit)
            .accessibilityIdentifier("laa.chatProject.edit")
            .disabled(running || project.pending != nil)
        }
        .padding(.horizontal, LAASpacing.x4)
        .padding(.bottom, LAASpacing.x2)
    }

    private func transcript(_ project: LAAChatProject) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: LAASpacing.x6) {
                    ForEach(project.history) { message in row(message, model: project.model) }
                    if let pending = project.pending { row(pending, model: project.model) }
                    if !live.isEmpty { reply(live, model: project.model) }
                    if running && live.isEmpty {
                        LAALoadingDots().accessibilityLabel(LAACopy.ChatProjects.running)
                    }
                    Color.clear.frame(height: LAASpacing.x1).id(tail)
                }
                .laaPageWidth()
                .padding(.horizontal, LAASpacing.x6)
                .padding(.vertical, LAASpacing.x3)
                .frame(maxWidth: .infinity)
            }
            .overlay(alignment: .topLeading) {
                if project.history.isEmpty && project.pending == nil && live.isEmpty {
                    Text("Start Here")
                        .font(LAAType.title("Start Here"))
                        .foregroundStyle(LAAColor.secondaryText)
                        .padding(.horizontal, LAASpacing.x6)
                        .padding(.top, LAASpacing.x8)
                        .allowsHitTesting(false)
                }
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: project.pending?.id) { _, _ in proxy.scrollTo(tail, anchor: .bottom) }
            .onChange(of: live.isEmpty) { _, empty in
                if !empty { proxy.scrollTo(tail, anchor: .bottom) }
            }
            .onChange(of: project.history.count) { _, _ in proxy.scrollTo(tail, anchor: .bottom) }
            .accessibilityIdentifier("laa.chatProject.transcript")
        }
    }

    @ViewBuilder private func row(_ message: LAAChatProject.Message, model: LAAChatProject.Model) -> some View {
        if message.role == .user {
            LAAOwnerMessageRow {
                HugsIdealWidth { Text(verbatim: message.text).laaTextStyle(.body) }
                    .padding(.vertical, LAASpacing.x3).padding(.horizontal, LAASpacing.x4)
                    .foregroundStyle(LAAColor.text)
                    .background(LAAColor.subtleSurface, in: RoundedRectangle(cornerRadius: LAARadius.bubble))
                    .textSelection(.enabled)
            }
        } else {
            reply(message.text, model: message.model ?? model)
        }
    }

    private func reply(_ source: String, model: LAAChatProject.Model) -> some View {
        LAAAgentMessageRow(name: model.name) {
            LAAModelMark(model: model.rawValue, provider: model.provider)
        } content: {
            MarkdownText(source: source, foregroundStyle: LAAColor.text)
        }
    }

    private func notice(_ issue: LAAChatProjectFailure, model: LAAChatProject.Model) -> some View {
        let description = switch (issue.code, issue.retryAt) {
        case (.quotaExhausted, .some(let date)):
            LAACopy.ChatProjects.quota(model.name, at: date.formatted(.dateTime.month().day().hour().minute().timeZone()))
        case (.unknownDelivery, _): LAACopy.ChatProjects.unknownDelivery
        case (.localStorage, _): LAACopy.ChatProjects.storageError
        case (.contextOverflow, _): LAACopy.ChatProjects.longInput
        default: LAACopy.ChatProjects.unavailable(model.name)
        }
        return Text(verbatim: description).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, LAASpacing.x6)
            .accessibilityIdentifier("laa.chatProject.issue")
    }

    private var recovery: some View {
        HStack {
            Button(LAACopy.ChatProjects.check) { check() }.accessibilityIdentifier("laa.chatProject.check")
            Spacer(minLength: 0)
            Button(LAACopy.ChatProjects.keepDraft) {
                guard let pending = store.project(id)?.pending else { return }
                do { try store.release(id); setDraft(pending.text); issue = nil }
                catch { issue = .init(.localStorage) }
            }
        }
        .laaTextStyle(.body)
        .buttonStyle(.borderless)
        .foregroundStyle(LAAColor.link)
        .frame(minHeight: LAASpacing.minimumTouchTarget)
        .padding(.horizontal, LAASpacing.x6)
    }

    private func composer(_ project: LAAChatProject) -> some View {
        let enabled = !running && project.pending == nil
        return HStack(alignment: .bottom, spacing: LAASpacing.x2) {
            LAAWorkComposer(text: $text, revision: $draftRevision, placeholder: LAACopy.ChatProjects.question,
                            enabled: enabled, onChange: { _ in }, onSubmit: send,
                            accessibilityPrefix: "laa.chatProject.composer", showsTextSize: false, compact: true)
            LAAGlassActionButton(systemImage: "arrow.up", label: LAACopy.WorkTab.send, role: .send,
                                 enabled: enabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                 identifier: "laa.chatProject.send", action: send)
        }
        .laaComposerGlassGroup()
        .laaPageWidth()
        .padding(.horizontal, LAASpacing.x4)
        .padding(.vertical, LAASpacing.x2)
        .frame(maxWidth: .infinity)
    }

    private func setDraft(_ draft: String) { text = draft; draftRevision &+= 1 }

    private func guidance(_ input: String, project: LAAChatProject) -> LAAChatPokemon.Guidance? {
        guard project.kind == .pokemon else { return nil }
        return LAAChatPokemon.bundled?.guidance(input, route: .init(context: project.context))
            ?? .local(LAACopy.ChatProjects.pokemonDataUnavailable)
    }

    private func send() {
        guard !running, let project = store.project(id), project.pending == nil else { return }
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        let question = LAAChatProject.Message(role: .user, text: input)
        let lookup = guidance(input, project: project)
        issue = nil
        do {
            if case .local(let answer) = lookup {
                try store.complete(question, answer: answer, in: id, localOnly: true)
                setDraft("")
                return
            }
            try store.reserve(question, in: id)
        } catch { issue = .init(.localStorage); return }
        setDraft("")
        store.startTurn(in: id)
        Task { @MainActor in
            defer { store.endTurn(in: id); live = "" }
            do {
                let answer: String? = if case .reference(let reference) = lookup { reference } else { nil }
                let reply = try await LAAChatProjectRunner.run(runtime: runtime, project: project, question: question,
                                                               referenceAnswer: answer) { live = $0 }
                do { try store.complete(question, answer: reply, in: id) }
                catch { issue = .init(.localStorage) }
            } catch let error as LAAChatProjectFailure {
                issue = error
                if error.code != .unknownDelivery { restore(question) }
            } catch { issue = .init(.unknownDelivery) }
        }
    }

    private func restore(_ question: LAAChatProject.Message) {
        do { try store.release(id); setDraft(question.text) }
        catch { issue = .init(.localStorage) }
    }

    private func check() {
        guard !running, let project = store.project(id), let pending = project.pending else { return }
        store.startTurn(in: id)
        Task { @MainActor in
            defer { store.endTurn(in: id) }
            do {
                let pin = try LAAChatProjectRoute(project.pendingModel)
                let events = try await runtime.replay(conversationID: project.pendingConversationID, turnID: pending.id)
                if case .failed(let error) = events.last { issue = error; restore(pending); return }
                guard events.first == .started(pin), case .completed(let output) = events.last else {
                    issue = .init(.unknownDelivery); return
                }
                let answer = switch guidance(pending.text, project: project) {
                case .reference(let reference), .local(let reference): reference
                case nil: output
                }
                guard !answer.isEmpty else { issue = .init(.internalError); return }
                try store.complete(pending, answer: answer, in: id)
                issue = nil
            } catch is LAAChatProjectStore.Failure { issue = .init(.localStorage) }
            catch { issue = .init(.unknownDelivery) }
        }
    }
}

struct LAAChatProjectEditor: View {
    let store: LAAChatProjectStore
    var project: LAAChatProject?
    var onSave: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var context = ""
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Form {
                TextField(LAACopy.ChatProjects.name, text: $name).accessibilityIdentifier("laa.chatProject.name")
                Section(LAACopy.ChatProjects.context) {
                    TextEditor(text: $context)
                        .frame(minHeight: LAASpacing.x8 * 4)
                        .accessibilityLabel(LAACopy.ChatProjects.context)
                        .accessibilityIdentifier("laa.chatProject.context")
                }
                if failed { Text(verbatim: LAACopy.ChatProjects.storageError).foregroundStyle(LAAColor.attention) }
            }
            .navigationTitle(project == nil ? LAACopy.ChatProjects.new : LAACopy.ChatProjects.edit)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LAACopy.ChatProjects.save, action: save)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("laa.chatProject.save")
                }
            }
            .onAppear {
                if let project { name = project.name; context = project.context }
            }
        }
        .tint(LAAColor.link)
        .laaSheetSize(.form)
    }

    private func save() {
        do {
            let id: UUID
            if let project { try store.edit(project.id, name: name, context: context); id = project.id }
            else { id = try store.create(name: name, context: context, model: .hydrogen) }
            onSave(id)
            dismiss()
        } catch { failed = true }
    }
}
#endif
