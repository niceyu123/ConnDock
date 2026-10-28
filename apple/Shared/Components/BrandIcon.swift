import SwiftUI

struct BrandIcon: View {
  var size: CGFloat = 24

  var body: some View {
    Image("ConnDockBrand", bundle: .module)
      .resizable()
      .renderingMode(.template)
      .scaledToFit()
      .frame(width: size, height: size)
      .foregroundStyle(.primary)
      .accessibilityHidden(true)
  }
}
