import SwiftUI

extension Color {
    static let gymBackground = Color(red: 0.055, green: 0.065, blue: 0.06)
    static let gymCard = Color(red: 0.10, green: 0.115, blue: 0.105)
    static let gymLime = Color(red: 0.79, green: 0.96, blue: 0.38)
    static let gymMuted = Color(red: 0.57, green: 0.62, blue: 0.57)
}

struct GymCard: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(20)
            .background(Color.gymCard, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.06), lineWidth: 1))
    }
}

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(.headline, design: .rounded).weight(.bold))
            .frame(maxWidth: .infinity).padding(.vertical, 18)
            .foregroundStyle(Color.gymBackground)
            .background(Color.gymLime.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 19))
    }
}

struct SectionLabel: View {
    var title: String
    var detail: String = ""
    var body: some View {
        HStack {
            Text(title).font(.system(.title3, design: .rounded).weight(.bold))
            Spacer()
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(Color.gymMuted) }
        }
    }
}

struct ExerciseRow: View {
    var plan: PlannedExercise
    var number: Int
    var body: some View {
        HStack(spacing: 14) {
            Text(String(format: "%02d", number)).font(.system(.headline, design: .monospaced))
                .foregroundStyle(Color.gymMuted).frame(width: 26)
            ExerciseArt(kind: ExerciseCatalog.bundled.illustration(for: plan.exercise)).frame(width: 66, height: 66)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16)).clipped()
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.exercise.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text("\(plan.setCount) подх. × \(plan.targetReps) повт.")
                    .font(.caption).foregroundStyle(Color.gymMuted)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.gymMuted)
        }.padding(.vertical, 8)
    }
}

struct MuscleVolumeSummary: View {
    var volume: PlannedMuscleVolume

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Прямые подходы × 1 + косвенные × 0,5")
                .font(.caption).foregroundStyle(Color.gymMuted)
            if !volume.muscles.isEmpty {
                HStack(spacing: 8) {
                    Text("Мышцы").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Прямые").frame(width: 48, alignment: .trailing)
                    Text("Косв.").frame(width: 62, alignment: .trailing)
                    Text("Итого").frame(width: 42, alignment: .trailing)
                }.font(.caption2).foregroundStyle(Color.gymMuted).accessibilityHidden(true)
                ForEach(volume.muscles) { muscle in
                    HStack(spacing: 8) {
                        Text(muscle.name).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(muscle.directSets)").frame(width: 48, alignment: .trailing)
                        Text("\(muscle.indirectSets) × 0,5").foregroundStyle(Color.gymMuted).frame(width: 62, alignment: .trailing)
                        Text(muscle.weightedSets.formatted(.number.precision(.fractionLength(0...1))))
                            .fontWeight(.semibold).foregroundStyle(Color.gymLime).frame(width: 42, alignment: .trailing)
                    }.font(.caption).monospacedDigit()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(muscle.name): прямых подходов \(muscle.directSets), косвенных \(muscle.indirectSets), с учётом коэффициента \(muscle.weightedSets.formatted(.number.precision(.fractionLength(0...1))))")
                }
            } else {
                Text(volume.unmappedExerciseCount == 0 ? "Добавь упражнения, чтобы увидеть нагрузку." : "У этих упражнений пока нет разметки мышц.")
                    .font(.subheadline).foregroundStyle(Color.gymMuted)
            }
            if volume.unmappedExerciseCount > 0 {
                Label("Без разметки: \(volume.unmappedExerciseCount) упр., \(volume.unmappedSets) подх. Они не включены в расчёт.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(Color.gymMuted)
            }
            Text("Плановые подходы. Коэффициент 0,5 — условная оценка участия вспомогательных мышц.")
                .font(.caption2).foregroundStyle(Color.gymMuted)
            Text("Все подходы программы считаются рабочими. Разметка мышц: \(volume.catalogVersion).")
                .font(.caption2).foregroundStyle(Color.gymMuted)
        }
    }
}

