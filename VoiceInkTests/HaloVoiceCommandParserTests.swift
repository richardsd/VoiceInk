import Testing
@testable import VoiceInk

struct HaloVoiceCommandParserTests {
    @Test(
        "Recognizes every exact Halo command",
        arguments: [
            ("Halo apply", HaloVoiceCommand.apply),
            ("Halo copy", HaloVoiceCommand.copy),
            ("Halo cancel", HaloVoiceCommand.cancel),
            ("Halo show final", HaloVoiceCommand.showLens(.final)),
            ("Halo show changes", HaloVoiceCommand.showLens(.changes)),
            ("Halo show original", HaloVoiceCommand.showLens(.original)),
            ("Halo previous version", HaloVoiceCommand.previousRevision),
            ("Halo next version", HaloVoiceCommand.nextRevision),
        ]
    )
    func recognizesExactGrammar(input: String, expected: HaloVoiceCommand) {
        #expect(HaloVoiceCommandParser.parse(input) == expected)
    }

    @Test(
        "Normalizes case, repeated whitespace, and permitted terminal punctuation",
        arguments: [
            ("halo APPLY", HaloVoiceCommand.apply),
            ("  HALO   copy  ", HaloVoiceCommand.copy),
            ("\nHalo\tshow\nchanges\r", HaloVoiceCommand.showLens(.changes)),
            ("Halo show original.", HaloVoiceCommand.showLens(.original)),
            ("Halo previous version!", HaloVoiceCommand.previousRevision),
            ("Halo next version?", HaloVoiceCommand.nextRevision),
            ("Halo apply…", HaloVoiceCommand.apply),
            ("Halo cancel?!", HaloVoiceCommand.cancel),
            ("Halo show final .  ", HaloVoiceCommand.showLens(.final)),
        ]
    )
    func recognizesNormalizedGrammar(input: String, expected: HaloVoiceCommand) {
        #expect(HaloVoiceCommandParser.parse(input) == expected)
    }

    @Test(
        "Rejects missing prefixes, partials, near matches, and extra words",
        arguments: [
            "",
            "Halo",
            "apply",
            "Halo app",
            "Halo copie",
            "Halo please apply",
            "Hey Halo apply",
            "Halo apply now",
            "Halo show",
            "Halo show change",
            "Halo final",
            "Halo previous",
            "Halo previous revision",
            "Halo next versions",
            "Halos apply",
            "Halo, apply",
            "Halo apply,",
            "Halo apply:",
            "Halo apply;",
            "Halo apply. now",
        ]
    )
    func rejectsAnythingOutsideExactGrammar(input: String) {
        #expect(HaloVoiceCommandParser.parse(input) == nil)
    }
}
