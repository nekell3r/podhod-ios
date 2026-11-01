import ActivityKit
import SwiftUI
import WidgetKit

@main
struct PodhodRestActivityBundle: WidgetBundle {
    var body: some Widget { PodhodRestLiveActivity() }
}

struct PodhodRestLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutRestAttributes.self) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(context.isStale ? "Отдых завершён" : "Отдых", systemImage: "timer")
                            .font(.headline)
                        Text(context.isStale ? "Можно продолжать тренировку" :
                            context.state.betweenExercises ? "Перед следующим упражнением" : "Между подходами")
                            .font(.caption).foregroundStyle(Color.gymMuted)
                    }
                    Spacer(minLength: 10)
                    RestActivityTimer(deadline: context.state.deadline)
                        .font(.title2.bold()).foregroundStyle(Color.gymLime).frame(width: 80)
                }
                RestActivityActions(attributes: context.attributes, deadline: context.state.deadline)
            }
            .padding(18)
            .foregroundStyle(.white)
            .activityBackgroundTint(Color.gymBackground)
            .activitySystemActionForegroundColor(Color.gymLime)
            .widgetURL(context.attributes.link(.open, deadline: context.state.deadline))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.isStale ? "Можно продолжать" : "Отдых", systemImage: "timer")
                        .font(.headline).foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RestActivityTimer(deadline: context.state.deadline).font(.title2.bold()).foregroundStyle(Color.gymLime).frame(width: 80)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RestActivityActions(attributes: context.attributes, deadline: context.state.deadline).padding(.top, 8)
                }
            } compactLeading: {
                Image(systemName: "timer").foregroundStyle(Color.gymLime)
            } compactTrailing: {
                RestActivityTimer(deadline: context.state.deadline).font(.caption).frame(width: 46)
            } minimal: {
                Image(systemName: "timer").foregroundStyle(Color.gymLime)
            }
            .widgetURL(context.attributes.link(.open, deadline: context.state.deadline))
            .keylineTint(Color.gymLime)
        }
    }
}

private struct RestActivityTimer: View {
    let deadline: Date
    var body: some View {
        let interval = min(Date(), deadline)...deadline
        return Text(timerInterval: interval, countsDown: true, showsHours: false)
            .monospacedDigit().multilineTextAlignment(.trailing)
            .accessibilityLabel("Осталось отдыха")
            .accessibilityValue(Text(timerInterval: interval, countsDown: true, showsHours: false))
    }
}

private struct RestActivityActions: View {
    let attributes: WorkoutRestAttributes
    let deadline: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 24) {
                if let url = attributes.link(.extend, deadline: deadline) {
                    Link(destination: url) { Label("30 с", systemImage: "plus") }
                        .accessibilityLabel("Добавить 30 секунд отдыха в Подходе")
                }
                if let url = attributes.link(.stop, deadline: deadline) {
                    Link(destination: url) { Label("Закончить", systemImage: "checkmark") }
                        .accessibilityLabel("Закончить отдых в Подходе")
                }
            }.font(.subheadline.weight(.semibold)).foregroundStyle(Color.gymLime)
            Text("Действия откроют «Подход»").font(.caption2).foregroundStyle(Color.gymMuted)
        }
    }
}
