import SwiftUI

/// Placeholder device selection sheet. Will list real devices once the app
/// talks to the relay; for now it shows the single hardcoded lamp.
struct DevicePickerView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text("Bedroom")
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: "checkmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
            }
            .navigationTitle("Devices")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    DevicePickerView()
        .preferredColorScheme(.dark)
}
