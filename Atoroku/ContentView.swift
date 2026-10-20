import SwiftUI

/// 段階0の画面: 「開始」「停止」と、今の状態だけ。保存ボタンはまだない（段階1で足す）。
struct ContentView: View {
    /// アプリ全体で1つの録音係（AtorokuApp で渡している）
    @Environment(Recorder.self) private var recorder
    /// アプリが前面にいるか裏にいるか
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmingStop = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StatusHeader(status: recorder.status, keepMinutes: recorder.keepMinutes)
                    startStopButton
                }

                Section("今の状態") {
                    // 1秒ごとに描き直す。画面が見えていないときは描かれないので、電池はほとんど使わない。
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        StateRows(recorder: recorder, snapshot: recorder.snapshot(at: context.date))
                    }
                }

                Section("記録") {
                    if recorder.log.entries.isEmpty {
                        Text("まだありません").foregroundStyle(.secondary)
                    }
                    // 新しい順に30件
                    ForEach(recorder.log.entries.reversed().prefix(30)) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Format.dateTime(entry.date))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(entry.text).font(.subheadline)
                        }
                    }
                }

                Section {
                    Text(
                        "録った音は「ファイル」アプリの「この iPhone 内 > あとろく > RingBuffer」で聞けます。"
                            + "直近\(recorder.keepMinutes)分より古いファイルは、録音中に自動で消えます。"
                            + "記録は同じ場所の「記録.txt」にも残ります。音声はこの iPhone の外に出ません。"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("あとろく")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                recorder.appBecameActive()
            }
        }
    }

    @ViewBuilder private var startStopButton: some View {
        if recorder.isRunning {
            Button(role: .destructive) {
                confirmingStop = true
            } label: {
                Label("停止", systemImage: "stop.fill")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            // 一日録り続ける計測なので、うっかり止めないよう確認を挟む
            .confirmationDialog("録音を止めますか？", isPresented: $confirmingStop, titleVisibility: .visible) {
                Button("停止する", role: .destructive) { recorder.stop() }
                Button("続ける", role: .cancel) {}
            }
        } else {
            Button {
                Task { await recorder.start() }
            } label: {
                Label("開始", systemImage: "record.circle")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// 一番上の大きな表示（録音中・中断中・止まっている）。
private struct StatusHeader: View {
    let status: Recorder.Status
    let keepMinutes: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(color)
                .symbolEffect(.pulse, isActive: status == .recording)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.bold())
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        switch status {
        case .stopped: "止まっています"
        case .starting: "開始しています…"
        case .recording: "録り続けています"
        case .interrupted: "中断しています"
        case .failed: "始められませんでした"
        }
    }

    private var detail: String {
        switch status {
        case .stopped: "「開始」を押すと、直近\(keepMinutes)分を持ち続けます"
        case .starting: "マイクの準備をしています"
        case .recording: "直近\(keepMinutes)分を持ち続けています。画面を消しても続きます"
        case .interrupted: "通話などが終わると自動で再開します"
        case .failed(let message): message
        }
    }

    private var symbol: String {
        switch status {
        case .recording: "record.circle.fill"
        case .interrupted: "pause.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .stopped, .starting: "mic.circle"
        }
    }

    private var color: Color {
        switch status {
        case .recording: .red
        case .interrupted: .orange
        case .failed: .yellow
        case .stopped, .starting: .secondary
        }
    }
}

/// 「今の状態」の行（経過時間、ファイル数、残り容量など）。
private struct StateRows: View {
    let recorder: Recorder
    let snapshot: Recorder.Snapshot

    var body: some View {
        LabeledContent("経過時間", value: snapshot.elapsed.map(Format.duration) ?? "—")
        LabeledContent("録れた時間", value: Format.duration(snapshot.recordedSeconds))
        LabeledContent("ファイル数", value: "\(snapshot.fileCount)（\(Format.bytes(snapshot.totalBytes))）")
        LabeledContent("残り容量", value: snapshot.freeBytes.map(Format.bytes) ?? "不明")
        LabeledContent("中断", value: "\(recorder.interruptionCount)回")
        LabeledContent("バッテリー", value: Recorder.batteryText)
        LabeledContent("マイク", value: recorder.inputName ?? "—")
        LabeledContent("さかのぼる長さ", value: "\(recorder.keepMinutes)分")
    }
}

#Preview {
    ContentView()
        .environment(Recorder())
}
