//
//  Sheets.swift
//  Sandkraft
//
//  Everything that is not on screen all the time.
//
//  The rule for what earns a sheet rather than a permanent control: if you touch
//  it more than once a minute it belongs in the rail, and if you touch it less
//  than once a session it belongs in Settings. Everything in between is here.
//

import SwiftUI

// MARK: - Routing

enum PlaySheet: String, Identifiable {
    case mould, adornment, look, settings, fieldNotes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mould:      return "Moulds"
        case .adornment:  return "Adornments"
        case .look:       return "Looks"
        case .settings:   return "Settings"
        case .fieldNotes: return "Field Notes"
        }
    }
}

extension View {
    /// Platform-appropriate sheet chrome. iPhone gets detents and a grabber;
    /// the Mac gets a sensibly-sized panel, because a Mac sheet that can be
    /// dragged to half height is a Mac sheet somebody has ported badly.
    @ViewBuilder
    func skSheetChrome(large: Bool = false) -> some View {
        #if os(iOS)
        if large {
            self.presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
        } else {
            self.presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
        }
        #else
        self.frame(minWidth: 460, idealWidth: 520, minHeight: large ? 620 : 480)
        #endif
    }
}

struct PlaySheetContent: View {
    let which: PlaySheet
    @Bindable var model: GameModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch which {
                case .mould:      MouldPicker(model: model)
                case .adornment:  AdornmentPicker(model: model)
                case .look:       LookPicker(model: model)
                case .settings:   SettingsView(model: model)
                case .fieldNotes: FieldNotesView()
                }
            }
            .navigationTitle(which.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .skSheetChrome(large: which == .settings || which == .fieldNotes)
    }
}

// MARK: - Grid helper

private let pickerColumns = [GridItem(.adaptive(minimum: 96), spacing: Metric.s)]

// MARK: - Moulds

struct MouldPicker: View {
    @Bindable var model: GameModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metric.l) {
                Text("""
                     What comes out of a mould is exactly as wet as what went in. \
                     The wetter shapes below need damper sand to survive being \
                     turned out.
                     """)
                    .font(.skSerif(14))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: pickerColumns, spacing: Metric.s) {
                    ForEach(Mould.all) { mould in
                        GlyphChip(glyph: mould.glyph,
                                  title: mould.name,
                                  subtitle: mould.note,
                                  selected: model.selectedMouldID == mould.id) {
                            model.selectedMouldID = mould.id
                            model.selectedToolID = .mould
                        }
                    }
                }

                VStack(alignment: .leading, spacing: Metric.s) {
                    PanelHeading(title: "Needs")
                    HStack {
                        Text("Damp enough to hold")
                        Spacer()
                        Text(Palette.moistureLabel(model.mould.minimumMoisture))
                            .foregroundStyle(Palette.moisture(model.mould.minimumMoisture))
                    }
                    .font(.system(size: 13))
                    MeterBar(value: model.mould.minimumMoisture,
                             tint: Palette.moisture(model.mould.minimumMoisture))
                }
                .padding(Metric.m)
                .background {
                    RoundedRectangle(cornerRadius: Metric.radiusMedium, style: .continuous)
                        .fill(Palette.primaryText.opacity(0.05))
                }
            }
            .padding(Metric.l)
        }
    }
}

// MARK: - Adornments

struct AdornmentPicker: View {
    @Bindable var model: GameModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metric.l) {
                Text("""
                     Adornments are worth nothing at all, and they are the reason \
                     anyone remembers a particular castle. They lean as the sand \
                     moves under them and go over when the water reaches them.
                     """)
                    .font(.skSerif(14))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: pickerColumns, spacing: Metric.s) {
                    ForEach(Adornment.all) { adornment in
                        GlyphChip(glyph: adornment.glyph,
                                  title: adornment.name,
                                  subtitle: adornment.note,
                                  selected: model.selectedAdornmentID == adornment.id) {
                            model.selectedAdornmentID = adornment.id
                            model.selectedToolID = .place
                        }
                    }
                }
            }
            .padding(Metric.l)
        }
    }
}

