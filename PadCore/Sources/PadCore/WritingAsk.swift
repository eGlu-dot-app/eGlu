/// How the writing question shows, once (task 05). A person being welcomed
/// is asked on the welcome's Writing step; anybody else is asked by the
/// small sheet. `asked` is the "writingAsked" flag, set the moment either
/// button is pressed, so the question never comes back.
public enum WritingAsk {
    /// The welcome's own step asks, as part of the setup.
    case welcomeStep
    /// The small sheet asks, on its own.
    case sheet
    /// Asked already: nothing shows.
    case nothing

    public static func decision(welcomePending: Bool, asked: Bool, setupSkipped: Bool = false) -> WritingAsk {
        asked || setupSkipped ? .nothing : welcomePending ? .welcomeStep : .sheet
    }
}
