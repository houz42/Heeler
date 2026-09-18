/// Saved Host layouts take precedence. Next the saved global default
/// layout, so one choice covers every Host without per-Host editing.
/// Otherwise, import herdr's first two rows and initialize Heeler's third
/// row with the directory. Heeler's default is the silent last resort: it is
/// never shown as a choice and the user never edits it. Whatever the
/// source, the Console receives the three-slot shape without `state_icon`.
enum AgentRowLayoutResolver {
    static func resolve(
        hostLayout: AgentRowLayout?,
        globalLayout: AgentRowLayout?,
        pluginSnapshot: AgentRowLayoutSnapshot?
    ) -> AgentRowLayout {
        if let hostLayout { return hostLayout.normalizedForConsole() }
        if let globalLayout { return globalLayout.normalizedForConsole() }
        return (pluginSnapshot?.layout ?? .heelerDefault).withHeelerRow()
    }
}