// MARK: - Looks

struct LookPicker: View {
    @Bindable var model: GameModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metric.m) {
                Text("The same beach, the same light, the same water. Rendered nine ways.")
                    .font(.skSerif(14))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Look.all) { look in
                    Button {
                        model.lookID = look.id
                    } label: {
                        HStack(spacing: Metric.m) {
                            LookSwatch(look: look)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(look.name)
                                    .font(.system(size: 15, weight: .medium))
                                Text(look.note)
                                    .font(.skSerif(13))
                                    .italic()
                                    .foregroundStyle(Palette.secondaryText)
                            }
                            Spacer(minLength: 0)
                            if model.lookID == look.id {
                                Circle().fill(Palette.accent).frame(width: 9, height: 9)
                            }
                        }
                        .padding(Metric.m)
                        .background {
                            RoundedRectangle(cornerRadius: Metric.radiusMedium, style: .continuous)
                                .fill(Palette.primaryText.opacity(model.lookID == look.id ? 0.09 : 0.04))
                        }
                        .contentShape(RoundedRectangle(cornerRadius: Metric.radiusMedium, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.lookID == look.id ? [.isSelected, .isButton] : .isButton)
                }
            }
            .padding(Metric.l)
        }
    }
}

/// A little gradient of the look's own palette. Not a screenshot: a screenshot
/// would have to be captured, shipped and kept in step with the shader, and this
/// is derived from the same numbers the shader uses.
struct LookSwatch: View {
    let look: Look

