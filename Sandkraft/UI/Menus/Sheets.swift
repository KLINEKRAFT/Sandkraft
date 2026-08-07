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
    case mould, adornment, look, beaches, settings, fieldNotes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mould:      return "Moulds"
        case .adornment:  return "Adornments"
        case .look:       return "Looks"
        case .beaches:    return "Beaches"
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
                case .beaches:    BeachesView(model: model)
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
        .skSheetChrome(large: which == .settings || which == .fieldNotes || which == .beaches)
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
                    .font(.skProse(12))
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
                    .font(Typeface.font(13, .regular))
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
                    .font(.skProse(12))
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
                    .font(.skProse(12))
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
                                    .font(.skDisplay(14, weight: .medium))
                                Text(look.note)
                                    .font(.skProse(11))
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
    @State private var confirmingReset = false
    /// Its own, rather than the one `PlaySheetContent` holds: `dismiss` reaches
    /// the nearest presentation, and this view needs to close the sheet it is
    /// inside from a button halfway down a Form.
    @Environment(\.dismiss) private var dismiss
    // One computed property per section, for the same reason `PlayView.body` is
    // built in stages: Swift type-checks a whole expression at once, against a
    // wall-clock budget, and a `Form` holding nine sections of bindings,
    // ternaries and interpolated strings is one expression. This screen went
    // from six sections to nine in a single commit and was heading the same way
    // PlayView already went — failing to compile on a slower machine while
    // passing on a faster one.
    //
    // Nine children is also exactly at `ViewBuilder`'s ten-child limit. A tenth
    // section wants a `Group`, not a squeeze.

    var body: some View {
        Form {
            // Two `Group`s rather than ten bare sections. `ViewBuilder` takes at
            // most ten children and this reached exactly ten the moment Controls
            // was added — which is a compile error waiting for the eleventh
            // idea, not a limit to sit on.
            Group {
                daySection
                feelSection
                controlsSection
                performanceSection
                draftingSection
            }
            Group {
                seaSection
                cameraSection
                beachSection
                storedSection
                aboutSection
            }
        }
        .confirmationDialog("Reset settings and progress?",
                            isPresented: $confirmingReset,
                            titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                Preferences.reset()
                // The autosaved beach goes with it. "A clean slate" that leaves
                // the last castle sitting behind Continue is not one, and this
                // is the only button in the app that offers to throw work away.
                BeachStore.clear()
                // The model has to be put back too. It is the source the save
                // reads from, so clearing only the store would see every old
                // value written straight back on the next change.
                model.apply(StoredPreferences())
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("""
                 Every setting goes back to its default and the campaign locks \
                 back to the first tide. Quality is left as it is, because \
                 changing it lays down a fresh beach.
                 """)
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }

    private var daySection: some View {
        Section("The day") {
            Picker("Clock", selection: $model.daySpeed) {
                ForEach(DaySpeed.allCases) { speed in
                    Text(speed.title).tag(speed)
                }
            }
            Text(model.daySpeed.subtitle)
                .font(.skCaption)
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
    }

    private var feelSection: some View {
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
    }

    /// Every button and key, in the place people look for them.
    ///
    /// The same list has been in Field Notes since the first build, which is a
    /// perfectly good place for it and completely the wrong *only* place: Field
    /// Notes reads as lore, and nobody hunting for "how do I orbit" opens the
    /// essay about capillary bridges. It is one view, shown from both.
    private var controlsSection: some View {
        Section("Controls") {
            NavigationLink("Every button and key") {
                ControlsReference()
                    .navigationTitle("Controls")
            }
            Text("""
                 The full list — pointer, touch, and every keyboard shortcut. \
                 Also in Field Notes, which is where it used to hide.
                 """)
                .font(.skCaption)
                .foregroundStyle(Palette.secondaryText)
        }
    }

    private var performanceSection: some View {
        Section("Performance") {
            Picker("Quality", selection: $model.qualityTier) {
                ForEach(QualityTier.allCases) { tier in
                    Text(tier.title).tag(tier)
                }
            }
            Text(model.qualityTier.note)
                .font(.skCaption)
                .foregroundStyle(Palette.secondaryText)
            LabeledContent("Approximate memory",
                           value: "\(model.qualityTier.approximateMemoryMB) MB")
                .font(.skCaption)
            LabeledContent("Beach mesh", value: model.qualityTier.meshDescription)
                .font(.skCaption)
            Text("""
                 Changing quality rebuilds the simulation, which means laying \
                 down a fresh beach. Finish what you are working on first.
                 """)
                .font(.skCaption)
                .foregroundStyle(Palette.secondaryText)
        }
    }

    private var draftingSection: some View {
        Section("Drafting") {
            Toggle("Straight strokes", isOn: $model.straightStrokes)
            Text("""
                 Locks a stroke to one of eight directions from wherever it \
                 started, so a wall, a trench or a row of turrets comes out \
                 straight. Also squares a mould to fifteen-degree turns.
                 """)
                .font(.skCaption)
                .foregroundStyle(Palette.secondaryText)

            Toggle("Snap to a grid", isOn: $model.snapToGrid)
            if model.snapToGrid {
                Picker("Spacing", selection: $model.snapSpacing) {
                    // Spelled `as Double` rather than left to inference. The
                    // selection is a `Binding<Double>` and a bare `0.1` would
                    // almost certainly resolve to one — but `tag` is generic over
                    // `Hashable`, so "almost certainly" is the type-checker doing
                    // work it does not need to do, four times, in a file that has
                    // already run out of budget once.
                    Text("10 cm").tag(0.1 as Double)
                    Text("25 cm").tag(0.25 as Double)
                    Text("50 cm").tag(0.5 as Double)
                    Text("1 m").tag(1.0 as Double)
                }
            }
            Text("""
                 Straight strokes make a wall straight; the grid makes it \
                 land somewhere repeatable, so two walls built five minutes \
                 apart line up. Both are off by default — sand slumps, and \
                 most of the time that is the point.
                 """)
                .font(.skCaption)
                .foregroundStyle(Palette.secondaryText)
        }
    }

    private var seaSection: some View {
        Section("The sea") {
            // The label is the number, not the fraction. "0.85" means nothing;
            // "most of the swell this tide asks for" is what the slider does.
            LabeledContent("Surf", value: "\(Int(model.surf * 100))%")
            Slider(value: $model.surf, in: 0...1.5, step: 0.05)
                .accessibilityLabel("Surf")
                .accessibilityValue("\(Int(model.surf * 100)) percent")
            Text("""
                 Scales every wave, on top of whatever the tide asks for. \
                 The water you see is the water that erodes, so turning this \
                 down really does make a calmer beach rather than a beach \
                 that lies about what the sea is doing to it. At zero the \
                 sea is glass and nothing is taken away.
                 """)
                .font(.skCaption)
                .foregroundStyle(Palette.secondaryText)
        }
    }

    private var cameraSection: some View {
        Section("Camera") {
            Toggle("Invert orbit — left and right", isOn: $model.invertOrbitX)
            Toggle("Invert orbit — up and down", isOn: $model.invertOrbitY)
            Toggle("Invert zoom", isOn: $model.invertZoom)
            Text("""
                 Which way a drag turns the world is not a thing with a \
                 right answer, and the answer is often different on a \
                 trackpad and a mouse. Try them.
                 """)
                .font(.skCaption)
                .foregroundStyle(Palette.secondaryText)
        }
    }

    private var beachSection: some View {
        Section("This beach") {
            // A push rather than a second sheet. `BeachesView` is reached from
            // here and from ⌘O, and presenting a sheet from inside a sheet is
            // the exact shape of bug that made Save do nothing for months.
            NavigationLink("Kept beaches") {
                BeachesView(model: model)
                    .navigationTitle("Beaches")
            }
            Text("""
                 A kept beach holds the sand exactly as it stands, along \
                 with the adornments, the look and the time of day. It \
                 reopens as a sandbox, and only at the quality it was kept \
                 at — the field is a different size at every tier.
                 """)
                .font(.skCaption)
                .foregroundStyle(Palette.secondaryText)
            Text("""
                 The beach in front of you is also kept automatically, every \
                 half minute that something has changed on it, and offered \
                 back as Continue the next time you launch. That slot holds \
                 one beach and it is always the last one — it is a way not to \
                 lose an afternoon, not a way to keep several. Keeping several \
                 is what the shelf above is for.
                 """)
                .font(.skCaption)
                .foregroundStyle(Palette.secondaryText)
        }
    }

    private var storedSection: some View {
        Section("Stored") {
            LabeledContent("Campaign", value: "tide \(model.campaignProgress) unlocked")
                .font(.skCaption)
            Text("""
                 Everything on this screen is remembered between launches, \
                 along with your brush and which tides you have reached.
                 """)
                .font(.skCaption)
                .foregroundStyle(Palette.secondaryText)

            Button("Reset settings and progress", role: .destructive) {
                confirmingReset = true
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Simulation", value: "\(model.qualityTier.simResolution)² heightfield")
            LabeledContent("Solver", value: "\(model.qualityTier.substeps) substeps per frame")
        }
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
                            .font(.skDisplay(17, weight: .medium))
                        Text(note.body)
                            .font(.skProse(13))
                            .lineSpacing(skProseSpacing)
                            .foregroundStyle(Palette.primaryText.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                ControlsReference()
            }
            .padding(Metric.xl)
            .frame(maxWidth: 640, alignment: .leading)
        }
    }
}

// MARK: - Controls

/// Every shortcut and gesture, in the app rather than in a README.
///
/// The tool rows are generated from `Tool.all`, so a tool that changes its key —
/// or a tool that gets added — cannot leave a lie behind on this page. The rest
/// is hand-written because it corresponds to menu items and gesture recognisers
/// that have no single table to read from.
struct ControlsReference: View {
    private struct Row: Identifiable {
        let id = UUID()
        let keys: String
        let what: String
    }

    private struct Block: Identifiable {
        let id = UUID()
        let title: String
        let rows: [Row]
    }

    private var blocks: [Block] {
        var all: [Block] = []

        #if os(macOS)
        all.append(Block(title: "Tools",
                         rows: Tool.all.map { Row(keys: String($0.shortcut), what: $0.name) }))

        all.append(Block(title: "Brush", rows: [
            Row(keys: "]", what: "Bigger — one detent, about 15%"),
            Row(keys: "[", what: "Smaller"),
            Row(keys: "⌘B", what: "Round footprint"),
            Row(keys: "⇧⌘B", what: "Square footprint"),
            Row(keys: "⌘\\", what: "Straight strokes — lock to eight directions"),
            Row(keys: "⌘'", what: "Snap to a grid")
        ]))

        all.append(Block(title: "The beach", rows: [
            Row(keys: "⌘S", what: "Keep this beach — saves over it after the first time"),
            Row(keys: "⌘O", what: "The shelf of kept beaches"),
            Row(keys: "⌘0", what: "Centre the beach"),
            Row(keys: "⇧⌘S", what: "Export this beach to a file"),
            Row(keys: "⌥⌘O", what: "Import a beach from a file"),
            Row(keys: "⇧⌘P", what: "Photograph the frame as it stands"),
            Row(keys: "Space", what: "Pause"),
            Row(keys: "⇧⌘R", what: "Reset the beach"),
            Row(keys: "⇧⌘H", what: "Hide the controls — the beach, and nothing else"),
            Row(keys: "⌘L", what: "Next look"),
            Row(keys: "⇧⌘L", what: "Previous look")
        ]))

        all.append(Block(title: "App", rows: [
            Row(keys: "⌘Z", what: "Undo"),
            Row(keys: "⇧⌘Z", what: "Redo"),
            Row(keys: "⌘,", what: "Settings"),
            Row(keys: "⌘/", what: "This page"),
            Row(keys: "Return", what: "The accented button — Begin, or Next tide")
        ]))

        all.append(Block(title: "Pointer", rows: [
            Row(keys: "Drag", what: "Use the selected tool"),
            Row(keys: "⌥ drag", what: "Orbit the camera"),
            Row(keys: "Right drag", what: "Orbit — the same thing, for a mouse"),
            Row(keys: "Scroll", what: "Pan"),
            Row(keys: "⇧ scroll", what: "Orbit"),
            Row(keys: "⌘ scroll", what: "Move closer or further away"),
            Row(keys: "Pinch", what: "Move closer or further away"),
            Row(keys: "Rotate", what: "Turn the mould under the cursor")
        ]))
        #else
        all.append(Block(title: "Touch", rows: [
            Row(keys: "Drag", what: "Use the selected tool"),
            Row(keys: "Two fingers", what: "Pan and orbit the camera"),
            Row(keys: "Pinch", what: "Move closer or further away"),
            Row(keys: "Rotate", what: "Turn the mould under your finger")
        ]))
        #endif

        return all
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.l) {
            Text("Controls")
                .font(.skDisplay(17, weight: .medium))

            ForEach(blocks) { block in
                VStack(alignment: .leading, spacing: Metric.s) {
                    Text(block.title).skLabelStyle()

                    ForEach(block.rows) { row in
                        HStack(alignment: .top, spacing: Metric.m) {
                            Text(row.keys)
                                .font(.skNumeric(12, weight: .medium))
                                .frame(width: 84, alignment: .leading)
                            Text(row.what)
                                .font(.skProse(12))
                                .foregroundStyle(Palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}
