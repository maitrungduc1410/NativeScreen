import SwiftUI

/// Segmented control whose selection pill slides to the chosen segment. Looks like the system one (accent pill,
/// hairline dividers between unselected neighbours), but AppKit's segmented control jumps instead of sliding.
/// VoiceOver sees a standard segmented `Picker` through `accessibilityRepresentation`. Reduce Motion: no slide.
struct SlidingSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    /// Values and their titles (already translated).
    let options: [(value: Value, title: String)]

    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                segment(at: index)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityRepresentation {
            Picker("", selection: $selection) {
                ForEach(options.indices, id: \.self) { index in
                    Text(verbatim: options[index].title).tag(options[index].value)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private func segment(at index: Int) -> some View {
        let option = options[index]
        let isSelected = option.value == selection
        let nextIsSelected = index + 1 < options.count && options[index + 1].value == selection

        Text(verbatim: option.title)
            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minWidth: 44, minHeight: 24)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor)
                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                        .matchedGeometryEffect(id: "selection", in: namespace)
                }
            }
            .overlay(alignment: .trailing) {
                // Hairline between two unselected segments, as in the system control.
                if index + 1 < options.count {
                    Rectangle()
                        .fill(Color.primary.opacity(isSelected || nextIsSelected ? 0 : 0.18))
                        .frame(width: 1, height: 13)
                        .offset(x: 0.5)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard isEnabled, !isSelected else { return }
                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82)) {
                    selection = option.value
                }
            }
    }
}
