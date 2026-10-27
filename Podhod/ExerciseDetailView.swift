import SwiftUI
import AVKit

struct ExerciseDetailView: View {
    var exercise: Exercise
    var add: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVPlayer?
    @State private var playingVideoID: String?
    @State private var playbackFailed = false
    private let catalog = ExerciseCatalog.bundled
    private var entry: ExerciseCatalogEntry? { catalog.entry(for: exercise.id) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(exercise.name).font(.system(.title, design: .rounded).bold())
                        ExerciseArt(kind: catalog.illustration(for: exercise))
                            .frame(height: 190).frame(maxWidth: .infinity)
                            .background(Color.gymCard, in: RoundedRectangle(cornerRadius: 24))
                    }
                    if let entry {
                        let primaryNames = catalog.muscles.filter { entry.primaryMuscles.contains($0.id) }.map(\.name).joined(separator: ", ")
                        let secondaryNames = catalog.muscles.filter { entry.secondaryMuscles.contains($0.id) && !entry.primaryMuscles.contains($0.id) }.map(\.name).joined(separator: ", ")
                        VStack(alignment: .leading, spacing: 18) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Основные мышцы").font(.headline)
                                Text(primaryNames.isEmpty ? "Не указаны в источнике" : primaryNames)
                                    .font(.subheadline).foregroundStyle(Color.gymLime)
                            }
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Вспомогательные мышцы").font(.headline)
                                Text(secondaryNames.isEmpty ? "Не учитываются в расчёте" : secondaryNames)
                                    .font(.subheadline).foregroundStyle(Color.gymMuted)
                            }
                            if !entry.equipment.isEmpty {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("Оборудование").font(.headline)
                                    Text(catalog.equipment.filter { entry.equipment.contains($0.id) }.map(\.name).joined(separator: ", "))
                                        .font(.subheadline).foregroundStyle(Color.gymMuted)
                                }
                            }
                            Text("Русские пояснения и разметка мышц — Подход")
                                .font(.caption2).foregroundStyle(Color.gymMuted)
                        }.frame(maxWidth: .infinity, alignment: .leading).modifier(GymCard())
                        if !entry.instructions.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                SectionLabel(title: "Как выполнять")
                                ForEach(Array(entry.instructions.enumerated()), id: \.offset) { index, instruction in
                                    HStack(alignment: .top, spacing: 12) {
                                        Text("\(index + 1)").font(.subheadline.bold()).foregroundStyle(Color.gymLime)
                                            .frame(width: 20)
                                        Text(instruction).font(.subheadline).lineSpacing(4)
                                    }
                                }
                            }
                        } else if !entry.exercise.cue.isEmpty {
                            Text(entry.exercise.cue).font(.subheadline).foregroundStyle(Color.gymMuted).lineSpacing(4)
                        }
                        if !exercise.cue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           exercise.cue.trimmingCharacters(in: .whitespacesAndNewlines) != entry.exercise.cue.trimmingCharacters(in: .whitespacesAndNewlines) {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionLabel(title: "Твоя заметка")
                                Text(exercise.cue).font(.subheadline).lineSpacing(4)
                            }.frame(maxWidth: .infinity, alignment: .leading).modifier(GymCard())
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            SectionLabel(title: "Видео", detail: "Нужен интернет")
                            if entry.videos.isEmpty {
                                Text("Для этого упражнения в каталоге пока нет видео.")
                                    .font(.subheadline).foregroundStyle(Color.gymMuted)
                            }
                            ForEach(entry.videos) { video in
                                videoCard(video)
                            }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            if !entry.attribution.author.isEmpty {
                                Text("Данные справочника: \(entry.attribution.author)").font(.caption).foregroundStyle(Color.gymMuted)
                            }
                            if let url = URL(string: entry.attribution.licenseURL), url.scheme == "https", url.host?.isEmpty == false, !entry.attribution.license.isEmpty {
                                Link("Лицензия: \(entry.attribution.license)", destination: url).font(.caption)
                            }
                            if let url = URL(string: entry.sourceURL), url.scheme == "https", url.host?.isEmpty == false,
                               !entry.videos.contains(where: { $0.playback == .external && $0.url == entry.sourceURL }) {
                                Link(destination: url) { Label("Открыть источник", systemImage: "arrow.up.right.square") }
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(exercise.muscle).font(.headline).foregroundStyle(Color.gymLime)
                            Text(exercise.cue).font(.subheadline).foregroundStyle(Color.gymMuted).lineSpacing(4)
                            Text("Для своего или ранее сохранённого упражнения разметка мышц и видео могут быть недоступны. Его подходы не включаются в расчёт нагрузки по мышцам.")
                                .font(.caption).foregroundStyle(Color.gymMuted)
                        }.modifier(GymCard())
                    }
                }.padding(22)
            }
            .background(Color.gymBackground)
            .navigationTitle("Об упражнении")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                if let add {
                    Button {
                        add()
                        dismiss()
                    } label: { Label("Добавить в тренировку", systemImage: "plus") }
                        .buttonStyle(PrimaryButton()).padding(.horizontal, 22).padding(.vertical, 12)
                        .background(Color.gymBackground)
                }
            }
        }
        .tint(.gymLime).preferredColorScheme(.dark)
        .onDisappear { player?.pause() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { player?.pause() }
        }
        #if os(macOS)
        .frame(minWidth: 430, minHeight: 650)
        #endif
    }

    private func videoCard(_ video: ExerciseVideo) -> some View {
        let number = (entry?.videos.firstIndex(where: { $0.id == video.id }) ?? 0) + 1
        return VStack(alignment: .leading, spacing: 12) {
            if video.playback == .external {
                if let url = URL(string: video.url), url.scheme == "https", url.host?.isEmpty == false {
                    Link(destination: url) {
                        Label("Смотреть на сайте", systemImage: "arrow.up.right.square")
                            .font(.headline).frame(maxWidth: .infinity).frame(minHeight: 80)
                            .background(Color.gymBackground, in: RoundedRectangle(cornerRadius: 14))
                    }.foregroundStyle(Color.gymLime)
                }
                Text("Это видео доступно на сайте автора и откроется в браузере.")
                    .font(.caption).foregroundStyle(Color.gymMuted)
            } else if playingVideoID == video.id, let player, let item = player.currentItem {
                VideoPlayer(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .onReceive(item.publisher(for: \.status, options: [.initial, .new]).receive(on: RunLoop.main)) { status in
                        if status == .failed, self.player === player { playbackFailed = true }
                    }
                if playbackFailed {
                    Text("Видео не удалось загрузить. Проверь интернет или открой его на сайте источника.")
                        .font(.caption).foregroundStyle(Color.gymMuted)
                }
                Button("Закрыть видео") {
                    player.pause()
                    self.player = nil
                    playingVideoID = nil
                }.font(.caption)
            } else {
                Button {
                    guard let url = URL(string: video.url), url.scheme == "https", url.host?.isEmpty == false else { return }
                    player?.pause()
                    playbackFailed = false
                    playingVideoID = video.id
                    let newPlayer = AVPlayer(url: url)
                    player = newPlayer
                    newPlayer.play()
                } label: {
                    Label("Смотреть технику · видео \(number)", systemImage: "play.circle.fill")
                        .font(.headline).frame(maxWidth: .infinity).frame(minHeight: 100)
                        .background(Color.gymBackground, in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain).foregroundStyle(Color.gymLime)
            }
            Text("Видео: \(video.author)").font(.caption).foregroundStyle(Color.gymMuted)
            if video.playback != .external {
                HStack(alignment: .firstTextBaseline) {
                    if let url = URL(string: video.licenseURL), url.scheme == "https", url.host?.isEmpty == false {
                        Link(video.license, destination: url).font(.caption)
                    }
                    Spacer(minLength: 8)
                    if let url = URL(string: video.sourceURL), url.scheme == "https", url.host?.isEmpty == false {
                        Link("Открыть на сайте ↗", destination: url).font(.caption)
                    }
                }
            }
        }.modifier(GymCard())
    }
}
