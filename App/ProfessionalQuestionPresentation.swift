import Foundation
import StudyCore
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

private struct ProfessionalJSONKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func requireProfessionalKeys(_ decoder: Decoder, _ keys: [String]) throws {
    let container = try decoder.container(keyedBy: ProfessionalJSONKey.self)
    guard Set(container.allKeys.map(\.stringValue)).isSubset(of: Set(keys)) else {
        throw ExamError.invalid("题图存在未知字段，不能忽略后导入。")
    }
}

extension ConceptQuestion {
    /// Stable length-prefixed UTF8; includes all source question fields in source order.
    var professionalDigest: String {
        var values = [id, type.rawValue, prompt, String(options.count)]
        values += options.flatMap { [$0.id, $0.text] }
        values += [String(answer.count)] + answer + [explanation, String(sourceIDs.count)]
        values += sourceIDs + [sourceLocation, verification]
        if let preserveOptionOrder { values += ["preserveOptionOrder", preserveOptionOrder ? "true" : "false"] }
        return StudySHA256.hex(Data(values.map { String($0.utf8.count) + ":" + $0 }.joined().utf8))
    }
}

struct ProfessionalNormalizedCrop: Codable, Equatable {
    let x: Double; let y: Double; let width: Double; let height: Double
    func validate() throws {
        guard [x,y,width,height].allSatisfy(\.isFinite), x >= 0, y >= 0,
              width > 0, height > 0, x + width <= 1, y + height <= 1 else {
            throw ExamError.invalid("题图裁区必须在完整图像范围内。")
        }
    }
    enum CodingKeys: String, CodingKey { case x,y,width,height }
    init(x: Double, y: Double, width: Double, height: Double) {
        self.x=x; self.y=y; self.width=width; self.height=height
    }
    init(from decoder: Decoder) throws {
        try requireProfessionalKeys(decoder, ["x","y","width","height"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x=try c.decode(Double.self,forKey:.x); y=try c.decode(Double.self,forKey:.y)
        width=try c.decode(Double.self,forKey:.width); height=try c.decode(Double.self,forKey:.height)
    }
}

struct ProfessionalRasterAsset: Codable, Equatable {
    let mimeType: String
    let bytes: Data
    let sha256: String
    let pixelWidth: Int
    let pixelHeight: Int
    let crop: ProfessionalNormalizedCrop
    let altText: String
    enum CodingKeys: String, CodingKey { case mimeType,bytes,sha256,pixelWidth,pixelHeight,crop,altText }
    init(mimeType: String, bytes: Data, sha256: String, pixelWidth: Int, pixelHeight: Int,
         crop: ProfessionalNormalizedCrop, altText: String) {
        self.mimeType=mimeType; self.bytes=bytes; self.sha256=sha256
        self.pixelWidth=pixelWidth; self.pixelHeight=pixelHeight; self.crop=crop; self.altText=altText
    }
    init(from decoder: Decoder) throws {
        try requireProfessionalKeys(decoder,["mimeType","bytes","sha256","pixelWidth","pixelHeight","crop","altText"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        mimeType=try c.decode(String.self,forKey:.mimeType); bytes=try c.decode(Data.self,forKey:.bytes)
        sha256=try c.decode(String.self,forKey:.sha256); pixelWidth=try c.decode(Int.self,forKey:.pixelWidth)
        pixelHeight=try c.decode(Int.self,forKey:.pixelHeight); crop=try c.decode(ProfessionalNormalizedCrop.self,forKey:.crop)
        altText=try c.decode(String.self,forKey:.altText)
    }
    private func validateBounds() throws {
        guard ["image/png","image/jpeg"].contains(mimeType), (1...4*1_024*1_024).contains(bytes.count),
              ExamContent.isHash(sha256), StudySHA256.hex(bytes)==sha256,
              (1...8192).contains(pixelWidth), (1...8192).contains(pixelHeight),
              pixelWidth * pixelHeight <= 20_000_000,
              !altText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, altText.count<=1000 else {
            throw ExamError.invalid("题图格式、字节校验、尺寸或替代说明无效。")
        }
        try crop.validate()
        let prefix = Array(bytes.prefix(8))
        guard (mimeType == "image/png" && prefix == [137,80,78,71,13,10,26,10]) ||
              (mimeType == "image/jpeg" && prefix.starts(with:[255,216,255])) else {
            throw ExamError.invalid("题图实际格式与声明不一致。")
        }
    }
    func validate() throws {
        try validateBounds()
        #if canImport(ImageIO)
        _ = try decodedCGImage()
        #else
        throw ExamError.invalid("当前平台不能实际解码题图，拒绝导入。")
        #endif
    }
    #if canImport(ImageIO)
    func decodedCGImage() throws -> CGImage {
        try validateBounds()
        guard let source=CGImageSourceCreateWithData(bytes as CFData,nil), CGImageSourceGetCount(source)==1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let type=CGImageSourceGetType(source) as String?,
              type == (mimeType == "image/png" ? "public.png" : "public.jpeg"),
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let w=properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let h=properties[kCGImagePropertyPixelHeight] as? NSNumber,
              w.intValue==pixelWidth, h.intValue==pixelHeight,
              let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary),
              image.width==pixelWidth, image.height==pixelHeight,
              CGImageSourceGetStatusAtIndex(source,0) == .statusComplete else {
            throw ExamError.invalid("题图不能完整解码或实际像素与声明不一致。")
        }
        // Crop coordinates bind to original pixels; reject orientation transformations.
        if let orientation=properties[kCGImagePropertyOrientation] as? NSNumber, orientation.intValue != 1 {
            throw ExamError.invalid("题图须先归一方向，不能隐式改变裁区。")
        }
        return image
    }
    func croppedCGImage() throws -> CGImage {
        let image=try decodedCGImage()
        let rect=CGRect(x:crop.x*Double(pixelWidth),y:crop.y*Double(pixelHeight),
                        width:crop.width*Double(pixelWidth),height:crop.height*Double(pixelHeight)).integral
        guard let result=image.cropping(to:rect),result.width>0,result.height>0 else {
            throw ExamError.invalid("题图裁剪失败。")
        }
        return result
    }
    #endif
}

/// Metadata-only reference: no caller-supplied path or URL, and no I/O during course validation.
struct ProfessionalSourceFileAsset: Codable, Equatable {
    let sha256: String
    let mimeType: String
    let byteCount: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let crop: ProfessionalNormalizedCrop
    let altText: String
    func validateMetadata() throws {
        guard ExamContent.isHash(sha256), ["image/png","image/jpeg"].contains(mimeType),
              (1...4*1_024*1_024).contains(byteCount), (1...8192).contains(pixelWidth),
              (1...8192).contains(pixelHeight), pixelWidth*pixelHeight<=20_000_000,
              !altText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,altText.count<=1000 else {
            throw ExamError.invalid("原图文件元数据无效。")
        }
        try crop.validate()
    }
    private func raster(assetRoot: URL?) throws -> ProfessionalRasterAsset {
        try validateMetadata()
        let root:URL
        if let assetRoot { root=assetRoot }
        else {
            guard let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first else {
                throw ExamError.invalid("无法定位原图目录。")
            }
            root=documents.appendingPathComponent("ProfessionalSourceAssets",isDirectory:true)
        }
        let file=root.appendingPathComponent(sha256+(mimeType=="image/jpeg" ? ".jpg" : ".png"))
        guard root.isFileURL,FileManager.default.fileExists(atPath:file.path) else {
            throw ExamError.invalid("尚未复制原图，请先导入专业课原图资产。")
        }
        let rootInfo=try root.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        let info=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard rootInfo.isDirectory==true,rootInfo.isSymbolicLink != true,
              info.isRegularFile==true,info.isSymbolicLink != true,info.fileSize==byteCount,
              file.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw ExamError.invalid("原图文件类型、位置或长度无效。")
        }
        let bytes=try Data(contentsOf:file,options:[])
        guard bytes.count==byteCount,StudySHA256.hex(bytes)==sha256 else { throw ExamError.invalid("原图文件校验失败。") }
        return ProfessionalRasterAsset(mimeType:mimeType,bytes:bytes,sha256:sha256,pixelWidth:pixelWidth,
            pixelHeight:pixelHeight,crop:crop,altText:altText)
    }
    #if canImport(ImageIO)
    func croppedCGImage(assetRoot: URL? = nil) throws -> CGImage { try raster(assetRoot:assetRoot).croppedCGImage() }
    func decodedCGImage(assetRoot: URL? = nil) throws -> CGImage { try raster(assetRoot:assetRoot).decodedCGImage() }
    #endif
}
extension ProfessionalSourceFileAsset {
    enum CodingKeys: String,CodingKey { case sha256,mimeType,byteCount,pixelWidth,pixelHeight,crop,altText }
    init(from decoder:Decoder) throws {
        try requireProfessionalKeys(decoder,["sha256","mimeType","byteCount","pixelWidth","pixelHeight","crop","altText"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        sha256=try c.decode(String.self,forKey:.sha256);mimeType=try c.decode(String.self,forKey:.mimeType)
        byteCount=try c.decode(Int.self,forKey:.byteCount);pixelWidth=try c.decode(Int.self,forKey:.pixelWidth)
        pixelHeight=try c.decode(Int.self,forKey:.pixelHeight);crop=try c.decode(ProfessionalNormalizedCrop.self,forKey:.crop)
        altText=try c.decode(String.self,forKey:.altText)
    }
}

enum ProfessionalSourceStatus:String,Codable { case verified="VERIFIED", ambiguous="AMBIGUOUS", unverified="UNVERIFIED" }
enum ProfessionalCourseReadiness:String,Codable {
    case ready="READY", awaitingCard="AWAITING_CARD", awaitingDiagram="AWAITING_DIAGRAM"
    case unsupportedResponseType="UNSUPPORTED_RESPONSE_TYPE", awaitingCanonicalBinding="AWAITING_CANONICAL_BINDING", notApplicable="NOT_APPLICABLE"
}
enum ProfessionalSourceScope:String,Codable {
    case mainline="MAINLINE", relatedFoundation="RELATED_FOUNDATION", legacyOrOutOfScope="LEGACY_OR_OUT_OF_SCOPE"
}

struct ProfessionalQuestionVisual: Codable, Equatable, Identifiable {
    let id: String
    let kind: String
    var diagram: ConceptDiagram? = nil
    var raster: ProfessionalRasterAsset? = nil
    var sourceFile: ProfessionalSourceFileAsset? = nil
    enum CodingKeys: String, CodingKey { case id,kind,diagram,raster,sourceFile }
    init(id: String, kind: String, diagram: ConceptDiagram? = nil, raster: ProfessionalRasterAsset? = nil, sourceFile: ProfessionalSourceFileAsset? = nil) {
        self.id=id; self.kind=kind; self.diagram=diagram; self.raster=raster; self.sourceFile=sourceFile
    }
    init(from decoder: Decoder) throws {
        try requireProfessionalKeys(decoder,["id","kind","diagram","raster","sourceFile"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(String.self,forKey:.id); kind=try c.decode(String.self,forKey:.kind)
        diagram=try c.decodeIfPresent(ConceptDiagram.self,forKey:.diagram)
        raster=try c.decodeIfPresent(ProfessionalRasterAsset.self,forKey:.raster)
        sourceFile=try c.decodeIfPresent(ProfessionalSourceFileAsset.self,forKey:.sourceFile)
    }
    func validate() throws {
        guard !id.isEmpty,id.count<=160 else { throw ExamError.invalid("题图标识无效。") }
        switch kind {
        case "vector":
            guard let diagram,raster==nil,sourceFile==nil else { throw ExamError.invalid("矢量题图载荷不一致。") }
            try diagram.validate()
        case "raster":
            guard let raster,diagram==nil,sourceFile==nil else { throw ExamError.invalid("原始题图载荷不一致。") }
            try raster.validate()
        case "sourceFile":
            guard let sourceFile,diagram==nil,raster==nil else { throw ExamError.invalid("只读源文件题图载荷不一致。") }
            try sourceFile.validateMetadata()
        default: throw ExamError.invalid("不支持的题图类型。")
        }
    }
}

struct ProfessionalQuestionPresentation: Codable, Equatable {
    let questionID: String
    let sourceQuestionDigest: String
    let requiredDiagram: Bool
    let beforeAnswer: [ProfessionalQuestionVisual]
    let afterAnswer: [ProfessionalQuestionVisual]
    var sourceKind: String = "verifiedSource"
    /// Preflight before ANY store write, including rollover of historical attempt volumes.
    static func validatePracticeContent(_ values: [Self], bank: ConceptBank) throws {
        try validateAll(values, bank: bank)
        let activeIDs = Set(bank.concepts.flatMap { bank.activeQuestions(in: $0).map(\.id) })
        guard activeIDs.isSubset(of: Set(values.map(\.questionID))) else {
            throw ExamError.invalid("专业课v5可练题缺少已验证题级呈现，不能启动或评分。")
        }
    }
    static func validateAll(_ values:[Self],bank:ConceptBank) throws {
        let questions=Dictionary(uniqueKeysWithValues:bank.concepts.flatMap(\.questions).map{($0.id,$0)})
        guard values.count<=20_000,Set(values.map(\.questionID)).count==values.count else {
            throw ExamError.invalid("题级排版重复或过多。")
        }
        var total=0
        for v in values {
            let visuals=v.beforeAnswer+v.afterAnswer
            guard let q=questions[v.questionID],q.professionalDigest==v.sourceQuestionDigest,
                  ["existingBank","verifiedSource"].contains(v.sourceKind),
                  v.beforeAnswer.count<=8,v.afterAnswer.count<=8,
                  Set(visuals.map(\.id)).count==visuals.count,
                  !visuals.contains(where:{$0.kind=="sourceFile" || $0.sourceFile != nil}),
                  !v.requiredDiagram || !v.beforeAnswer.isEmpty else {
                throw ExamError.invalid("题级排版绑定失效、缺少作答前必要图或重复图。")
            }
            for visual in visuals { try visual.validate(); total += visual.raster?.bytes.count ?? 0 }
            guard total<=20*1_024*1_024 else { throw ExamError.invalid("题图总字节超过上限。") }
        }
    }
}

struct ProfessionalQuestionLinks: Codable, Equatable {
    let questionID: String
    let sourceQuestionDigest: String
    let primaryCardIDs: [String]
    let supplementCardIDs: [String]
    let guideConceptIDs: [String]
    static func validateAll(_ values:[Self],bank:ConceptBank,teaching:ConceptTeaching) throws {
        let questions=Dictionary(uniqueKeysWithValues:bank.concepts.flatMap(\.questions).map{($0.id,$0)})
        let primary=Set(teaching.primaryRecallDeck?.cards.map(\.id) ?? [])
        let supplement=Set((teaching.recallGroups ?? []).flatMap(\.recallCards).map(\.id))
        let guides=Set(teaching.lessons.filter{$0.guide != nil}.map(\.conceptID))
        guard values.count<=20_000,Set(values.map(\.questionID)).count==values.count else {
            throw ExamError.invalid("题目知识卡关联重复或过多。")
        }
        for v in values {
            guard let q=questions[v.questionID],q.professionalDigest==v.sourceQuestionDigest else {
                throw ExamError.invalid("题目知识卡关联未绑定当前原题。")
            }
            try validateProfessionalReferences(v.primaryCardIDs,allowed:primary)
            try validateProfessionalReferences(v.supplementCardIDs,allowed:supplement)
            try validateProfessionalReferences(v.guideConceptIDs,allowed:guides)
        }
    }
}

private func validateProfessionalReferences(_ ids:[String],allowed:Set<String>) throws {
    guard ids.count<=12, Set(ids).count==ids.count, Set(ids).isSubset(of:allowed) else {
        throw ExamError.invalid("题目关联了未知、重复或过多的知识卡。")
    }
}

/// A source image is never a scorable bank question merely because it can be read.
struct ProfessionalSourceLeaf: Codable, Equatable, Identifiable {
    let sourceQuestionID: String
    let sourceID: String
    let page: Int
    let label: String
    let status: String
    var bankQuestionID: String? = nil
    let visual: ProfessionalQuestionVisual
    let primaryCardIDs: [String]
    let supplementCardIDs: [String]
    var sourceStatus: ProfessionalSourceStatus = .unverified
    var courseReadiness: ProfessionalCourseReadiness = .awaitingCanonicalBinding
    var scope: ProfessionalSourceScope = .mainline
    var reason: String = "尚未完成源题与课程绑定核验。"
    var additionalVisuals: [ProfessionalQuestionVisual] = []
    var allVisuals: [ProfessionalQuestionVisual] { [visual] + additionalVisuals }
    var id:String { sourceQuestionID }
    static func validateAll(_ values:[Self],bank:ConceptBank,teaching:ConceptTeaching) throws {
        let sourceIDs=Set(bank.sources.map(\.id))
        let primary=Set(teaching.primaryRecallDeck?.cards.map(\.id) ?? [])
        let supplement=Set((teaching.recallGroups ?? []).flatMap(\.recallCards).map(\.id))
        let presentIDs=Set((teaching.questionPresentations ?? []).map(\.questionID))
        let questions=Dictionary(uniqueKeysWithValues:bank.concepts.flatMap(\.questions).map{($0.id,$0)})
        guard values.count<=20_000, Set(values.map(\.id)).count==values.count else {
            throw ExamError.invalid("原题图索引重复或过多。")
        }
        var total=0,uniqueFileBytes=0
        var fileIdentities:[String:String]=[:]
        for v in values {
            guard !v.sourceQuestionID.isEmpty,v.sourceQuestionID.count<=200,sourceIDs.contains(v.sourceID),
                  (1...100_000).contains(v.page),!v.label.isEmpty,v.label.count<=300,
                  ["pending","verified"].contains(v.status),
                  !v.reason.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,v.reason.count<=2000,
                  v.allVisuals.count<=5,Set(v.allVisuals.map(\.id)).count==v.allVisuals.count,
                  v.status != "verified" || (v.sourceStatus == .verified && v.courseReadiness == .ready),
                  (v.status == "pending" && v.bankQuestionID == nil) ||
                    (v.status == "verified" && v.bankQuestionID.map{presentIDs.contains($0) && (questions[$0]?.sourceIDs.contains(v.sourceID) ?? false)} == true) else {
                throw ExamError.invalid("原题图索引状态、题源或已核题关联无效。")
            }
            for visual in v.allVisuals { try visual.validate() }
            try validateProfessionalReferences(v.primaryCardIDs,allowed:primary)
            try validateProfessionalReferences(v.supplementCardIDs,allowed:supplement)
            for visual in v.allVisuals {
                total += visual.raster?.bytes.count ?? 0
                guard total<=20*1_024*1_024 else { throw ExamError.invalid("原题图索引内嵌字节超过上限。") }
                if let file=visual.sourceFile {
                    let identity="\(file.mimeType)/\(file.byteCount)/\(file.pixelWidth)/\(file.pixelHeight)"
                    if let previous=fileIdentities[file.sha256] {
                        guard previous==identity else { throw ExamError.invalid("同一原图hash的元数据互相冲突。") }
                    } else {
                        fileIdentities[file.sha256]=identity;uniqueFileBytes += file.byteCount
                    }
                    guard uniqueFileBytes<=128*1_024*1_024 else { throw ExamError.invalid("只读源图唯一文件总字节超过上限。") }
                }
            }
        }
    }
}

extension ProfessionalQuestionPresentation {
    enum CodingKeys: String, CodingKey { case questionID,sourceQuestionDigest,requiredDiagram,beforeAnswer,afterAnswer,sourceKind }
    init(from decoder: Decoder) throws {
        try requireProfessionalKeys(decoder,["questionID","sourceQuestionDigest","requiredDiagram","beforeAnswer","afterAnswer","sourceKind"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        questionID=try c.decode(String.self,forKey:.questionID)
        sourceQuestionDigest=try c.decode(String.self,forKey:.sourceQuestionDigest)
        requiredDiagram=try c.decode(Bool.self,forKey:.requiredDiagram)
        beforeAnswer=try c.decode([ProfessionalQuestionVisual].self,forKey:.beforeAnswer)
        afterAnswer=try c.decode([ProfessionalQuestionVisual].self,forKey:.afterAnswer)
        sourceKind=try c.decode(String.self,forKey:.sourceKind)
    }
}
extension ProfessionalQuestionLinks {
    enum CodingKeys: String, CodingKey { case questionID,sourceQuestionDigest,primaryCardIDs,supplementCardIDs,guideConceptIDs }
    init(from decoder: Decoder) throws {
        try requireProfessionalKeys(decoder,["questionID","sourceQuestionDigest","primaryCardIDs","supplementCardIDs","guideConceptIDs"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        questionID=try c.decode(String.self,forKey:.questionID)
        sourceQuestionDigest=try c.decode(String.self,forKey:.sourceQuestionDigest)
        primaryCardIDs=try c.decode([String].self,forKey:.primaryCardIDs)
        supplementCardIDs=try c.decode([String].self,forKey:.supplementCardIDs)
        guideConceptIDs=try c.decode([String].self,forKey:.guideConceptIDs)
    }
}
extension ProfessionalSourceLeaf {
    enum CodingKeys: String, CodingKey { case sourceQuestionID,sourceID,page,label,status,bankQuestionID,visual,primaryCardIDs,supplementCardIDs,sourceStatus,courseReadiness,scope,reason,additionalVisuals }
    init(from decoder: Decoder) throws {
        try requireProfessionalKeys(decoder,["sourceQuestionID","sourceID","page","label","status","bankQuestionID","visual","primaryCardIDs","supplementCardIDs","sourceStatus","courseReadiness","scope","reason","additionalVisuals"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        sourceQuestionID=try c.decode(String.self,forKey:.sourceQuestionID)
        sourceID=try c.decode(String.self,forKey:.sourceID);page=try c.decode(Int.self,forKey:.page)
        label=try c.decode(String.self,forKey:.label);status=try c.decode(String.self,forKey:.status)
        bankQuestionID=try c.decodeIfPresent(String.self,forKey:.bankQuestionID)
        visual=try c.decode(ProfessionalQuestionVisual.self,forKey:.visual)
        additionalVisuals=try c.decodeIfPresent([ProfessionalQuestionVisual].self,forKey:.additionalVisuals) ?? []
        sourceStatus=try c.decode(ProfessionalSourceStatus.self,forKey:.sourceStatus)
        courseReadiness=try c.decode(ProfessionalCourseReadiness.self,forKey:.courseReadiness)
        scope=try c.decode(ProfessionalSourceScope.self,forKey:.scope)
        reason=try c.decode(String.self,forKey:.reason)
        primaryCardIDs=try c.decode([String].self,forKey:.primaryCardIDs)
        supplementCardIDs=try c.decode([String].self,forKey:.supplementCardIDs)
    }
}
