// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic

/// Full-player lyrics panel. Displays all five ViewModel states; the current line is kept
/// centred in the viewport and emphasised, with the rest fading by distance (no blur).
struct LyricsView: View {
    @Bindable var viewModel: LyricsViewModel
    var foregroundColor: Color = .white

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .loaded(let structured):
                loadedContent(structured)

            case .empty:
                emptyState

            case .unsupported:
                unsupportedState

            case .error(let message):
                errorState(message)
            }
        }
        .onAppear { viewModel.setVisible(true) }
        .onDisappear { viewModel.setVisible(false) }
        .onChange(of: viewModel.isPlaying) { _, _ in viewModel.reconcileTracking() }
    }

    // MARK: - Loaded

    @ViewBuilder
    private func loadedContent(_ structured: StructuredLyrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Plain VStack, not LazyVStack: every row is materialised, so scrollTo(id,
                // anchor: .center) always finds the target. Lazy stacks only build rows on
                // approach — scrollTo to a not-yet-built index silently no-ops, which is how
                // the lyric column used to stop following the song.
                VStack(alignment: .leading, spacing: 32) {
                    ForEach(Array(structured.line.enumerated()), id: \.offset) { index, line in
                        LyricsLineView(
                            // Defensive: a stray `\r` from any source (server structured
                            // lyrics included) makes Text overstrike the suffix onto the same
                            // visual row — the "ghosted" overlap. Normalise it to a vertical
                            // break so the rest of the line stays readable below, never on top.
                            value: line.value.replacingOccurrences(of: "\r", with: "\n"),
                            index: index,
                            currentIndex: viewModel.currentLineIndex,
                            isSynced: structured.synced,
                            isTappable: structured.synced && line.start != nil,
                            foregroundColor: foregroundColor,
                            onTap: { viewModel.userTapped(lineIndex: index) }
                        )
                        .id(index)
                    }
                }
                .padding(.horizontal, 8)
                // Generous top/bottom padding so the first and last lines can still be centred
                // on the scroll viewport (otherwise anchor .center leaves them pinned to the edge).
                .padding(.vertical, 240)
            }
            .scrollIndicators(.hidden)
            // Centre on the current line as it advances. Auto-scroll is suppressed while the
            // user is dragging (and for the 3 s grace after they let go).
            .onChange(of: viewModel.currentLineIndex) { _, newIndex in
                guard viewModel.autoScrollEnabled,
                      !viewModel.isUserScrolling else { return }
                scrollToCurrent(newIndex, in: proxy, animated: true)
            }
            // Centre once when lyrics first load — currentLineIndex is already non-nil by the
            // time the view appears, so the .onChange above never fires for the initial frame
            // and the column would stay pinned at the top.
            .onAppear {
                scrollToCurrent(viewModel.currentLineIndex, in: proxy, animated: false)
            }
            .onChange(of: viewModel.state) { _, newState in
                // Re-centre after a language switch or a retry that swaps the synced set.
                if case .loaded = newState {
                    scrollToCurrent(viewModel.currentLineIndex, in: proxy, animated: false)
                }
            }
            // During the manual-scroll grace period the active lyric may advance,
            // but those changes intentionally do not move the list. Re-centre as
            // soon as auto-follow resumes instead of waiting for another lyric line.
            .onChange(of: viewModel.isUserScrolling) { _, isScrolling in
                guard !isScrolling else { return }
                scrollToCurrent(viewModel.currentLineIndex, in: proxy, animated: true)
            }
            .onChange(of: viewModel.autoScrollEnabled) { _, isEnabled in
                guard isEnabled else { return }
                scrollToCurrent(viewModel.currentLineIndex, in: proxy, animated: true)
            }
            .onScrollPhaseChange { _, newPhase in
                switch newPhase {
                case .tracking, .interacting, .decelerating:
                    // Deceleration is still user-driven scrolling. Keep auto-follow
                    // suspended until the scroll view is genuinely idle, otherwise a
                    // lyric tick can start scrollTo while momentum is still moving it.
                    guard !viewModel.isUserScrolling else { return }
                    viewModel.userStartedScrolling()
                case .idle:
                    guard viewModel.isUserScrolling else { return }
                    viewModel.userStoppedScrolling()
                default:
                    break
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                header
            }
        }
    }

    /// Scrolls the lyric column so `index` sits at the vertical centre of the viewport.
    /// No-op when there is no line to centre on, or when auto-scroll is disabled.
    private func scrollToCurrent(_ index: Int?, in proxy: ScrollViewProxy, animated: Bool) {
        guard viewModel.autoScrollEnabled, let index else { return }
        let scroll = { proxy.scrollTo(index, anchor: .center) }
        if animated {
            withAnimation(.easeInOut(duration: 0.3)) { scroll() }
        } else {
            scroll()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 16) {
            if viewModel.availableLanguages.count > 1 {
                Menu {
                    ForEach(viewModel.availableLanguages, id: \.self) { lang in
                        Button(displayName(for: lang)) {
                            viewModel.selectLanguage(lang)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                        Text(displayName(for: viewModel.selectedLanguage ?? "und"))
                    }
                    .font(.callout)
                    .foregroundStyle(foregroundColor.opacity(0.8))
                }
            }

            Spacer()

            // Force a re-fetch from the server. The lyrics cache has a long TTL, so
            // without this the player would keep showing stale words after Navidrome
            // scanned an updated `.lrc` sidecar. See LyricsViewModel.refresh().
            Button {
                Task { await viewModel.refresh() }
            } label: {
                if viewModel.isRefreshing {
                    ProgressView()
                        .font(.title3)
                        .foregroundStyle(foregroundColor.opacity(0.8))
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.title3)
                        .foregroundStyle(foregroundColor.opacity(0.8))
                }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isRefreshing)

            Button {
                viewModel.autoScrollEnabled.toggle()
            } label: {
                Image(systemName: viewModel.autoScrollEnabled
                    ? "arrow.up.arrow.down.circle.fill"
                    : "arrow.up.arrow.down.circle")
                    .font(.title3)
                    .foregroundStyle(foregroundColor.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 12)
    }

    // MARK: - Empty states

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40))
                .foregroundStyle(foregroundColor.opacity(0.65))
            Text("No lyrics available")
                .font(.cassetteDetailTitle)
                .foregroundStyle(foregroundColor.opacity(0.65))
            retryButton
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unsupportedState: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(foregroundColor.opacity(0.65))
            Text("Lyrics not supported")
                .font(.cassetteDetailTitle)
                .foregroundStyle(foregroundColor.opacity(0.65))
            Text("This server rejected the lyrics endpoint. Structured lyrics need Navidrome 0.53 or later.")
                .font(.callout)
                .foregroundStyle(foregroundColor.opacity(0.65))
                .multilineTextAlignment(.center)
            retryButton
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.octagon")
                .font(.system(size: 40))
                .foregroundStyle(foregroundColor.opacity(0.65))
            Text("Failed to load lyrics")
                .font(.cassetteDetailTitle)
                .foregroundStyle(foregroundColor)
            Text(message)
                .font(.caption)
                .foregroundStyle(foregroundColor.opacity(0.65))
            retryButton
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Re-queries the server, ignoring the cached result.
    ///
    /// Failures were previously terminal: the only way out was to leave the player and
    /// come back. Retrying also clears the negative cache, so a server that has since
    /// picked up an `.lrc` file is picked up without a restart.
    private var retryButton: some View {
        Button {
            Task { await viewModel.retry() }
        } label: {
            Label("Try again", systemImage: "arrow.clockwise")
                .font(.callout)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Helpers

    private func displayName(for lang: String) -> String {
        guard lang != "und", lang != "xxx" else { return "—" }
        return Locale.current.localizedString(forLanguageCode: lang)?.capitalized ?? lang.uppercased()
    }
}
