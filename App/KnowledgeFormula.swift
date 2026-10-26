import Foundation

/// A bounded algebra recognizer for audited elementary formula templates.
/// It executes no code and supports no general functions. Unsupported notation
/// remains pending; a matching final number never substitutes for a relation.
enum KnowledgeFormula {
    private struct Powers:Hashable {
        let values:[String:Int]
        static func ==(a:Self,b:Self)->Bool{a.values==b.values}
        func hash(into h:inout Hasher){for k in values.keys.sorted(){h.combine(k);h.combine(values[k])}}
        var key:String{values.keys.sorted().map{$0+":"+String(values[$0]!)}.joined(separator:";")}
    }
    private struct Poly {
        var terms:[Powers:Double]
        static func constant(_ n:Double)->Self{.init(terms:[.init(values:[:]):n])}
        static func variable(_ s:String)->Self{.init(terms:[.init(values:[s:1]):1])}
        func plus(_ b:Self,scale:Double=1)throws->Self {
            var r=terms
            for (k,v) in b.terms{r[k,default:0]+=scale*v}
            return try Self.checked(r)
        }
        func times(_ b:Self)throws->Self {
            guard terms.count*b.terms.count<=64 else{throw Parse.unsupported}
            var r:[Powers:Double]=[:]
            for (a,av) in terms{for (b,bv) in b.terms {
                var p=a.values;for (k,v) in b.values{p[k,default:0]+=v;if p[k]==0{p.removeValue(forKey:k)}}
                guard p.values.allSatisfy({abs($0)<=12}) else{throw Parse.unsupported}
                r[.init(values:p),default:0]+=av*bv
            }}
            return try Self.checked(r)
        }
        func divided(_ b:Self)throws->Self {
            guard b.terms.count==1,let (p,c)=b.terms.first,abs(c)>1e-12 else{throw Parse.unsupported}
            let inverse=Poly(terms:[.init(values:p.values.mapValues{-$0}):1/c]);return try times(inverse)
        }
        static func checked(_ r:[Powers:Double])throws->Self {
            guard r.count<=32,r.values.allSatisfy({$0.isFinite && abs($0)<=1e18}) else{throw Parse.unsupported}
            return .init(terms:r.filter{abs($0.value)>1e-12})
        }
    }
    private enum Token:Equatable {case number(Double),variable(String),symbol(Character)}
    private enum Parse:Error{case unsupported}
    private struct Parser {
        let tokens:[Token];var index=0;var depth=0
        mutating func expression()throws->Poly {
            var p=try product()
            while index<tokens.count {
                if tokens[index] == .symbol("+"){index+=1;p=try p.plus(product())}
                else if tokens[index] == .symbol("-"){index+=1;p=try p.plus(product(),scale:-1)}else{break}
            };return p
        }
        mutating func product()throws->Poly {
            var p=try unary()
            while index<tokens.count {
                if tokens[index] == .symbol("*"){index+=1;p=try p.times(unary())}
                else if tokens[index] == .symbol("/"){index+=1;p=try p.divided(unary())}else{break}
            };return p
        }
        mutating func unary()throws->Poly {
            if index<tokens.count,tokens[index] == .symbol("-"){index+=1;return try Poly.constant(-1).times(unary())}
            if index<tokens.count,tokens[index] == .symbol("+"){index+=1;return try unary()}
            return try power()
        }
        mutating func power()throws->Poly {
            var p=try atom()
            if index<tokens.count,tokens[index] == .symbol("^") {
                index+=1;var sign=1
                if index<tokens.count,tokens[index] == .symbol("-"){sign = -1;index+=1}
                guard index<tokens.count,case .number(let d)=tokens[index],d.rounded()==d,abs(d)<=4 else{throw Parse.unsupported}
                index+=1;let n=Int(d)*sign;var out=Poly.constant(1)
                for _ in 0..<abs(n){out=try out.times(p)}
                if n<0{p=try Poly.constant(1).divided(out)}else{p=out}
            };return p
        }
        mutating func atom()throws->Poly {
            guard index<tokens.count,depth<20 else{throw Parse.unsupported};depth+=1;defer{depth-=1}
            let t=tokens[index];index+=1
            switch t {
            case .number(let n):return .constant(n)
            case .variable(let v):return .variable(v)
            case .symbol("("):
                let p=try expression();guard index<tokens.count,tokens[index] == .symbol(")") else{throw Parse.unsupported};index+=1;return p
            default:throw Parse.unsupported
            }
        }
    }
    private struct Signature {let equation:Bool;let terms:[String:Double];let variables:Set<String>}
    private static func normalize(_ s:String)->String {
        var x=s.lowercased().filter{!$0.isWhitespace}
        for (a,b) in [("（","("),("）",")"),("×","*"),("·","*"),("÷","/"),("−","-"),("²","^2"),("³","^3"),("cosφ","c"),("cos(phi)","c"),("cos(φ)","c"),("u_l","u"),("i_l","i"),("u线","u"),("i线","i"),("sqrt(3)","@"),("√3","@")]{x=x.replacingOccurrences(of:a,with:b)}
        return x
    }
    private static func lex(_ text:String,variables:[String])throws->[Token] {
        let chars=Array(text);let names=variables.sorted{$0.count>$1.count};var i=0,out:[Token]=[]
        while i<chars.count {
            guard out.count<160 else{throw Parse.unsupported};let ch=chars[i]
            if ch=="@"{out.append(.number(sqrt(3)));i+=1;continue}
            if ch.isNumber || ch=="." {
                let start=i;i+=1
                while i<chars.count,(chars[i].isNumber || chars[i]=="."){i+=1}
                guard let n=Double(String(chars[start..<i])),n.isFinite,abs(n)<=1e12,(n==0 || abs(n)>=1e-12) else{throw Parse.unsupported}
                out.append(.number(n));continue
            }
            if "+-*/^()".contains(ch){out.append(.symbol(ch));i+=1;continue}
            if let name=names.first(where:{Array(chars[i...]).starts(with:Array($0))}){out.append(.variable(name));i+=name.count;continue}
            throw Parse.unsupported
        }
        // Conventional adjacent mathematical factors such as sqrt(3)UI are
        // accepted. Explicit operators remain necessary around sums/divisions.
        var expanded:[Token]=[]
        func end(_ t:Token)->Bool{if case .number=t{return true};if case .variable=t{return true};return t == .symbol(")")}
        func begin(_ t:Token)->Bool{if case .number=t{return true};if case .variable=t{return true};return t == .symbol("(")}
        for t in out{if let prior=expanded.last,end(prior),begin(t){expanded.append(.symbol("*"))};expanded.append(t)}
        return expanded
    }
    private static func polynomial(_ text:String,variables:[String])throws->(Poly,Set<String>) {
        let tokens=try lex(text,variables:variables);guard !tokens.isEmpty else{throw Parse.unsupported}
        var parser=Parser(tokens:tokens);let p=try parser.expression();guard parser.index==tokens.count else{throw Parse.unsupported}
        return (p,Set(tokens.compactMap{if case .variable(let s)=$0{return s};return nil}))
    }
    private static func signature(_ input:String,variables:[String],lhs:String?)throws->Signature {
        guard input.count<=300 else{throw Parse.unsupported};let text=normalize(input)
        var sides=text.split(separator:"=",omittingEmptySubsequences:false).map(String.init)
        guard (1...2).contains(sides.count) else{throw Parse.unsupported}
        if sides.count==1,let lhs{sides=[lhs,sides[0]]}
        var (p,used)=try polynomial(sides[0],variables:variables)
        if sides.count==2 {
            let (right,rvars)=try polynomial(sides[1],variables:variables);p=try p.plus(right,scale:-1);used.formUnion(rvars)
            guard !p.terms.isEmpty else{throw Parse.unsupported}
            let names=Set(p.terms.keys.flatMap{$0.values.keys});var minima:[String:Int]=[:]
            for name in names{minima[name]=p.terms.keys.map{$0.values[name] ?? 0}.min()!}
            p=try p.times(.init(terms:[.init(values:minima.mapValues{-$0}):1]))
        }
        var result=Dictionary(uniqueKeysWithValues:p.terms.map{($0.key.key,$0.value)})
        if sides.count==2,let first=result.keys.sorted().first,let scale=result[first],abs(scale)>1e-12{result=result.mapValues{$0/scale}}
        return .init(equation:sides.count==2,terms:result,variables:used)
    }
    static func equivalent(_ input:String,to expected:String,variables:[String],lhs:String?)->Bool? {
        guard let a=try? signature(input,variables:variables,lhs:lhs),let b=try? signature(expected,variables:variables,lhs:lhs) else{return nil}
        guard a.equation==b.equation,Set(a.terms.keys)==Set(b.terms.keys) else{return false}
        return a.terms.allSatisfy{k,v in abs(v-b.terms[k]!)<=1e-9*max(1,abs(v),abs(b.terms[k]!))}
    }
    static func usedVariables(_ input:String,variables:[String],lhs:String?)->Set<String>?{try? signature(input,variables:variables,lhs:lhs).variables}
}
