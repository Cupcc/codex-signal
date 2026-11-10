import AppKit
import SwiftUI
import SignalCore

struct IslandView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var layoutState: IslandLayoutState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settingsVisible = false
    @State private var hoveredID: String?
    @State private var scrollPositionID: String?
    @Namespace private var filterSelection

    private let muted = Color(red: 0.61, green: 0.65, blue: 0.71)
    private var layout: IslandLayout { layoutState.layout }
    private var motion: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.18) }
    private var outline: IslandOutline { IslandOutline(attached: layout.topInset > 0, radius: model.expanded || model.islandNotice != nil ? 22 : 13) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                // Fixed destination dimensions keep text from reflowing while the
                // native panel grows. The same root retains scroll/settings state.
                expandedContent
                    .frame(width: layout.expandedSize.width, height: layout.expandedSize.height)
                    .opacity(model.expanded ? 1 : 0)
                    .allowsHitTesting(model.expanded)
                    .accessibilityHidden(!model.expanded)
                collapsedContent
                    .frame(width: model.islandNotice == nil ? layout.compactSize.width : layout.noticeSize.width,
                           height: model.islandNotice == nil ? layout.compactSize.height : layout.noticeSize.height,
                           alignment: .top)
                    .opacity(model.expanded ? 0 : 1)
                    .allowsHitTesting(!model.expanded)
                    .accessibilityHidden(model.expanded)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .background(layout.topInset > 0 ? Color.black : Color(red: 0.045, green: 0.052, blue: 0.065))
            .overlay {
                outline.stroke(model.islandNotice.map { PhaseAppearance($0.primary.phase).color.opacity(0.55) } ?? Color.white.opacity(0.15), lineWidth: 1)
                    .mask(Rectangle().padding(.top, layout.topInset > 0 ? 1 : 0))
                    .allowsHitTesting(false)
            }
            .clipShape(outline)
            .animation(motion, value: model.expanded)
            .animation(motion, value: model.islandNotice?.id)
        }
        .preferredColorScheme(.dark)
        .onChange(of: model.expanded) { _, expanded in
            if !expanded { settingsVisible = false; hoveredID = nil }
        }
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            if !layout.headerUsesNotchSpace { Color.clear.frame(height: layout.topInset) }
            statusBar
            toolbar
            if model.visibleSessions.isEmpty {
                emptyState
            } else {
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(model.visibleSessions) { session in
                                sessionRow(session)
                                    .id(session.id)
                                    .transition(.opacity)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                        .scrollTargetLayout()
                        .animation(motion, value: model.selectedID)
                        .animation(motion, value: model.visibleSessions.map(\.id))
                    }
                    .scrollIndicators(.hidden)
                    .defaultScrollAnchor(.bottom)
                    .scrollPosition(id: $scrollPositionID, anchor: .bottom)
                    .onChange(of: model.expanded) { _, expanded in
                        if expanded, let id = model.visibleSessions.last?.id { scroll.scrollTo(id, anchor: .bottom) }
                    }
                    .onChange(of: model.pendingOnly) { _, _ in
                        if let id = model.visibleSessions.last?.id { scroll.scrollTo(id, anchor: .bottom) }
                    }
                    .onChange(of: model.visibleSessions.last?.id) { previous, latest in
                        // Follow new activity only while the reader is at the
                        // newest row; browsing older sessions keeps its place.
                        if model.expanded, scrollPositionID == previous || scrollPositionID == nil, let latest {
                            withAnimation(motion) { scroll.scrollTo(latest, anchor: .bottom) }
                        }
                    }
                    .onChange(of: model.selectedID) { _, id in
                        if let id {
                            withAnimation(motion) {
                                scroll.scrollTo(id, anchor: id == model.visibleSessions.last?.id ? .bottom : .center)
                            }
                        }
                    }
                }
            }
            footer
        }
    }

    private var keyboardAction: String {
        guard let session = model.visibleSessions.first(where: { $0.id == model.selectedID }) else { return "打开" }
        switch SessionNavigator.plan(for: session).target {
        case .copyResume, .copyID: return "复制"
        case .terminal, .terminalSession: return "打开"
        case .codexThread: return "打开"
        }
    }

    private var activeCount: Int {
        model.activeSessions.count
    }

    private var statusBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                MascotView(phase: model.aggregatePhase,
                           size: 22, motionActive: model.expanded)
                if !layout.headerUsesNotchSpace {
                    Text("Codex Signal").font(.system(size: 12, weight: .semibold))
                }
                Text("\(activeCount)").monospacedDigit().foregroundStyle(muted)
                    .contentTransition(.numericText())
                if model.isDemo {
                    Text("演示").font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
                        .help("未连接真实会话")
                        .accessibilityLabel("演示，未连接真实会话")
                }
            }
            .frame(maxWidth: .infinity, alignment: layout.headerUsesNotchSpace ? .center : .leading)
            .help("Codex Signal · \(activeCount) 个会话")
            if layout.headerUsesNotchSpace { Color.clear.frame(width: layout.notchWidth) }
            HStack(spacing: 2) {
                Button { model.speechEnabled.toggle() } label: {
                    Image(systemName: model.speechEnabled ? "speaker.wave.2" : "speaker.slash")
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(IslandButtonStyle())
                .help(model.speechEnabled ? "暂停语音" : "恢复语音")
                .accessibilityLabel(model.speechEnabled ? "暂停语音" : "恢复语音")
                Button { settingsVisible.toggle() } label: {
                    Image(systemName: "gearshape").frame(width: 28, height: 28)
                }
                .buttonStyle(IslandButtonStyle())
                .help("设置")
                .accessibilityLabel("设置")
                .popover(isPresented: $settingsVisible, arrowEdge: .bottom) { settings }
                Button { model.setExpanded(false) } label: {
                    Image(systemName: "chevron.up").frame(width: 28, height: 28)
                }
                .buttonStyle(IslandButtonStyle())
                .accessibilityLabel("收起会话")
            }
            .frame(maxWidth: .infinity, alignment: layout.headerUsesNotchSpace ? .center : .trailing)
        }
        .lineLimit(1)
        .font(.system(size: 12))
        .foregroundStyle(Color(red: 0.92, green: 0.94, blue: 0.97))
        .padding(.horizontal, IslandLayout.headerSideInset)
        .frame(height: layout.headerUsesNotchSpace ? max(32, layout.topInset) : 32)
    }

    private var toolbar: some View {
        HStack(spacing: 3) {
            filterButton("全部", count: activeCount, pending: false)
            filterButton("待处理", count: model.pendingCount, pending: true)
            Spacer(minLength: 0)
            HelpButton(title: "快捷键", message: "↑ ↓ 选择会话\n↵ \(keyboardAction)\nEsc 收起", symbol: "keyboard")
                .foregroundStyle(muted)
        }
        .foregroundStyle(Color(red: 0.92, green: 0.94, blue: 0.97))
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func filterButton(_ title: String, count: Int, pending: Bool) -> some View {
        Button { withAnimation(motion) { model.pendingOnly = pending } } label: {
            HStack(spacing: 6) {
                Text(title)
                Text("\(count)").monospacedDigit()
                    .foregroundStyle(model.pendingOnly == pending ? Color.white.opacity(0.8) : muted)
                    .contentTransition(.numericText())
            }
            .font(.system(size: 11, weight: model.pendingOnly == pending ? .semibold : .regular))
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background {
                if model.pendingOnly == pending {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.white.opacity(0.10))
                        .matchedGeometryEffect(id: "filter", in: filterSelection)
                }
            }
        }
        .buttonStyle(IslandButtonStyle())
        .accessibilityLabel("\(title)，\(count) 个会话")
        .accessibilityAddTraits(model.pendingOnly == pending ? .isSelected : [])
    }

    private func sessionRow(_ session: SignalSession) -> some View {
        let selected = model.selectedID == session.id
        let appearance = PhaseAppearance(session.phase, seen: session.seen)
        let source = SourceAppearance(session.source)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                MascotView(phase: session.phase, size: 32, motionActive: model.expanded)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.94, green: 0.95, blue: 0.98))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(session.displayTitle)
                    HStack(spacing: 6) {
                        Label(appearance.title, systemImage: appearance.symbol)
                            .labelStyle(.iconOnly)
                            .foregroundStyle(appearance.color)
                            .help(appearance.title)
                            .accessibilityLabel(appearance.title)
                            .fixedSize()
                        Text(session.project).lineLimit(1).truncationMode(.middle)
                        Text("·")
                        Label(source.title, systemImage: source.symbol).fixedSize()
                        Spacer(minLength: 0)
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(elapsed(session.updatedAt, now: context.date))
                        }
                        .fixedSize()
                    }
                    .font(.system(size: 10.5)).foregroundStyle(muted)
                }
                Button { withAnimation(motion) { model.dismissReminder(session.id) } } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(muted)
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.06), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(IslandButtonStyle())
                .help("关闭这条提醒；有新状态时再次显示")
                .accessibilityLabel("关闭提醒：\(session.displayTitle)")
            }
            if selected {
                selectedActions(session)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: -4)))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(selected ? Color(red: 0.095, green: 0.12, blue: 0.16) : Color.white.opacity(hoveredID == session.id ? 0.07 : 0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(selected ? Color(red: 0.43, green: 0.65, blue: 0.94).opacity(0.34) : Color.white.opacity(hoveredID == session.id ? 0.13 : 0.055), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onTapGesture { withAnimation(motion) { model.select(session.id) } }
        .onHover { hoveredID = $0 ? session.id : nil }
        .animation(motion, value: hoveredID == session.id)
        .contextMenu {
            Button(model.navigationTitle(for: session)) { model.openSource(session, feedbackAnchor: .row) }
                .disabled(model.isNavigating)
            Button("复制会话标识") { model.copySessionID(session, feedbackAnchor: .row) }
            if session.source == .cli, SessionNavigator.resumeCommand(for: session) != nil {
                Button("复制恢复命令") { model.copyResumeCommand(session, feedbackAnchor: .row) }
            }
            if session.unread { Button("标记已查看") { model.markSeen(session.id) } }
            Divider()
            Button("关闭提醒") { model.dismissReminder(session.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(session.displayTitle)，\(session.project)，\(appearance.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "展开会话") { model.select(session.id) }
        .accessibilityAction(named: "打开会话") { model.openSource(session) }
        .accessibilityAction(named: "关闭提醒") { model.dismissReminder(session.id) }
        .overlay(alignment: .bottomTrailing) {
            feedbackBubble(for: session, anchor: .row)
                .padding(.trailing, 12)
                .padding(.bottom, 8)
        }
        .zIndex(model.actionFeedback?.sessionID == session.id ? 1 : 0)
    }

    private func selectedActions(_ session: SignalSession) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
            HStack(spacing: 4) {
                Text(String(session.sessionId.prefix(8)))
                    .font(.system(size: 10, design: .monospaced))
                Button { model.copyResumeCommand(session) } label: {
                    Image(systemName: "doc.on.doc").frame(width: 24, height: 22)
                }
                .buttonStyle(IslandButtonStyle())
                .help("复制恢复命令")
                .accessibilityLabel("复制恢复命令")
                .overlay(alignment: .top) {
                    feedbackBubble(for: session, anchor: .copyResume).alignmentGuide(.top) { $0[.bottom] + 6 }
                }
                Spacer(minLength: 0)
                if session.unread {
                    Button("标记已查看") { withAnimation(motion) { model.markSeen(session.id) } }
                        .buttonStyle(IslandButtonStyle())
                        .font(.system(size: 11))
                } else if session.seen {
                    Label("已查看", systemImage: "checkmark").font(.system(size: 11))
                }
                Button { model.openSource(session) } label: {
                    HStack(spacing: 6) {
                        Text(model.navigationTitle(for: session))
                        Image(systemName: SessionNavigator.plan(for: session).actionSymbol)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 0.06, green: 0.10, blue: 0.16))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Color(red: 0.72, green: 0.84, blue: 1), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(IslandButtonStyle())
                .padding(.leading, 8)
                .disabled(model.isNavigating)
                .help(model.navigationDetail(for: session))
                .accessibilityHint(model.navigationDetail(for: session))
                .overlay(alignment: .top) {
                    feedbackBubble(for: session, anchor: .primary).alignmentGuide(.top) { $0[.bottom] + 6 }
                }
            }
        }
        .foregroundStyle(muted)
    }

    private func feedbackBubble(for session: SignalSession, anchor: ActionFeedback.Anchor) -> some View {
        Group {
            if let feedback = model.actionFeedback, feedback.sessionID == session.id, feedback.anchor == anchor {
                Label(feedback.message, systemImage: feedback.isFailure ? "exclamationmark.circle" : "checkmark")
                    .font(.system(size: 11, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: feedback.isFailure ? 240 : nil)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(red: 0.16, green: 0.19, blue: 0.23), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
                    .fixedSize()
                    .id(feedback.id)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.actionFeedback?.id)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
            HStack(spacing: 5) {
                Circle().fill(model.activeSessions.contains(where: { $0.phase == .running }) ? Color(red: 0.48, green: 0.73, blue: 0.66) : muted).frame(width: 4, height: 4)
                Text("\(model.runningCount) 运行中")
                Text("·  \(model.unreadCount) 待查看")
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .monospacedDigit()
            if let notice = model.statusNotice {
                HStack(alignment: .top, spacing: 4) {
                    Text(notice.message)
                        .font(.system(size: 10.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                    if notice.details != nil || notice.directory != nil {
                        StatusDetailsButton(notice: notice)
                    }
                }
            }
        }
        .foregroundStyle(muted)
        .padding(.horizontal, 18)
        .padding(.top, 7)
        .padding(.bottom, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            MascotView(phase: .completed, size: 48, motionActive: model.expanded)
            Text(model.sessions.isEmpty ? "暂无会话" : (model.pendingOnly ? "暂无待处理提醒" : "暂无会话提醒"))
                .font(.system(size: 13, weight: .medium))
            if model.sessions.isEmpty {
                ConnectionHelpButton(dataDirectory: model.dataDirectory)
            } else if model.pendingOnly {
                Button("查看全部") { withAnimation(motion) { model.pendingOnly = false } }
                    .buttonStyle(.bordered)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var collapsedContent: some View {
        VStack(spacing: 0) {
            compactContent
                .frame(width: layout.compactSize.width, height: layout.compactSize.height)
            if let notice = model.islandNotice {
                noticeContent(notice)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: -5)))
            }
        }
    }

    private func noticeContent(_ notice: IslandNotice) -> some View {
        let session = notice.primary
        let appearance = PhaseAppearance(session.phase)
        return HStack(spacing: 8) {
            Button { model.openIslandNotice() } label: {
                HStack(spacing: 12) {
                    MascotView(phase: session.phase, size: 36, motionActive: !model.expanded)
                        .id(session.id + session.turnId + (session.requestId ?? "") + session.phase.rawValue)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Image(systemName: session.phase == .completed ? "checkmark.circle" : appearance.symbol)
                                .symbolEffect(.bounce, options: .nonRepeating, value: notice.id)
                                .symbolEffectsRemoved(reduceMotion)
                            Text(appearance.title).fontWeight(.semibold)
                            if notice.sessions.count > 1 {
                                Text("· \(notice.sessions.count) 条提醒").foregroundStyle(muted)
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(appearance.color)
                        Text(session.title.map { "\(session.project) · \($0)" } ?? session.project)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.8))
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(IslandButtonStyle())
            .help("查看会话：\(session.displayTitle)")
            .accessibilityLabel("\(appearance.title)，\(session.displayTitle)，\(notice.sessions.count) 条提醒，查看会话")
            Button { model.dismissIslandNotice() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                    .frame(width: 24, height: 28)
            }
            .buttonStyle(IslandButtonStyle())
            .foregroundStyle(muted)
            .help("收起提示")
            .accessibilityLabel("收起提示")
        }
        .padding(.horizontal, 20)
        .frame(height: 78)
    }

    private var compactContent: some View {
        Button { model.setExpanded(true) } label: {
            HStack(spacing: 0) {
                HStack(spacing: 5) {
                    MascotView(phase: model.aggregatePhase,
                               size: 22, motionActive: !model.expanded)
                    Text("\(model.runningCount)")
                        .foregroundStyle(model.runningCount > 0 ? PhaseAppearance(.running).color : muted)
                        .contentTransition(.numericText())
                }
                .frame(maxWidth: .infinity)
                if layout.notchWidth > 0 { Color.clear.frame(width: layout.notchWidth) }
                HStack(spacing: 5) {
                    Image(systemName: model.pendingCount > 0 ? "exclamationmark.circle.fill" : "tray")
                    Text("\(model.pendingCount > 0 ? model.pendingCount : model.unreadCount)").contentTransition(.numericText())
                    Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(muted)
                }
                .foregroundStyle(model.pendingCount > 0 ? Color.orange : muted)
                .frame(maxWidth: .infinity)
            }
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, layout.topInset > 0 ? 14 : 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(IslandButtonStyle())
        .help("\(model.runningCount) 个运行中 · \(model.pendingCount) 个待处理 · \(model.unreadCount) 个未查看，点击展开")
        .accessibilityLabel("展开 Codex Signal，\(model.runningCount) 个运行中，\(model.pendingCount) 个待处理，\(model.unreadCount) 个未查看")
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置").font(.headline)
            Picker("首选终端", selection: $model.preferredTerminal) {
                ForEach(TerminalPreference.allCases) { terminal in
                    Text(terminal.title).tag(terminal)
                }
            }
            .help("有原标签页时直接打开；否则优先查找所选终端，未找到再查找其他终端。")
            Divider()
            HStack {
                Toggle("中文语音提醒", isOn: $model.speechEnabled)
                HelpButton(title: "语音提醒说明", message: "仅关闭语音；灵动岛仍可提示。重新开启不补播。")
            }
            HStack {
                Toggle("灵动岛提示", isOn: $model.islandAlertsEnabled)
                HelpButton(title: "灵动岛提示说明", message: "新提醒短暂展开，6 秒后收起。待处理标记会保留；关闭提示不影响状态动画。")
            }
            HStack {
                Toggle("勿扰时段", isOn: $model.quietHoursEnabled)
                HelpButton(title: "静音说明", message: "锁屏及勿扰时段仅静音。")
            }
            HStack {
                Picker("从", selection: $model.quietStart) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
                Picker("至", selection: $model.quietEnd) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
            }
            .disabled(!model.quietHoursEnabled)
            Divider()
            HStack {
                Picker("自动清理", selection: $model.retentionDays) {
                    ForEach(SignalSettings.retentionOptions, id: \.self) { days in
                        Text("\(days) 天").tag(days)
                    }
                }
                HelpButton(title: "自动清理说明", message: "按最后一次状态更新计算，清理所有到期提醒。有新状态时会再次显示。")
            }
            HStack {
                Button("预览提醒") { model.previewIslandNotice() }
                Spacer()
                ConnectionHelpButton(dataDirectory: model.dataDirectory)
            }
        }
        .padding(22)
        .frame(width: 330)
    }

    private func elapsed(_ timestamp: Double, now: Date) -> String {
        let minutes = max(0, Int((now.timeIntervalSince1970 - timestamp) / 60))
        if minutes == 0 { return "刚刚" }
        if minutes < 60 { return "\(minutes) 分钟前" }
        if minutes < 1440 { return "\(minutes / 60) 小时前" }
        return "\(minutes / 1440) 天前"
    }
}

private struct HelpButton: View {
    let title: String
    let message: String
    var symbol = "info.circle"
    @State private var visible = false

    var body: some View {
        Button { visible.toggle() } label: {
            Image(systemName: symbol).frame(width: 24, height: 24)
        }
        .buttonStyle(IslandButtonStyle())
        .help(title)
        .accessibilityLabel(title)
        .popover(isPresented: $visible) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 240, alignment: .leading)
        }
    }
}

private struct StatusDetailsButton: View {
    let notice: StatusNotice
    @State private var visible = false

    var body: some View {
        Button { visible.toggle() } label: {
            Image(systemName: "info.circle").frame(width: 22, height: 22)
        }
        .buttonStyle(IslandButtonStyle())
        .help("错误详情")
        .accessibilityLabel("错误详情")
        .popover(isPresented: $visible) {
            VStack(alignment: .leading, spacing: 12) {
                Text(notice.message).font(.headline)
                if let details = notice.details {
                    Text(details).font(.system(size: 12)).textSelection(.enabled)
                }
                if let directory = notice.directory {
                    Text(directory.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Button("打开文件夹") { NSWorkspace.shared.open(directory) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(18)
            .frame(width: 340, alignment: .leading)
        }
        .onChange(of: notice) { _, _ in visible = false }
    }
}

private struct ConnectionHelpButton: View {
    let dataDirectory: URL
    @State private var visible = false

    private var command: String {
        "python3 scripts/signal_bridge.py --print-hooks --source auto --data-dir \(SessionNavigator.shellQuote(dataDirectory.path))"
    }

    var body: some View {
        Button("接入说明") { visible.toggle() }
            .buttonStyle(.bordered)
            .popover(isPresented: $visible) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("接入 Codex").font(.headline)
                    Text("1. 在 Codex Signal 项目目录运行：")
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    Text("2. 在 Codex 的 Hooks 设置中审阅并合并生成的配置，保留已有条目。")
                    Text("3. 开启新会话。")
                }
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .padding(20)
                .frame(width: 360, alignment: .leading)
            }
    }
}

private struct SourceAppearance {
    let title: String
    let symbol: String

    init(_ source: SessionSource) {
        switch source {
        case .cli: title = "CLI"; symbol = "terminal"
        case .desktop: title = "桌面版"; symbol = "desktopcomputer"
        case .unknown: title = "Codex"; symbol = "desktopcomputer"
        }
    }
}

/// A small shoulder joins the screen edge without the square corners of a
/// rounded rectangle whose top radius is zero. Floating displays round all sides.
struct IslandOutline: Shape {
    var attached: Bool
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard attached else { return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect) }
        let ear = min(10, rect.width / 8, rect.height / 3)
        let bottom = min(radius, max(0, (rect.width - ear * 2) / 2), max(0, rect.height - ear))
        let left = rect.minX + ear, right = rect.maxX - ear
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.minY + ear), control: CGPoint(x: right, y: rect.minY))
        path.addLine(to: CGPoint(x: right, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: right - bottom, y: rect.maxY), control: CGPoint(x: right, y: rect.maxY))
        path.addLine(to: CGPoint(x: left + bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.maxY - bottom), control: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: left, y: rect.minY + ear))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY), control: CGPoint(x: left, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct IslandButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}
