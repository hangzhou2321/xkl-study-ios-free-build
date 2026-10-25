import Foundation

/// Presentation-only sections. Never filters the bank, scheduler, or recorded attempts.
struct ProfessionalSourceSections: Equatable {
    let lectureQuestionIDs: [String]
    let variantQuestionIDs: [String]
    let extensionQuestionIDs: [String]
    let usesLegacyFallback: Bool

    static func make(practiceQuestionIDs: [String], sourceBankQuestionIDs: [String], selectedPlanQuestionIDs: [String]?) -> Self {
        var seen=Set<String>()
        let practice=practiceQuestionIDs.filter { seen.insert($0).inserted }
        guard let selectedPlanQuestionIDs else {
            return Self(lectureQuestionIDs:[],variantQuestionIDs:[],extensionQuestionIDs:practice,usesLegacyFallback:true)
        }
        let original=Set(sourceBankQuestionIDs), selected=Set(selectedPlanQuestionIDs)
        return Self(lectureQuestionIDs:practice.filter { selected.contains($0) && original.contains($0) },
                    variantQuestionIDs:practice.filter { selected.contains($0) && !original.contains($0) },
                    extensionQuestionIDs:practice.filter { !selected.contains($0) },usesLegacyFallback:false)
    }
}
