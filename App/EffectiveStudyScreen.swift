import Foundation

/// A UI-independent description of what is actually in the foreground.
/// It is not a learning engine and does not modify any study records.
struct EffectiveStudyScreen: Equatable {
    enum Tab: Equatable { case home, vocabulary, publicQuestions, professional, math, records, other }

    var foreground = false
    var tab: Tab = .home
    var globalBlocked = false

    var vocabularyVisible = false
    var vocabularyPaused = false
    var vocabularyBlocked = false

    var publicVisible = false
    var publicPaused = false
    var publicBlocked = false

    var professionalArea: EffectiveStudyArea?
    var professionalVisible = false
    var professionalPaused = false
    var professionalLearningOverlay = false
    var professionalBlocked = false

    var mathVisible = false
    var mathBlocked = false

    /// The mathematics overview itself is navigation; a question or a
    /// presented knowledge card is study content, even in a sheet.
    static func mathContentIsVisible(tabVisible: Bool, courseOverview: Bool,
                                     questionAvailable: Bool, guideAvailable: Bool,
                                     knowledgeCardVisible: Bool, blocked: Bool) -> Bool {
        tabVisible && !blocked && (knowledgeCardVisible || (!courseOverview && questionAvailable && guideAvailable))
    }

    /// Home and records do not accrue time. A recent home-screen tap may still
    /// start a study page when it actually becomes visible.
    var area: EffectiveStudyArea? {
        guard foreground, !globalBlocked else { return nil }
        switch tab {
        case .vocabulary:
            return vocabularyVisible && !vocabularyPaused && !vocabularyBlocked ? .vocabulary : nil
        case .publicQuestions:
            return publicVisible && !publicPaused && !publicBlocked ? .publicQuestions : nil
        case .professional:
            guard !professionalBlocked, let professionalArea,
                  [.computer, .power, .circuit, .mechanics].contains(professionalArea) else { return nil }
            if professionalLearningOverlay { return professionalArea }
            return professionalVisible && !professionalPaused ? professionalArea : nil
        case .math:
            return mathVisible && !mathBlocked ? .math : nil
        case .home, .records, .other:
            return nil
        }
    }

    /// Touches on ordinary navigation screens can initiate a subsequent page;
    /// touches in file pickers, alerts and the break sheet cannot.
    var acceptsInteraction: Bool {
        guard foreground, !globalBlocked else { return false }
        switch tab {
        case .vocabulary: return !vocabularyBlocked
        case .publicQuestions: return !publicBlocked
        case .professional: return !professionalBlocked
        case .math: return !mathBlocked
        case .home, .records, .other: return true
        }
    }
}
