// NetVplayerApp/Views/LiveStreamView.swift
// 直播间视图

import AppKit
import SwiftUI
import Models
import PlayerEngine

struct LiveStreamView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var playerState: PlayerState
    @ObservedObject var windowContext: PlayerWindowContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let onExit: () -> Void

    @State private var isGuideVisible = false
    @State private var isHUDVisible = true
    @State private var isPointerInsidePlayer = false
    @State private var guideFocusedChannel: Channel?
    @State private var liveSearchText = ""
    @State private var hudHideTask: Task<Void, Never>?
    @State private var channelNumberInput = ""
    @State private var isChannelNumberEntryVisible = false
    @State private var channelNumberSubmitTask: Task<Void, Never>?
    @State private var liveResumeTask: Task<Void, Never>?
    @State private var hiddenGroupPassword = ""
    @State private var isHiddenGroupUnlockPresented = false
    @State private var unlockedHiddenGroupNames = Set<String>()
    @State private var lastNonZeroVolume: Float = 1
    @FocusState private var isChannelNumberFieldFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let usesCompactControls = CompactPlayerLayoutPolicy.isCompact(
                contentSize: windowContext.contentSize == .zero
                    ? proxy.size
                    : windowContext.contentSize
            )

            ZStack {
                videoLayer

                videoInteractionLayer
                    .zIndex(1)

                if usesCompactControls {
                    CompactPlayerStatusOverlay(
                        isLoading: appState.isLoadingLive || isPlaybackActivityActive,
                        errorMessage: appState.liveError
                    )
                    .zIndex(2)

                    CompactPlayerControls(
                        kind: .live,
                        isPlaying: playerState.isPlaying,
                        isPlaybackEnabled: appState.selectedChannel != nil,
                        position: playerState.position,
                        duration: playerState.duration,
                        isAlwaysOnTop: windowContext.isAlwaysOnTop,
                        isVisible: isPointerInsidePlayer,
                        onTogglePlayback: togglePlayPause,
                        onSeek: { target in
                            MPVPlayerEngine.live.seek(to: Int64(target * 1_000))
                        },
                        onToggleAlwaysOnTop: {
                            _ = windowContext.toggleAlwaysOnTop()
                        },
                        onRestoreWindow: {
                            _ = windowContext.restoreRegularWindow()
                        },
                        onClose: onExit
                    )
                    .zIndex(3)
                } else {
                    if appState.isLoadingLive {
                        loadingState
                            .zIndex(8)
                    }

                    PlayerPlaybackActivityView(
                        phase: playbackActivityPhase,
                        progress: playerState.cacheBufferingProgress,
                        speedBytesPerSecond: playerState.cacheSpeedBytesPerSecond,
                        bufferedAheadDuration: playerState.bufferedAheadDuration
                    )
                    .zIndex(2)

                    if let error = appState.liveError {
                        liveErrorState(error)
                            .zIndex(9)
                    }

                    if isHUDVisible || isGuideVisible || appState.selectedChannel == nil {
                        topChrome
                            .transition(.opacity)
                            .zIndex(6)
                    }

                    if isHUDVisible, !isGuideVisible, appState.selectedChannel != nil {
                        channelIdentitySummary
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .zIndex(3)
                    }

                    if isGuideVisible {
                        tvGuideLayer(size: proxy.size)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                            .zIndex(4)
                    }

                    if !isGuideVisible, isHUDVisible, appState.selectedChannel != nil {
                        bottomLiveHUD
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .zIndex(5)
                    }

                    if isChannelNumberEntryVisible, !isGuideVisible {
                        channelNumberControl
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .zIndex(7)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(Color.black)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isPointerInsidePlayer = true
                    showHUDTemporarily()
                case .ended:
                    isPointerInsidePlayer = false
                    hudHideTask?.cancel()
                    restorePlayerCursor()
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isGuideVisible)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isHUDVisible)
            .onChange(of: usesCompactControls) { _, isCompact in
                handleCompactModeChange(isCompact)
            }
        }
        .ignoresSafeArea()
        .background {
            PlayerShortcutMonitor(
                isPlaybackControlEnabled: appState.selectedChannel != nil
                    && !isGuideVisible
                    && !isChannelNumberEntryVisible,
                isScrollVolumeEnabled: appState.selectedChannel != nil
                    && !isGuideVisible
                    && !isChannelNumberEntryVisible
            ) { command, window in
                handleKeyboardShortcut(command, window: window)
            }
            .frame(width: 0, height: 0)
        }
        .onAppear {
            prepareInitialSelection()
            focusGuideChannel(appState.selectedChannel)
            lastNonZeroVolume = max(0.01, playerState.volume)
            showHUDTemporarily()
        }
        .onDisappear {
            hudHideTask?.cancel()
            channelNumberSubmitTask?.cancel()
            liveResumeTask?.cancel()
            isPointerInsidePlayer = false
            isChannelNumberEntryVisible = false
            restorePlayerCursor()
        }
        .onChange(of: appState.selectedChannel.map(channelIdentity) ?? "") { _, _ in
            focusGuideChannel(appState.selectedChannel)
            showHUDTemporarily()
        }
        .onChange(of: liveSearchText) { _, _ in
            if isSearching {
                focusGuideChannel(searchHits.first?.channel)
            } else {
                focusGuideChannel(appState.selectedChannel ?? displayedChannels.first)
            }
        }
        .onChange(of: isChannelNumberFieldFocused) { _, focused in
            if !focused, channelNumberInput.isEmpty {
                isChannelNumberEntryVisible = false
            }
        }
        .onChange(of: isChannelNumberEntryVisible) { _, isVisible in
            if isVisible {
                hudHideTask?.cancel()
                restorePlayerCursor()
            } else {
                showHUDTemporarily()
            }
        }
        .onChange(of: playerState.isPlaying) { _, isPlaying in
            if isPlaying {
                showHUDTemporarily()
            } else {
                hudHideTask?.cancel()
                restorePlayerCursor()
                isHUDVisible = true
            }
        }
        .onChange(of: isPlaybackActivityActive) { _, isActive in
            if isActive {
                hudHideTask?.cancel()
                restorePlayerCursor()
                isHUDVisible = true
            } else {
                showHUDTemporarily()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                showHUDTemporarily()
            } else {
                if !windowContext.isCompact {
                    isPointerInsidePlayer = false
                }
                hudHideTask?.cancel()
                restorePlayerCursor()
            }
        }
        .preferredColorScheme(.dark)
        .alert("解锁隐藏分组", isPresented: $isHiddenGroupUnlockPresented) {
            SecureField("密码", text: $hiddenGroupPassword)
            Button("解锁") {
                unlockHiddenGroup()
            }
            Button("取消", role: .cancel) {
                hiddenGroupPassword = ""
            }
        } message: {
            Text("输入分组密码后会在本次会话显示对应频道。")
        }
    }

    private var videoLayer: some View {
        ZStack {
            Color.black

            if appState.selectedChannel != nil {
                MPVVideoView(
                    engine: MPVPlayerEngine.live,
                    surface: .live,
                    attachmentRevision: appState.livePlayerOpenRequestSerial
                )
            } else {
                emptyLiveState
            }
        }
        .ignoresSafeArea()
    }

    private var videoInteractionLayer: some View {
        Color.black.opacity(0.001)
            .contentShape(Rectangle())
        .gesture(
            TapGesture(count: PlayerPointerShortcutPolicy.fullScreenClickCount)
                .exclusively(
                    before: TapGesture(count: PlayerPointerShortcutPolicy.singleClickCount)
                )
                .onEnded { result in
                    switch result {
                    case .first:
                        handleVideoPointerShortcut(
                            clickCount: PlayerPointerShortcutPolicy.fullScreenClickCount
                        )
                    case .second:
                        handleVideoPointerShortcut(
                            clickCount: PlayerPointerShortcutPolicy.singleClickCount
                        )
                    }
                },
            including: LivePlayerInteractionPolicy.videoGestureMask(
                hasSelectedChannel: appState.selectedChannel != nil,
                hasBlockingUI: hasBlockingPlayerUI
            )
        )
        .ignoresSafeArea()
    }

    private func handleCompactModeChange(_ isCompact: Bool) {
        if isCompact {
            hudHideTask?.cancel()
            isGuideVisible = false
            isChannelNumberEntryVisible = false
            isChannelNumberFieldFocused = false
            restorePlayerCursor()
        } else {
            showHUDTemporarily()
        }
    }

    private var emptyLiveState: some View {
        liveStateCard(systemImage: "tv", tint: LiveUIPalette.foreground) {
            Text(appState.channelGroups.isEmpty ? "电视直播" : "选择频道开始直播")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(LiveUIPalette.foreground)
            Text(appState.channelGroups.isEmpty ? "暂无直播数据" : "频道列表已准备好，打开频道指南后即可按分组浏览或直接搜索。")
                .font(.system(size: 13))
                .foregroundStyle(LiveUIPalette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            if appState.channelGroups.isEmpty {
                Button {
                    reloadLiveContent()
                } label: {
                    Label("重新加载直播源", systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(height: 42)
                        .padding(.horizontal, 12)
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(LiveUIPalette.accent.opacity(0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(LiveUIPalette.accent.opacity(0.58), lineWidth: 1)
                }
            } else {
                Button {
                    showGuide()
                } label: {
                    Label("打开频道指南", systemImage: "list.bullet.rectangle")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(height: 42)
                        .padding(.horizontal, 12)
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(LiveUIPalette.accent.opacity(0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(LiveUIPalette.accent.opacity(0.58), lineWidth: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LiveUIPalette.background)
    }

    private var topChrome: some View {
        VStack {
            ZStack {
                VStack(spacing: 2) {
                    Text(appState.selectedChannel?.name ?? "电视直播")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(LiveUIPalette.foreground)
                        .lineLimit(1)
                    Text(topSubtitle)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LiveUIPalette.muted)
                        .lineLimit(1)
                }
                .padding(.horizontal, 220)

                HStack {
                    chromeIconButton(systemImage: "chevron.left", help: "停止直播并返回") {
                        exitLive()
                    }
                    Spacer()
                }
                .padding(.leading, 118)
                .padding(.trailing, 18)
            }
            .frame(height: LivePlayerInteractionPolicy.topChromeHeight)
            .background {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .opacity(PlayerHUDVisualPolicy.topBarMaterialOpacity)
                    Rectangle()
                        .fill(LiveUIPalette.background.opacity(PlayerHUDVisualPolicy.topBarBackgroundOpacity))
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(PlayerHUDVisualPolicy.topBarBorderOpacity))
                    .frame(height: 1)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomLiveHUD: some View {
        VStack {
            Spacer()

            VStack(spacing: 0) {
                HStack(spacing: 18) {
                    HStack(spacing: 8) {
                        chromeTextButton(title: "频道指南", systemImage: "list.bullet.rectangle", help: "打开频道指南") {
                            showGuide()
                        }
                        chromeIconButton(
                            systemImage: playerState.isPlaying ? "pause.fill" : "play.fill",
                            help: playerState.isPlaying ? "暂停" : "播放",
                            isPrimary: true
                        ) {
                            togglePlayPause()
                            showHUDTemporarily()
                        }
                        chromeIconButton(systemImage: "chevron.up", help: "上一个频道") {
                            changeChannel(offset: -1)
                        }
                        chromeIconButton(systemImage: "chevron.down", help: "下一个频道") {
                            changeChannel(offset: 1)
                        }
                    }

                    liveInfoCapsule
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        Button {
                            toggleMute()
                            showHUDTemporarily()
                        } label: {
                            Image(systemName: playerState.volume > 0 ? "speaker.wave.2" : "speaker.slash")
                                .font(.system(size: 15))
                                .foregroundStyle(LiveUIPalette.foreground)
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(playerState.volume > 0 ? "静音" : "恢复音量")

                        Slider(value: volumeBinding, in: 0...1)
                            .frame(width: 88)
                            .tint(LiveUIPalette.lavender)

                        if let channel = appState.selectedChannel, channel.urls.count > 1 {
                            Picker("线路", selection: Binding(
                                get: { appState.currentChannelUrlIndex },
                                set: { index in
                                    Task {
                                        showHUDTemporarily()
                                        await appState.changeChannelUrlIndex(index)
                                    }
                                }
                            )) {
                                ForEach(0..<channel.urls.count, id: \.self) { index in
                                    Text("线路 \(index + 1)").tag(index)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .tint(LiveUIPalette.lavender)
                            .frame(width: 108, height: 44)
                        }

                        chromeIconButton(systemImage: "stop.fill", help: "停止直播") {
                            stopLive()
                        }
                        .disabled(appState.selectedChannel == nil)

                        chromeIconButton(
                            systemImage: windowContext.isFullScreen
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right",
                            help: windowContext.isFullScreen ? "退出全屏" : "进入全屏"
                        ) {
                            toggleFullScreen()
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(liveBottomGlassPanel(cornerRadius: 16))
            .padding(.horizontal, 22)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var channelNumberControl: some View {
        VStack(spacing: 2) {
            Text("频道号")
                .font(.system(size: 10))
                .foregroundStyle(LiveUIPalette.muted)
            TextField("频道号", text: Binding(
                get: { channelNumberInput },
                set: { value in
                    channelNumberInput = String(value.filter(\.isNumber).suffix(3))
                    scheduleChannelNumberSubmit()
                }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 20, weight: .semibold, design: .monospaced))
            .multilineTextAlignment(.center)
            .frame(width: 72)
            .focused($isChannelNumberFieldFocused)
            .onSubmit {
                playChannelNumber()
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(liveGlassPanel(cornerRadius: 8))
        .padding(.trailing, 28)
        .padding(.bottom, 158)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private var liveInfoCapsule: some View {
        HStack(spacing: 12) {
            Button {
                isChannelNumberEntryVisible = true
                isChannelNumberFieldFocused = true
            } label: {
                Text(appState.selectedChannel?.number.isEmpty == false ? appState.selectedChannel?.number ?? "" : "--")
                    .font(.system(size: 22, weight: .medium, design: .monospaced))
                    .foregroundStyle(LiveUIPalette.foreground)
                    .frame(minWidth: 42)
            }
            .buttonStyle(.plain)
            .help("输入频道号")

            VStack(alignment: .leading, spacing: 3) {
                Text(appState.selectedChannel?.name ?? "未选择频道")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LiveUIPalette.foreground)
                    .lineLimit(1)
                Text(bottomSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(LiveUIPalette.muted)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: 180, alignment: .leading)
    }

    private var channelIdentitySummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(LiveUIPalette.foreground)
                    .frame(width: 7, height: 7)
                    .shadow(color: LiveUIPalette.foreground.opacity(0.42), radius: 7)
                Text("正在直播")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LiveUIPalette.foreground.opacity(0.88))
            }

            Text(appState.selectedChannel?.name ?? "电视直播")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(LiveUIPalette.foreground)
                .lineLimit(1)
                .shadow(color: Color.black.opacity(0.45), radius: 11, y: 2)

            Text(heroSubtitle)
                .font(.system(size: 14))
                .foregroundStyle(LiveUIPalette.foreground.opacity(0.74))
                .lineLimit(1)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.leading, 28)
        .padding(.bottom, 158)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(false)
    }

    private func tvGuideLayer(size: CGSize) -> some View {
        let guideWidth = LiveGuideLayoutPolicy.drawerWidth(availableWidth: size.width)
        let groupWidth = LiveGuideLayoutPolicy.groupWidth(drawerWidth: guideWidth)
        let channelWidth = LiveGuideLayoutPolicy.channelWidth(
            drawerWidth: guideWidth,
            groupWidth: groupWidth
        )

        return ZStack(alignment: .topLeading) {
            Button {
                hideGuide()
            } label: {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭频道指南")

            VStack(spacing: LiveGuideLayoutPolicy.columnSpacing) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("频道指南")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(LiveUIPalette.foreground.opacity(0.94))
                        Text("\(visibleGroups.count) 个分类 · \(displayedChannels.count) 个频道")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(LiveUIPalette.muted)
                    }

                    Spacer(minLength: 12)
                    guideCloseButton
                }
                .frame(height: PlayerHUDVisualPolicy.drawerCloseButtonSize)

                HStack(alignment: .top, spacing: LiveGuideLayoutPolicy.columnSpacing) {
                    guideGroupColumn(width: groupWidth)
                    guideChannelColumn(width: channelWidth)
                }
            }
            .padding(LiveGuideLayoutPolicy.contentPadding)
            .frame(width: guideWidth)
            .frame(height: max(420, size.height - 94))
            .background(liveDrawerGlassPanel(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.leading, 20)
            .padding(.top, 72)
            .padding(.bottom, 22)
        }
        .frame(width: size.width, height: size.height)
        .onAppear {
            ensureGuideFocus()
        }
    }

    private func guideGroupColumn(width: CGFloat) -> some View {
        guidePanel(
            title: isSearching ? "搜索" : "频道分类",
            detail: isSearching ? nil : "\(visibleGroups.count) 组",
            width: width
        ) {
            if isSearching {
                VStack(alignment: .leading, spacing: 10) {
                    Label("搜索结果", systemImage: "magnifyingglass")
                        .font(.headline)
                    Text("\(searchHits.count) 个频道")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("清空搜索后恢复分组浏览")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ThemedScrollView(theme: LiveGuideLayoutPolicy.scrollbarTheme) {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        if hasLockedHiddenGroups {
                            Button {
                                hiddenGroupPassword = ""
                                isHiddenGroupUnlockPresented = true
                            } label: {
                                Label("解锁隐藏分组", systemImage: "lock")
                                    .font(.callout.weight(.semibold))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 9)
                                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }

                        ForEach(visibleGroups) { group in
                            Button {
                                appState.selectedGroup = group
                                focusGuideChannel(group.channels.first)
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: isSelected(group) ? "tv.fill" : "tv")
                                        .foregroundStyle(isSelected(group) ? AnyShapeStyle(accentGradient) : AnyShapeStyle(inactiveIcon))
                                    Text(group.name)
                                        .fontWeight(isSelected(group) ? .semibold : .regular)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.88)
                                        .layoutPriority(1)
                                    Spacer()
                                    Text("\(group.channels.count)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(LiveUIPalette.muted)
                                }
                                .padding(.horizontal, 11)
                                .frame(minHeight: 46)
                                .background(rowBackground(isSelected(group)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(alignment: .leading) {
                                    if isSelected(group) {
                                        Capsule()
                                            .fill(LiveUIPalette.lavender)
                                            .frame(width: 3)
                                            .padding(.vertical, 7)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func guideChannelColumn(width: CGFloat) -> some View {
        guidePanel(
            title: "频道列表",
            detail: "\(isSearching ? searchHits.count : displayedChannels.count) 个频道",
            width: width
        ) {
            VStack(spacing: 10) {
                searchField

                ThemedScrollView(theme: LiveGuideLayoutPolicy.scrollbarTheme) {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        if isSearching, searchHits.isEmpty {
                            ContentUnavailableView(
                                "没有匹配频道",
                                systemImage: "magnifyingglass",
                                description: Text("换个关键词试试")
                            )
                            .frame(maxWidth: .infinity, minHeight: 220)
                        } else if isSearching {
                            ForEach(searchHits) { hit in
                                channelRow(channel: hit.channel, group: hit.group)
                            }
                        } else {
                            ForEach(Array(displayedChannels.enumerated()), id: \.offset) { _, channel in
                                channelRow(channel: channel, group: appState.selectedGroup)
                            }
                        }
                    }
                }
            }
        }
    }

    private func guidePanel<Content: View>(
        title: String,
        detail: String? = nil,
        width: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LiveUIPalette.foreground.opacity(0.92))

                Spacer(minLength: 4)

                if let detail {
                    Text(detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(LiveUIPalette.muted)
                }

            }
            .frame(minHeight: 36)

            content()
        }
        .padding(14)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索频道", text: $liveSearchText)
                .textFieldStyle(.plain)
            if !liveSearchText.isEmpty {
                Button {
                    liveSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清空搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(Color.white.opacity(PlayerHUDVisualPolicy.topControlBackgroundOpacity), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(PlayerHUDVisualPolicy.topControlBorderOpacity), lineWidth: 1)
        }
    }

    private func channelRow(channel: Channel, group: ChannelGroup?) -> some View {
        let sourceGroup = sourceGroup(for: channel, fallback: group)
        let selected = isGuideFocused(channel) || isSelected(channel)
        let isKept = appState.isLiveChannelKept(channel, group: sourceGroup)

        return HStack(spacing: 9) {
            Button {
                selectChannel(channel, group: sourceGroup ?? group)
            } label: {
                HStack(spacing: 11) {
                    channelLogo(channel)
                        .frame(width: 38, height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(channel.name)
                                .font(.system(size: 13, weight: isSelected(channel) ? .semibold : .regular))
                                .fontWeight(isSelected(channel) ? .semibold : .regular)
                                .lineLimit(1)
                        }

                        Text(isSelected(channel) && playerState.isPlaying
                             ? "正在播放"
                             : channelSecondaryText(channel: channel, group: group))
                            .font(.system(size: 11))
                            .foregroundStyle(LiveUIPalette.muted)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text(channel.number.isEmpty ? "" : channel.number)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LiveUIPalette.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                appState.toggleLiveKeep(channel: channel, group: sourceGroup)
            } label: {
                Image(systemName: isKept ? "star.fill" : "star")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isKept ? LiveUIPalette.warning : LiveUIPalette.muted)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .help(isKept ? "取消直播收藏" : "收藏直播频道")
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 46)
        .background(rowBackground(selected), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected(channel) ? LiveUIPalette.lavender.opacity(0.60) : Color.white.opacity(0.12), lineWidth: 1)
        }
        .overlay(alignment: .leading) {
            if selected {
                Capsule()
                    .fill(LiveUIPalette.lavender)
                    .frame(width: 3)
                    .padding(.vertical, 7)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                focusGuideChannel(channel)
            }
        }
    }

    private func liveErrorState(_ error: String) -> some View {
        liveStateOverlay {
            liveStateCard(systemImage: "exclamationmark.triangle", tint: LiveUIPalette.danger) {
                Text("当前线路无法播放")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(LiveUIPalette.foreground)

                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(LiveUIPalette.muted)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)

                HStack(spacing: 8) {
                    Button("重试当前线路") {
                        retryCurrentChannel()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(height: 42)
                    .padding(.horizontal, 13)
                    .background(LiveUIPalette.accent.opacity(0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(LiveUIPalette.accent.opacity(0.58), lineWidth: 1)
                    }

                    chromeTextButton(title: "选择其他频道", systemImage: "list.bullet.rectangle", help: "打开频道指南") {
                        appState.liveError = nil
                        showGuide()
                    }
                }
            }
        }
    }

    private var loadingState: some View {
        liveStateOverlay {
            VStack(spacing: 15) {
                ZStack {
                    Circle()
                        .fill(LiveUIPalette.foreground.opacity(0.07))
                        .frame(width: 52, height: 52)
                    ProgressView()
                        .controlSize(.regular)
                }

                Text("正在连接直播")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(LiveUIPalette.foreground)
                Text("正在检查当前频道线路，请稍候。")
                    .font(.system(size: 13))
                    .foregroundStyle(LiveUIPalette.muted)
            }
            .padding(28)
            .frame(width: 420)
            .background(liveDrawerGlassPanel(cornerRadius: 16))
        }
    }

    private func liveStateOverlay<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.46))
            .padding(.top, 58)
    }

    private func liveStateCard<Content: View>(
        systemImage: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 15) {
            ZStack {
                Circle()
                    .fill(LiveUIPalette.foreground.opacity(0.07))
                    .frame(width: 52, height: 52)
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(tint)
            }

            content()
        }
        .padding(28)
        .frame(width: 420)
        .background(liveDrawerGlassPanel(cornerRadius: 16))
    }

    private func channelLogo(_ channel: Channel) -> some View {
        Group {
            if !channel.logo.isEmpty {
                WebImage(
                    urlString: channel.logo,
                    siteHeader: channel.requestHeaders,
                    showsLoadingIndicator: false,
                    timeout: 3,
                    fallbackSystemImage: "tv",
                    fallbackIconFont: .caption
                )
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.10))
                    .overlay {
                        Image(systemName: "tv")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.62))
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var guideCloseButton: some View {
        Button {
            hideGuide()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LiveUIPalette.foreground.opacity(0.92))
                .frame(
                    width: PlayerHUDVisualPolicy.drawerCloseButtonSize,
                    height: PlayerHUDVisualPolicy.drawerCloseButtonSize
                )
                .background(
                    Color.white.opacity(0.08),
                    in: RoundedRectangle(
                        cornerRadius: PlayerHUDVisualPolicy.drawerCloseButtonCornerRadius,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: PlayerHUDVisualPolicy.drawerCloseButtonCornerRadius,
                        style: .continuous
                    )
                    .stroke(Color.white.opacity(0.13), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help("关闭频道指南")
    }

    private func chromeIconButton(
        systemImage: String,
        help: String,
        isPrimary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(LiveUIPalette.foreground.opacity(0.92))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isPrimary
                ? LiveUIPalette.accent.opacity(PlayerHUDVisualPolicy.primaryAccentBackgroundOpacity)
                : Color.white.opacity(PlayerHUDVisualPolicy.topControlBackgroundOpacity),
            in: RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.topControlCornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.topControlCornerRadius, style: .continuous)
                .stroke(
                    isPrimary
                        ? LiveUIPalette.accent.opacity(PlayerHUDVisualPolicy.primaryAccentBorderOpacity)
                        : Color.white.opacity(PlayerHUDVisualPolicy.topControlBorderOpacity),
                    lineWidth: isPrimary ? 1.6 : 1
                )
        }
        .shadow(
            color: isPrimary
                ? LiveUIPalette.accent.opacity(PlayerHUDVisualPolicy.primaryAccentShadowOpacity)
                : Color.clear,
            radius: isPrimary ? PlayerHUDVisualPolicy.primaryAccentShadowRadius : 0
        )
        .help(help)
    }

    private func chromeTextButton(
        title: String,
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LiveUIPalette.foreground.opacity(0.92))
                .frame(height: 44)
                .padding(.horizontal, 13)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            Color.white.opacity(PlayerHUDVisualPolicy.topControlBackgroundOpacity),
            in: RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.topControlCornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.topControlCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(PlayerHUDVisualPolicy.topControlBorderOpacity), lineWidth: 1)
        }
        .help(help)
    }

    private func liveGlassPanel(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .opacity(PlayerHUDVisualPolicy.glassPanelMaterialOpacity)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(LiveUIPalette.surface.opacity(PlayerHUDVisualPolicy.glassPanelSurfaceOpacity))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                LiveUIPalette.lavender.opacity(0.28),
                                LiveUIPalette.accent.opacity(0.21),
                                Color.white.opacity(0.08),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: LiveUIPalette.accent.opacity(0.12), radius: 18, x: 0, y: 8)
    }

    private func liveDrawerGlassPanel(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .opacity(PlayerHUDVisualPolicy.drawerGlassMaterialOpacity)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(LiveUIPalette.surface.opacity(PlayerHUDVisualPolicy.drawerGlassSurfaceOpacity))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(LiveUIPalette.lavender.opacity(0.25), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.42), radius: 30, x: 0, y: 18)
    }

    private func liveBottomGlassPanel(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .opacity(PlayerHUDVisualPolicy.bottomGlassMaterialOpacity)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(LiveUIPalette.surface.opacity(PlayerHUDVisualPolicy.bottomGlassSurfaceOpacity))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                LiveUIPalette.lavender.opacity(0.25),
                                LiveUIPalette.accent.opacity(0.12),
                                Color.white.opacity(0.06),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(PlayerHUDVisualPolicy.bottomGlassTopHighlightOpacity),
                                LiveUIPalette.lavender.opacity(0.03),
                                Color.clear,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.black.opacity(PlayerHUDVisualPolicy.bottomGlassBottomInsetOpacity), lineWidth: 1)
            }
            .shadow(
                color: .black.opacity(PlayerHUDVisualPolicy.bottomGlassShadowOpacity),
                radius: PlayerHUDVisualPolicy.bottomGlassShadowRadius,
                x: 0,
                y: 18
            )
    }

    private var volumeBinding: Binding<Float> {
        Binding(
            get: { playerState.volume },
            set: { volume in
                setVolume(volume)
                showHUDTemporarily()
            }
        )
    }

    private func prepareInitialSelection() {
        if appState.selectedGroup.map({ isGroupVisible($0) }) != true {
            appState.selectedGroup = visibleGroups.first
        }
        if guideFocusedChannel == nil {
            guideFocusedChannel = appState.selectedChannel ?? appState.selectedGroup?.channels.first
        }
    }

    private func reloadLiveContent() {
        liveResumeTask?.cancel()
        liveResumeTask = Task {
            guard await appState.loadLiveContentAndResumeIfNeeded(), !Task.isCancelled else { return }
            await MainActor.run {
                prepareInitialSelection()
                focusGuideChannel(appState.selectedChannel)
                showHUDTemporarily()
            }
        }
    }

    private func showGuide() {
        hudHideTask?.cancel()
        restorePlayerCursor()
        isHUDVisible = true
        isGuideVisible = true
        ensureGuideFocus()
    }

    private func hideGuide() {
        isGuideVisible = false
        focusGuideChannel(appState.selectedChannel)
        showHUDTemporarily()
    }

    private func handleVideoPointerShortcut(clickCount: Int) {
        guard let action = PlayerPointerShortcutPolicy.action(forClickCount: clickCount) else { return }
        isPointerInsidePlayer = true
        switch action {
        case .togglePlayPause:
            togglePlayPause()
        case .toggleFullScreen:
            toggleFullScreen()
        }
    }

    private func handleKeyboardShortcut(_ command: PlayerShortcutCommand, window: NSWindow) {
        switch command {
        case .togglePlayPause:
            togglePlayPause()
        case .seekBackward:
            seekLivePlayback(by: -PlayerKeyboardShortcutPolicy.seekInterval)
        case .seekForward:
            seekLivePlayback(by: PlayerKeyboardShortcutPolicy.seekInterval)
        case .volumeUp:
            setVolume(playerState.volume + PlayerKeyboardShortcutPolicy.volumeStep)
        case .volumeDown:
            setVolume(playerState.volume - PlayerKeyboardShortcutPolicy.volumeStep)
        case .enterFullScreen:
            enterFullScreen(window)
        case .exitFullScreen:
            exitFullScreen(window)
        }
        showHUDTemporarily()
    }

    private func togglePlayPause() {
        guard appState.selectedChannel != nil else { return }
        let shouldPlay = PlayerKeyboardShortcutPolicy.toggledPlaybackState(
            from: playerState.isPlaying
        )
        playerState.isPlaying = shouldPlay
        if shouldPlay {
            MPVPlayerEngine.live.resume()
        } else {
            MPVPlayerEngine.live.pause()
        }
    }

    private func seekLivePlayback(by offset: Double) {
        let duration = playerState.duration
        guard LivePlayerInteractionPolicy.canSeek(duration: duration) else { return }
        let position = min(max(0, playerState.position + offset), duration)
        MPVPlayerEngine.live.seek(to: Int64(position * 1_000))
    }

    private func setVolume(_ volume: Float) {
        let clamped = min(1, max(0, volume))
        if clamped > 0 {
            lastNonZeroVolume = clamped
        }
        playerState.volume = clamped
        MPVPlayerEngine.live.setVolume(clamped)
    }

    private func toggleMute() {
        if playerState.volume > 0 {
            setVolume(0)
        } else {
            setVolume(max(0.01, lastNonZeroVolume))
        }
    }

    private func ensureGuideFocus() {
        if let guideFocusedChannel {
            focusGuideChannel(guideFocusedChannel)
        } else if let selected = appState.selectedChannel {
            focusGuideChannel(selected)
        } else if isSearching {
            focusGuideChannel(searchHits.first?.channel)
        } else {
            focusGuideChannel(displayedChannels.first)
        }
    }

    private func focusGuideChannel(_ channel: Channel?) {
        guideFocusedChannel = channel
    }

    private func selectChannel(_ channel: Channel, group: ChannelGroup?) {
        let sourceGroup = sourceGroup(for: channel, fallback: group)
        if let sourceGroup {
            appState.selectedGroup = sourceGroup
        }
        focusGuideChannel(channel)
        liveSearchText = ""
        hideGuide()
        Task {
            await appState.playChannel(channel)
            showHUDTemporarily()
        }
    }

    private func changeChannel(offset: Int) {
        guard let selectedChannel = appState.selectedChannel,
              let group = sourceGroup(for: selectedChannel, fallback: appState.selectedGroup),
              !group.channels.isEmpty else { return }

        let currentIndex = group.channels.firstIndex(where: { channelIdentity($0) == channelIdentity(selectedChannel) }) ?? 0
        let nextIndex = (currentIndex + offset + group.channels.count) % group.channels.count
        selectChannel(group.channels[nextIndex], group: group)
    }

    private func stopLive() {
        appState.cancelLivePlaybackAttempts()
        MPVPlayerEngine.live.stop()
        appState.selectedChannel = nil
        appState.liveError = nil
        isGuideVisible = false
        isChannelNumberEntryVisible = false
        isHUDVisible = true
        restorePlayerCursor()
    }

    private func retryCurrentChannel() {
        guard let channel = appState.selectedChannel else {
            appState.liveError = nil
            showGuide()
            return
        }
        appState.liveError = nil
        selectChannel(channel, group: appState.selectedGroup)
    }

    private func toggleFullScreen() {
        guard let window = playerWindow else { return }
        PlayerWindowChromePolicy.toggleFullScreen(window)
        showHUDTemporarily()
    }

    private func enterFullScreen(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        PlayerWindowChromePolicy.toggleFullScreen(window)
    }

    private func exitFullScreen(_ window: NSWindow) {
        guard window.styleMask.contains(.fullScreen) else { return }
        PlayerWindowChromePolicy.toggleFullScreen(window)
    }

    private var playerWindow: NSWindow? {
        windowContext.window
    }

    private func scheduleChannelNumberSubmit() {
        channelNumberSubmitTask?.cancel()
        guard !channelNumberInput.isEmpty else { return }
        channelNumberSubmitTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                playChannelNumber()
            }
        }
    }

    private func playChannelNumber() {
        channelNumberSubmitTask?.cancel()
        let requested = channelNumberInput.trimmingCharacters(in: .whitespacesAndNewlines)
        channelNumberInput = ""
        isChannelNumberEntryVisible = false
        isChannelNumberFieldFocused = false
        guard !requested.isEmpty else { return }

        let normalizedRequest = normalizedChannelNumber(requested)
        for group in sourceVisibleGroups {
            if let channel = group.channels.first(where: { channel in
                channel.number == requested || normalizedChannelNumber(channel.number) == normalizedRequest
            }) {
                selectChannel(channel, group: group)
                return
            }
        }

        appState.liveError = "Live: 未找到频道号 \(requested)"
        showHUDTemporarily()
    }

    private func unlockHiddenGroup() {
        let password = hiddenGroupPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { hiddenGroupPassword = "" }
        guard !password.isEmpty else { return }

        let unlocked = appState.channelGroups
            .filter { $0.isHidden && $0.password == password }
            .map(\.name)
        guard !unlocked.isEmpty else {
            appState.liveError = "Live: 隐藏分组密码不匹配"
            return
        }

        unlockedHiddenGroupNames.formUnion(unlocked)
        if appState.selectedGroup.map({ isGroupVisible($0) }) != true {
            appState.selectedGroup = visibleGroups.first
        }
        showGuide()
    }

    private func normalizedChannelNumber(_ value: String) -> String {
        let digits = value.filter(\.isNumber)
        let trimmed = digits.drop { $0 == "0" }
        return trimmed.isEmpty ? String(digits) : String(trimmed)
    }

    private func showHUDTemporarily() {
        hudHideTask?.cancel()
        restorePlayerCursor()
        isHUDVisible = true
        guard shouldAutoHidePlayerChrome else { return }
        hudHideTask = Task {
            let delay = UInt64(PlayerCursorVisibilityPolicy.inactivityInterval * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if shouldAutoHidePlayerChrome {
                    isHUDVisible = false
                    PlayerCursorController.hideUntilMouseMoves()
                }
            }
        }
    }

    private var hasBlockingPlayerUI: Bool {
        isGuideVisible
            || isChannelNumberEntryVisible
            || appState.isLoadingLive
            || appState.liveError != nil
    }

    private var isPlaybackActivityActive: Bool {
        PlayerPlaybackActivityPolicy.isActive(
            isSourceLoading: appState.isLivePlaybackLoading,
            isMediaLoading: playerState.isMediaLoading,
            isBuffering: playerState.isBuffering
        )
    }

    private var playbackActivityPhase: PlayerPlaybackActivityPhase {
        PlayerPlaybackActivityPolicy.livePhase(
            isSourceLoading: appState.isLivePlaybackLoading,
            sourceLoadingMessage: appState.livePlaybackLoadingMessage,
            isMediaLoading: playerState.isMediaLoading,
            isBuffering: playerState.isBuffering,
            hasBlockingUI: hasBlockingPlayerUI
        )
    }

    private var shouldAutoHidePlayerChrome: Bool {
        appState.selectedChannel != nil && PlayerCursorVisibilityPolicy.shouldHide(
            isPlaying: playerState.isPlaying,
            isPointerInside: isPointerInsidePlayer,
            hasBlockingUI: hasBlockingPlayerUI,
            isLoading: appState.isLoadingLive || isPlaybackActivityActive
        )
    }

    private func restorePlayerCursor() {
        PlayerCursorController.restore()
    }

    private func exitLive() {
        hudHideTask?.cancel()
        channelNumberSubmitTask?.cancel()
        restorePlayerCursor()
        onExit()
    }

    private var topSubtitle: String {
        var parts: [String] = []
        if let group = appState.selectedGroup?.name, !group.isEmpty {
            parts.append(group)
        }
        if appState.selectedChannel != nil {
            parts.append("线路 \(appState.currentChannelUrlIndex + 1)")
        }
        return parts.isEmpty ? (appState.activeLive?.name ?? "直播") : parts.joined(separator: " · ")
    }

    private var bottomSubtitle: String {
        var parts: [String] = []
        if let group = appState.selectedGroup?.name, !group.isEmpty {
            parts.append(group)
        }
        if appState.selectedChannel != nil {
            parts.append("线路 \(appState.currentChannelUrlIndex + 1)")
        }
        return parts.isEmpty ? "打开频道指南选择频道" : parts.joined(separator: " · ")
    }

    private var heroSubtitle: String {
        var parts: [String] = []
        if let group = appState.selectedGroup?.name, !group.isEmpty {
            parts.append(group)
        }
        return parts.isEmpty ? "正在播放直播频道" : parts.joined(separator: " · ")
    }

    private var visibleGroups: [ChannelGroup] {
        appState.liveGuideGroups(from: sourceVisibleGroups)
    }

    private var sourceVisibleGroups: [ChannelGroup] {
        appState.channelGroups.filter { group in
            !group.isHidden || appState.activeLive?.pass == true || unlockedHiddenGroupNames.contains(group.name)
        }
    }

    private var hasLockedHiddenGroups: Bool {
        appState.channelGroups.contains { group in
            group.isHidden && appState.activeLive?.pass != true && !unlockedHiddenGroupNames.contains(group.name)
        }
    }

    private var displayedChannels: [Channel] {
        appState.selectedGroup?.channels ?? []
    }

    private var searchHits: [LiveChannelSearchHit] {
        let query = normalizedSearchText
        guard !query.isEmpty else { return [] }
        return sourceVisibleGroups.flatMap { group in
            group.channels.enumerated()
                .filter { _, channel in channel.name.localizedCaseInsensitiveContains(query) }
                .map { index, channel in
                    LiveChannelSearchHit(id: "\(group.id)-\(index)-\(channelIdentity(channel))", group: group, channel: channel)
                }
        }
    }

    private var normalizedSearchText: String {
        liveSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !normalizedSearchText.isEmpty
    }

    private var accentGradient: LinearGradient {
        LinearGradient(
            colors: [LiveUIPalette.lavender, LiveUIPalette.accent],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var inactiveIcon: Color {
        LiveUIPalette.muted
    }

    private func rowBackground(_ selected: Bool) -> AnyShapeStyle {
        if selected {
            return AnyShapeStyle(LiveUIPalette.lavender.opacity(0.20))
        }
        return AnyShapeStyle(Color.white.opacity(0.06))
    }

    private func isSelected(_ group: ChannelGroup) -> Bool {
        appState.selectedGroup?.id == group.id
    }

    private func isGroupVisible(_ group: ChannelGroup) -> Bool {
        if group.name == PlaybackLinkage.liveFavoritesGroupName {
            return true
        }
        return !group.isHidden || appState.activeLive?.pass == true || unlockedHiddenGroupNames.contains(group.name)
    }

    private func isSelected(_ channel: Channel) -> Bool {
        guard let selected = appState.selectedChannel else { return false }
        return channelIdentity(selected) == channelIdentity(channel)
    }

    private func isGuideFocused(_ channel: Channel) -> Bool {
        guard let focused = guideFocusedChannel else { return false }
        return channelIdentity(focused) == channelIdentity(channel)
    }

    private func channelSecondaryText(channel: Channel, group: ChannelGroup?) -> String {
        if group?.name == PlaybackLinkage.liveFavoritesGroupName {
            return sourceGroup(for: channel, fallback: group)?.name ?? "直播收藏"
        }
        if isSearching, let group {
            return group.name
        }
        if channel.urls.count > 1 {
            return "\(channel.urls.count) 条线路"
        }
        return channel.epgName.isEmpty ? "直播频道" : channel.epgName
    }

    private func sourceGroup(for channel: Channel, fallback group: ChannelGroup?) -> ChannelGroup? {
        if let group, group.name != PlaybackLinkage.liveFavoritesGroupName {
            return group
        }
        return appState.sourceGroup(forLiveChannel: channel)
    }

    private func channelIdentity(_ channel: Channel) -> String {
        "\(channel.name)|\(channel.number)|\(channel.urls.first ?? "")"
    }

}

enum LivePlayerInteractionPolicy {
    static let topChromeHeight: CGFloat = 58

    static func videoGestureMask(hasSelectedChannel: Bool, hasBlockingUI: Bool = false) -> GestureMask {
        PlayerPointerShortcutPolicy.videoGestureMask(
            hasPlayback: hasSelectedChannel,
            hasBlockingUI: hasBlockingUI
        )
    }

    static func canSeek(duration: Double) -> Bool {
        duration.isFinite && duration > 0
    }
}

enum LiveGuideLayoutPolicy {
    static let scrollbarTheme: AppScrollbarTheme = .player
    static let maximumDrawerWidth: CGFloat = 860
    static let horizontalMargin: CGFloat = 40
    static let contentPadding: CGFloat = 12
    static let columnSpacing: CGFloat = 10
    static let minimumGroupWidth: CGFloat = 230
    static let maximumGroupWidth: CGFloat = 260
    static let minimumChannelWidth: CGFloat = 300

    static func drawerWidth(availableWidth: CGFloat) -> CGFloat {
        max(0, min(maximumDrawerWidth, availableWidth - horizontalMargin))
    }

    static func groupWidth(drawerWidth: CGFloat) -> CGFloat {
        let contentWidth = max(0, drawerWidth - contentPadding * 2 - columnSpacing)
        let preferredWidth = min(
            maximumGroupWidth,
            max(minimumGroupWidth, drawerWidth * 0.32)
        )
        return max(0, min(preferredWidth, contentWidth - minimumChannelWidth))
    }

    static func channelWidth(drawerWidth: CGFloat, groupWidth: CGFloat) -> CGFloat {
        max(0, drawerWidth - contentPadding * 2 - columnSpacing - groupWidth)
    }
}

private enum LiveUIPalette {
    static let background = PlayerHUDPalette.background
    static let surface = PlayerHUDPalette.surface
    static let foreground = PlayerHUDPalette.foreground
    static let muted = PlayerHUDPalette.muted
    static let accent = PlayerHUDPalette.accent
    static let lavender = PlayerHUDPalette.lavender
    static let danger = Color(red: 0.920, green: 0.310, blue: 0.300)
    static let warning = Color(red: 0.960, green: 0.760, blue: 0.260)
}

private struct LiveChannelSearchHit: Identifiable {
    let id: String
    let group: ChannelGroup
    let channel: Channel
}
