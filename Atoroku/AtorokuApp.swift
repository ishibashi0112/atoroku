import SwiftUI

/// アプリの入口。
@main
struct AtorokuApp: App {
    /// アプリ全体で1つの録音係。@State に置くと、画面が作り直されても同じものを使い続ける。
    @State private var recorder = Recorder()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(recorder)  // 画面の中のどこからでも @Environment(Recorder.self) で使えるようにする
        }
    }
}
