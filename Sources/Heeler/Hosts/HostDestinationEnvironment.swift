import SwiftUI

// Build-only carry of the app-destination environment seam declared on
// feat/redesign-nav (AppRootView.swift, same bytes). This file exists so
// feat/redesign-hosts compiles standalone; Main deletes it at integration
// when the nav branch lands.

extension EnvironmentValues {
    /// The root destination switcher, so any page's toolbar can host the
    /// compact `AppDestinationMenu` without threading a binding through
    /// every initializer (ConsoleView's and HostListView's signatures stay
    /// untouched; both read this instead).
    @Entry var appDestination: Binding<AppDestination>? = nil
}