    var body: some View {
        let sand = Color(red: Double(0.70 * look.sandTint.x),
                         green: Double(0.62 * look.sandTint.y),
                         blue: Double(0.47 * look.sandTint.z))
        let water = Color(red: Double(0.14 * look.waterTint.x),
                          green: Double(0.42 * look.waterTint.y),
                          blue: Double(0.52 * look.waterTint.z))
        let foam = Color(red: Double(look.foamTint.x), green: Double(look.foamTint.y),
                         blue: Double(look.foamTint.z))

        ZStack {
            LinearGradient(colors: [sand, sand.opacity(0.75), water],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 0) {
                Spacer()
                Rectangle().fill(foam.opacity(0.9)).frame(height: 2)
                Rectangle().fill(water).frame(height: 12)
            }
        }
        .frame(width: 54, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: Metric.radiusSmall, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusSmall, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Bindable var model: GameModel

    var body: some View {
        Form {
            Section("The day") {
                Picker("Clock", selection: $model.daySpeed) {
                    ForEach(DaySpeed.allCases) { speed in
                        Text(speed.title).tag(speed)
                    }
                }
                Text(model.daySpeed.subtitle)
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)

                VStack(alignment: .leading) {
                    HStack {
                        Text("Time of day")
                        Spacer()
                        Text(SunPath.clockText(dayFraction: model.dayFraction))
                            .font(.skNumeric(13))
                            .foregroundStyle(Palette.secondaryText)
                    }
                    Slider(value: $model.dayFraction, in: 0...1).tint(Palette.accent)
                }

                VStack(alignment: .leading) {
                    HStack {
                        Text("Cloud")
                        Spacer()
                        Text("\(Int(model.cloudCover * 100))%")
                            .font(.skNumeric(13))
                            .foregroundStyle(Palette.secondaryText)
                    }
                    Slider(value: $model.cloudCover, in: 0...1).tint(Palette.accent)
                }
            }

            Section("Feel") {
                Toggle("Haptics", isOn: $model.hapticsEnabled)
                Toggle("Sound", isOn: $model.soundEnabled)
                Toggle("Advanced readouts", isOn: $model.showAdvancedReadouts)
                if model.showAdvancedReadouts {
                    LabeledContent("Frame time", value: model.frameTimeDescription)
                    LabeledContent("Sand in play", value: String(format: "%.1f m³", model.metrics.totalVolume))
                    LabeledContent("Packed", value: String(format: "%.1f m³", model.metrics.packedVolume))
                    LabeledContent("Wetted", value: String(format: "%.0f m²", model.metrics.wettedArea))
                }
            }

            Section("Performance") {
                Picker("Quality", selection: $model.qualityTier) {
                    ForEach(QualityTier.allCases) { tier in
                        Text(tier.title).tag(tier)
                    }
                }
                Text(model.qualityTier.note)
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
                LabeledContent("Approximate memory",
                               value: "\(model.qualityTier.approximateMemoryMB) MB")
                    .font(.caption)
                LabeledContent("Beach mesh", value: model.qualityTier.meshDescription)
                    .font(.caption)
                Text("""
                     Changing quality rebuilds the simulation, which means laying \
                     down a fresh beach. Finish what you are working on first.
                     """)
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
            }

            Section("About") {
                LabeledContent("Simulation", value: "\(model.qualityTier.simResolution)² heightfield")
                LabeledContent("Solver", value: "\(model.qualityTier.substeps) substeps per frame")
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }
}

// MARK: - Field notes

/// The craft manual. Written as notes from somebody who has done this, because
/// a tutorial that reads like a tutorial gets skipped and a note that reads like
/// experience gets read.
struct FieldNotesView: View {
    struct Note: Identifiable {
        let id = UUID()
        let title: String
        let body: String
    }

    private static let notes: [Note] = [
        Note(title: "Dry sand cannot stand",
             body: """
             Take dry sand between finger and thumb and it will not hold. Add a \
             little water and it becomes, briefly, a solid — not because the water \
             glues it, but because every drop is pulling the grains around it \
             together. Add more water and the drops touch each other and stop \
             pulling. The squeeze goes. The sand runs.

             So: damp, not soaked. There is no way to learn where that line is \
             except by crossing it, which you will, repeatedly, and then one day \
             not.
             """),
        Note(title: "Packing outlives water",
             body: """
             Water is what lets you build a steep face. Packing is what holds it up \
             after the sun has taken the water back, because packing does not \
             evaporate.

             This is why a wall you patted at noon is still standing at dusk and one \
             you only wetted is a heap. Pat everything you intend to keep.
             """),
        Note(title: "The purpose of a moat",
             body: """
             A moat does not stop water. Nothing stops water. A moat spends it.

             A wave arriving at a wall gives that wall all its energy at once. A \
             wave arriving at a ditch first has to fill the ditch, and filling a \
             ditch is work, and the work comes out of the wave. What reaches your \
             wall afterwards is slower, thinner and much stupider.

             The corollary that catches everyone: a moat that drains inland is a \
             delivery service. Cut your outlets seaward.
             """),
        Note(title: "The angle of repose",
             body: """
             Pour dry sand onto a table. It makes a cone. Pour more and it makes a \
             bigger cone with exactly the same sides. You cannot make it steeper. \
             That angle — about thirty-three degrees in this sand — is the sand \
             telling you the only shape it can be.

             Everything you build here is an argument with that angle. Water is one \
             argument. The flat of your hand is another. The sea is the rebuttal.
             """),
        Note(title: "Nothing is knocked down",
             body: """
             The sea does not hit your tower. It takes away a handful at the bottom \
             of your tower, and then the tower is standing on a slope steeper than \
             sand can be, and then it is not standing.

             Which is to say: defend the feet. The top of a sandcastle has never \
             once been the problem.
             """),
        Note(title: "Where the sand comes from",
             body: """
             There is no sand in this bay that you did not take from somewhere else \
             in this bay. Your pail is exactly the hole you dug.

             Beginners dig their borrow pit behind the castle, where it is \
             convenient, and are then surprised when the sea comes up the pit like a \
             stair and takes the castle from behind. Dig where you want a hole. \
             There is always somewhere you want a hole.
             """)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metric.xl) {
                ForEach(Self.notes) { note in
                    VStack(alignment: .leading, spacing: Metric.s) {
                        Text(note.title)
                            .font(.skSerif(19, weight: .semibold))
                        Text(note.body)
                            .font(.skSerif(15))
                            .lineSpacing(3)
                            .foregroundStyle(Palette.primaryText.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Metric.xl)
            .frame(maxWidth: 640, alignment: .leading)
        }
    }
}
