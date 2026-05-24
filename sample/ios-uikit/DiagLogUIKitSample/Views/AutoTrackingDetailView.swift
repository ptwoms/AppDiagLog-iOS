import Foundation
import SwiftUI
import AppDiagLog

struct AutoTrackingDetailView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Detail Screen")
                .font(.largeTitle.bold())

            Text("This screen was pushed by UIKit navigation, while SwiftUI renders the content. Entering it updates the current screen so subsequent events are attributed to the detail flow.")
                .foregroundColor(.secondary)

            Text("Navigate back to the root tab to see UIKit `viewDidAppear` set the screen context again.")
                .font(.footnote)
                .foregroundColor(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
        .onAppear {
            AppDiagLog.setCurrentScreen("DetailScreen")
        }
    }
}
