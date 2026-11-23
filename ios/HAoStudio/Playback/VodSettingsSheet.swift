// HAo Studio 2.0 — VOD settings sheet (S3, leg A).
//
// One of the four independent VOD pieces (P0-08): this file owns
// ONLY the settings sheet state + view. It knows nothing about
// the driver, the gesture layer or danmaku; the view model hands
// it a binding and applies changes back to the driver.
//
// NO QUALITY SELECTOR (rule 3, iron law): VOD has one play URL
// per episode and no quality tiers, so there is no quality row
// here, no fake button, no "画质" of any kind. The rows are:
// picture fit, speed, danmaku on/off + opacity, audio track,
// subtitle track, dialogue boost (MPV only), and the playback
// diagnosis (engine + hard-decode state + fps — a software
// decode says "软解中" here, never hides).
//
// All colours come from the theme palette (`.haoTheme`); no
// literal colours, no purple, no red (nothing here is a LIVE
// badge or a recording dot).
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation
import SwiftUI

// MARK: - State

/// VOD settings state. A plain value type: the view model owns
/// the current value, the sheet edits a binding, persistence is
/// UserDefaults under `hao_vod_*` keys.
struct VodSettingsState: Equatable {
    /// Picture fit (适应 / 裁剪 / 拉伸).
    var videoFit: VideoFit = .aspectFit
    /// Playback speed 0.5-2.0 (VOD only).
    var playbackSpeed: Double = 1.0
    /// Danmaku overlay on/off.
    var danmakuEnabled: Bool = true
    /// Danmaku text opacity 0.3-1.0.
    var danmakuOpacity: Double = 1.0
    /// Selected audio track index (-1 = default track).
    var audioTrackIndex: Int = -1
    /// Selected subtitle track index (-1 = no subtitles).
    var subtitleTrackIndex: Int = -1
    /// Dialogue boost (MPV only — an audio filter; other engines
    /// ignore it and the row is disabled).
    var dialogueBoostEnabled: Bool = false

    static func load(defaults: UserDefaults = .standard) -> VodSettingsState {
        var state = VodSettingsState()
        if let fitRaw = defaults.string(forKey: "hao_vod_fit"),
           let fit = VideoFit(rawValue: fitRaw) {
            state.videoFit = fit
        }
        let speed = defaults.double(forKey: "hao_vod_speed")
        if speed > 0 { state.playbackSpeed = min(2.0, max(0.5, speed)) }
        if defaults.object(forKey: "hao_vod_danmaku") != nil {
            state.danmakuEnabled = defaults.bool(forKey: "hao_vod_danmaku")
        }
        let opacity = defaults.double(forKey: "hao_vod_danmaku_opacity")
        if opacity > 0 { state.danmakuOpacity = min(1.0, max(0.3, opacity)) }
        state.audioTrackIndex = defaults.integer(forKey: "hao_vod_audio_track")
        state.subtitleTrackIndex = defaults.object(forKey: "hao_vod_subtitle_track") == nil
            ? -1 : defaults.integer(forKey: "hao_vod_subtitle_track")
        state.dialogueBoostEnabled = defaults.bool(forKey: "hao_vod_dialogue_boost")
        return state
    }

    func persist(defaults: UserDefaults = .standard) {
        defaults.set(videoFit.rawValue, forKey: "hao_vod_fit")
        defaults.set(playbackSpeed, forKey: "hao_vod_speed")
        defaults.set(danmakuEnabled, forKey: "hao_vod_danmaku")
        defaults.set(danmakuOpacity, forKey: "hao_vod_danmaku_opacity")
        defaults.set(audioTrackIndex, forKey: "hao_vod_audio_track")
        defaults.set(subtitleTrackIndex, forKey: "hao_vod_subtitle_track")
        defaults.set(dialogueBoostEnabled, forKey: "hao_vod_dialogue_boost")
    }
}

// MARK: - Sheet view

/// VOD settings sheet. The page presents it from
/// `VodPlayerViewModel.showSettings`; changes flow back through
/// the binding and the view model applies them to the driver.
/// `audioTracks` / `subtitleTracks` are display names from the
/// backend (empty = the row is hidden — most CMS streams carry
/// neither). `isMpv` enables the dialogue-boost row.
struct VodSettingsSheet: View {
    @Environment(\.haoTheme) private var theme
    @Binding var state: VodSettingsState
    var engine: VideoEngine
    var diagnostics: VideoPlaybackDiagnostics
    var audioTracks: [String] = []
    var subtitleTracks: [String] = []

    var body: some View {
        List {
            Section {
                Picker("画面比例", selection: $state.videoFit) {
                    ForEach(VideoFit.allCases, id: \.self) { fit in
                        Text(fit.label).tag(fit)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("倍速")
                    Spacer()
                    Text(String(format: "%.2fx", state.playbackSpeed))
                        .foregroundColor(theme.textSecondary)
                }
                Slider(value: $state.playbackSpeed, in: 0.5...2.0, step: 0.25)
            } header: {
                Text("播放")
            }

            Section {
                Toggle("弹幕", isOn: $state.danmakuEnabled)
                if state.danmakuEnabled {
                    HStack {
                        Text("弹幕不透明度")
                        Spacer()
                        Text(String(format: "%.0f%%", state.danmakuOpacity * 100))
                            .foregroundColor(theme.textSecondary)
                    }
                    Slider(value: $state.danmakuOpacity, in: 0.3...1.0, step: 0.1)
                }
            } header: {
                Text("弹幕")
            }

            if !audioTracks.isEmpty {
                Section {
                    Picker("音轨", selection: $state.audioTrackIndex) {
                        Text("默认").tag(-1)
                        ForEach(audioTracks.indices, id: \.self) { index in
                            Text(audioTracks[index]).tag(index)
                        }
                    }
                } header: {
                    Text("音轨")
                }
            }

            if !subtitleTracks.isEmpty {
                Section {
                    Picker("字幕", selection: $state.subtitleTrackIndex) {
                        Text("无").tag(-1)
                        ForEach(subtitleTracks.indices, id: \.self) { index in
                            Text(subtitleTracks[index]).tag(index)
                        }
                    }
                } header: {
                    Text("字幕")
                }
            }

            if engine == .mpv {
                Section {
                    Toggle("对白增强", isOn: $state.dialogueBoostEnabled)
                } header: {
                    Text("音频")
                } footer: {
                    Text("仅 MPV 引擎支持")
                }
            }

            Section {
                ForEach(diagnostics.detailLines, id: \.self) { line in
                    Text(line)
                        .foregroundColor(theme.textSecondary)
                }
            } header: {
                Text("播放诊断")
            }
        }
        .listStyle(.insetGrouped)
        .background(theme.scaffoldBackground)
    }
}