struct ExerciseArt: View {
    var kind: String
    var body: some View {
        Canvas { context, size in
            var context = context
            let scale = min(size.width / 300, size.height / 210)
            let sx = scale
            let sy = scale
            context.translateBy(x: (size.width - 300 * scale) / 2, y: (size.height - 210 * scale) / 2)
            func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
            func line(_ points: [(Double, Double)], color: Color, width: Double) {
                var path = Path()
                guard let first = points.first else { return }
                path.move(to: point(first.0, first.1))
                for p in points.dropFirst() { path.addLine(to: point(p.0, p.1)) }
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width * min(sx, sy), lineCap: .round, lineJoin: .round))
            }
            func head(_ x: Double, _ y: Double) {
                let rect = CGRect(x: (x - 13) * sx, y: (y - 13) * sy, width: 26 * sx, height: 26 * sy)
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.9)))
            }
            func bar(_ x: Double, _ y: Double, span: Double = 105) {
                line([(x - span / 2, y), (x + span / 2, y)], color: .gymLime, width: 5)
                for offset in [-span / 2 + 8, span / 2 - 8] {
                    line([(x + offset, y - 13), (x + offset, y + 13)], color: .gymLime, width: 10)
                }
            }
            let bodyColor = Color.white.opacity(0.88)
            let equipment = Color.gymMuted.opacity(0.45)
            for x in stride(from: 30.0, through: 270.0, by: 30) {
                line([(x, 20), (x, 190)], color: .white.opacity(0.035), width: 0.8)
            }
            line([(25, 188), (275, 188)], color: equipment, width: 1)
            switch kind {
            case "neck":
                head(150, 48)
                line([(150, 69), (150, 142)], color: bodyColor, width: 12)
                line([(86, 112), (125, 94), (175, 94), (214, 112)], color: bodyColor, width: 10)
                line([(104, 153), (196, 153)], color: equipment, width: 6)
                line([(112, 58), (101, 42), (107, 24)], color: .gymLime, width: 3)
                line([(188, 58), (199, 42), (193, 24)], color: .gymLime, width: 3)
            case "bench":
                line([(65, 142), (225, 142)], color: equipment, width: 10)
                line([(85, 147), (85, 185)], color: equipment, width: 6)
                line([(205, 147), (205, 185)], color: equipment, width: 6)
                head(77, 118)
                line([(98, 124), (169, 130), (196, 151), (203, 181), (227, 181)], color: bodyColor, width: 12)
                line([(110, 124), (133, 102), (133, 60)], color: bodyColor, width: 9)
                bar(133, 56)
            case "squat", "lunge":
                head(145, 48)
                line([(141, 69), (128, 115), (164, 139), (147, 182), (173, 182)], color: bodyColor, width: 12)
                line([(128, 115), (94, 142), (93, 182), (72, 182)], color: bodyColor.opacity(0.55), width: 10)
                if kind == "squat" {
                    line([(138, 76), (111, 86), (102, 63)], color: bodyColor, width: 8)
                    bar(145, 69)
                } else {
                    line([(137, 76), (162, 104), (164, 124)], color: bodyColor, width: 8)
                    bar(165, 133, span: 34)
                }
            case "deadlift":
                head(182, 67)
                line([(165, 80), (119, 116), (131, 150), (117, 183), (139, 183)], color: bodyColor, width: 12)
                line([(119, 116), (101, 150), (88, 183), (108, 183)], color: bodyColor.opacity(0.55), width: 10)
                line([(164, 85), (181, 116), (180, 150)], color: bodyColor, width: 8)
                bar(181, 155)
            case "row":
                head(123, 63)
                line([(123, 84), (130, 135), (186, 139), (213, 177)], color: bodyColor, width: 12)
                line([(130, 135), (94, 151), (75, 177)], color: bodyColor.opacity(0.55), width: 10)
                line([(124, 91), (151, 110), (177, 99)], color: bodyColor, width: 8)
                line([(177, 99), (269, 99), (269, 180)], color: .gymLime, width: 3)
                line([(98, 150), (150, 150)], color: equipment, width: 7)
                bar(181, 99, span: 25)
            case "pulldown", "pullup":
                line([(60, 181), (60, 26), (240, 26), (240, 181)], color: equipment, width: 5)
                head(150, 75)
                line([(150, 96), (150, 140), (121, 176)], color: bodyColor, width: 12)
                line([(150, 140), (180, 176)], color: bodyColor, width: 10)
                line([(146, 101), (116, 88), (103, 43)], color: bodyColor, width: 8)
                line([(155, 101), (184, 88), (197, 43)], color: bodyColor, width: 8)
                bar(150, 39, span: 128)
                if kind == "pulldown" { line([(113, 147), (184, 147)], color: equipment, width: 7) }
            case "press", "fly":
                head(150, 62)
                line([(150, 83), (150, 131), (122, 180)], color: bodyColor, width: 12)
                line([(150, 131), (181, 180)], color: bodyColor, width: 10)
                if kind == "press" {
                    line([(142, 91), (108, 79), (108, 41)], color: bodyColor, width: 8)
                    line([(158, 91), (192, 79), (192, 41)], color: bodyColor, width: 8)
                    bar(108, 35, span: 40); bar(192, 35, span: 40)
                    line([(122, 141), (182, 141)], color: equipment, width: 6)
                } else {
                    line([(141, 93), (97, 98), (62, 87)], color: bodyColor, width: 8)
                    line([(159, 93), (203, 98), (238, 87)], color: bodyColor, width: 8)
                    bar(60, 82, span: 32); bar(240, 82, span: 32)
                }
            case "legpress":
                line([(54, 89), (95, 151), (144, 151)], color: equipment, width: 12)
                head(72, 84)
                line([(87, 101), (116, 135), (158, 107), (202, 125)], color: bodyColor, width: 12)
                line([(91, 108), (90, 142)], color: bodyColor, width: 8)
                line([(184, 147), (223, 74)], color: .gymLime, width: 10)
                line([(218, 87), (260, 43)], color: equipment, width: 5)
            default:
                head(150, 51)
                line([(150, 74), (150, 126), (126, 181)], color: bodyColor, width: 12)
                line([(150, 126), (177, 181)], color: bodyColor, width: 10)
                line([(141, 85), (116, 113), (107, 86)], color: bodyColor, width: 8)
                line([(159, 85), (184, 113), (193, 86)], color: bodyColor, width: 8)
                bar(105, 80, span: 36); bar(195, 80, span: 36)
            }
        }
        .accessibilityLabel("Иллюстрация упражнения")
    }
}
