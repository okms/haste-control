import SwiftUI

/// The macOS 27 SDK declares `@State` as both a property wrapper and a macro.
/// The macro's plugin ships only with Xcode, so with the Command Line Tools
/// toolchain we refer to the property-wrapper type through this alias.
typealias ViewState<Value> = SwiftUI.State<Value>
