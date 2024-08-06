//
//  Expr.swift
//  LispKit
//
//  Created by Matthias Zenger on 08/11/2015.
//  Copyright © 2016-2022 ObjectHub. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation
import NumberKit
import CLFormat

///
/// `Expr` represents LispKit expressions in form of an enumeration with associated values.
///
public enum Expr: Hashable {
  case undef
  case void
  case eof
  case null
  case `true`
  case `false`
  case uninit(Symbol)
  case symbol(Symbol)
  case fixnum(Int64)
  case bignum(BigInt)
  indirect case rational(Expr, Expr)
  case flonum(Double)
  case complex(DoubleComplex)
  case char(UniChar)
  case string(NSMutableString)
  case bytes(ByteVector)
  indirect case pair(Expr, Expr)
  case box(Cell)
  case mpair(Tuple)
  case array(Collection)
  case vector(Collection)
  case record(Collection)
  case table(HashTable)
  case promise(Promise)
  indirect case values(Expr)
  case procedure(Procedure)
  case special(SpecialForm)
  case env(Environment)
  case port(Port)
  case object(any CustomExpr)
  indirect case tagged(Expr, Expr)
  case error(RuntimeError)
  indirect case syntax(SourcePosition, Expr)
  
  /// Returns the type of this expression.
  public var type: Type {
    switch self {
      case .undef, .uninit(_):
        return .undefinedType
      case .void:
        return .voidType
      case .eof:
        return .eofType
      case .null:
        return .nullType
      case .true:
        return .booleanType
      case .false:
        return .booleanType
      case .symbol(_):
        return .symbolType
      case .fixnum(_):
        return .fixnumType
      case .bignum(_):
        return .bignumType
      case .rational(_, _):
        return .rationalType
      case .flonum(let num):
        return Foundation.trunc(num) == num ? .integerType : .floatType
      case .complex(_):
        return .complexType
      case .char(_):
        return .charType
      case .string(_):
        return .strType
      case .bytes(_):
        return .byteVectorType
      case .pair(_, _):
        return .pairType
      case .box(_):
        return .boxType
      case .mpair(_):
        return .mpairType
      case .array(_):
        return .arrayType
      case .vector(let vec):
        return vec.isGrowableVector ? .gvectorType : .vectorType
      case .record(_):
        return .recordType
      case .table(_):
        return .tableType
      case .promise(let future):
        return future.isStream ? .streamType : .promiseType
      case .values(_):
        return .valuesType
      case .procedure(_):
        return .procedureType
      case .special(_):
        return .specialType
      case .env(_):
        return .envType
      case .port(_):
        return .portType
      case .object(let obj):
        return obj.type
      case .tagged(_, _):
        return .taggedType
      case .error(_):
        return .errorType
      case .syntax(_, _):
        return .syntaxType
    }
  }
  
  public func typeTag(in context: Context) -> [Symbol]? {
    switch self {
      case .undef:
        return nil
      case .uninit(_):
        return nil
      case .void:
        return [context.symbols.void]
      case .eof:
        return [context.symbols.endOfFile]
      case .null:
        return [context.symbols.null, context.symbols.list]
      case .true:
        return [context.symbols.boolean]
      case .false:
        return [context.symbols.boolean]
      case .symbol(_):
        return [context.symbols.symbol]
      case .fixnum(_):
        return [context.symbols.fixnum,
                context.symbols.integer,
                context.symbols.real,
                context.symbols.number]
      case .bignum(_):
        return [context.symbols.bignum,
                context.symbols.integer,
                context.symbols.real,
                context.symbols.number]
      case .rational(_, _):
        return [context.symbols.rational,
                context.symbols.real,
                context.symbols.number]
      case .flonum(_):
        return [context.symbols.flonum,
                context.symbols.real,
                context.symbols.number]
      case .complex(_):
        return [context.symbols.complex, context.symbols.number]
      case .char(_):
        return [context.symbols.char]
      case .string(_):
        return [context.symbols.string]
      case .bytes(_):
        return [context.symbols.bytevector]
      case .pair(_, _):
        return [context.symbols.pair, context.symbols.list]
      case .box(_):
        return [context.symbols.box]
      case .mpair(_):
        return [context.symbols.mpair]
      case .array(_):
        return [context.symbols.array]
      case .vector(let coll):
        switch coll.kind {
          case .vector:
            return [context.symbols.vector]
          case .immutableVector:
            return [context.symbols.vector]
          case .growableVector:
            return [context.symbols.gvector]
          default:
            return nil
        }
      case .record(let coll):
        switch coll.kind {
          case .recordType:
            return [context.symbols.recordType]
          case .record(let icoll):
            if case .recordType = icoll.kind,
               case .symbol(let curr) = icoll.exprs[Collection.RecordType.typeTag.rawValue] {
              var res = [curr]
              var rectype = icoll.exprs[Collection.RecordType.parent.rawValue]
              while case .record(let col) = rectype,
                    case .recordType = col.kind,
                    case .symbol(let sym) = col.exprs[Collection.RecordType.typeTag.rawValue] {
                res.append(sym)
                rectype = col.exprs[Collection.RecordType.parent.rawValue]
              }
              return res
            } else {
              return nil
            }
          default:
            return nil
        }
      case .table(_):
        return [context.symbols.hashtable]
      case .promise(_):
        return [context.symbols.promise]
      case .values(_):
        return [context.symbols.values]
      case .procedure(let proc):
        switch proc.kind {
          case .parameter(_):
            return [context.symbols.parameter]
          default:
            return [context.symbols.procedure]
        }
      case .special(_):
        return [context.symbols.syntax]
      case .env(_):
        return [context.symbols.environment]
      case .port(let port):
        if port.isInputPort {
          return [context.symbols.inputPort, context.symbols.port]
        } else if port.isOutputPort {
          return [context.symbols.outputPort, context.symbols.port]
        } else { // Not sure if this ever happens
          return [context.symbols.port]
        }
      case .object(let obj):
        if case .objectType(let sym) = obj.type {
          return [sym]
        } else {
          return nil
        }
      case .tagged(.pair(.symbol(let sym), let rest), _):
        var res = [sym]
        var taglist = rest
        while case .pair(.symbol(let s), let next) = taglist {
          res.append(s)
          taglist = next
        }
        return res
      case .tagged(let tag, _):
        if case .object(let objTag) = tag {
          if let enumType = objTag as? EnumType {
            return [enumType.id]
          }
        }
        return nil
      case .error(_):
        return [context.symbols.error]
      case .syntax(_, _):
        return nil
    }
  }
  
  public func unpack(in context: Context? = nil) -> Exprs? {
    switch self {
      case .false:
        return [.makeNumber(0)]
      case .true:
        return [.makeNumber(1)]
      case .rational(let num, let denom):
        return [num, denom]
      case .complex(let cpl):
        return [Expr.flonum(cpl.value.re), Expr.flonum(cpl.value.im)]
      case .symbol(let sym):
        return [Expr.makeString(sym.identifier),
                Expr.makeString(sym.description)]
      case .bytes(let bvec):
        var exprs: Exprs = []
        for x in bvec.value {
          exprs.append(.fixnum(Int64(x)))
        }
        return [Expr.makeString(bvec.identityString),
                Expr.vector(Collection(kind: .immutableVector, exprs: exprs))]
      case .box(let x):
        return [Expr.makeString(x.identityString), x.value]
      case .mpair(let x):
        return [Expr.makeString(x.identityString), x.fst, x.snd]
      case .table(let ht):
        var exprs: Exprs = []
        for bucket in ht.buckets {
          var current = bucket
          while case .pair(.pair(let key, let value), let next) = current {
            exprs.append(.pair(key, .pair(value, .null)))
            current = next
          }
        }
        return [Expr.makeString(ht.identityString),
                Expr.vector(Collection(kind: .immutableVector, exprs: exprs))]
      case .env(let ev):
        var exprs: Exprs = []
        for (sym, val) in ev.bindings {
          let suffix: Expr
          switch val {
            case .undefined:
              suffix = .pair(.fixnum(0), .null)
            case .mutable(let n):
              suffix = .pair(.fixnum(1), .pair(.fixnum(Int64(n)), .null))
            case .mutableImport(let n):
              suffix = .pair(.fixnum(2), .pair(.fixnum(Int64(n)), .null))
            case .immutableImport(let n):
              suffix = .pair(.fixnum(3), .pair(.fixnum(Int64(n)), .null))
          }
          exprs.append(.pair(.symbol(sym), suffix))
        }
        switch ev.kind {
          case .library(let name):
            return [Expr.makeString(ev.identityString),
                    Expr.fixnum(0),
                    name,
                    Expr.vector(Collection(kind: .immutableVector, exprs: exprs))]
          case .program(let file):
            return [Expr.makeString(ev.identityString),
                    Expr.fixnum(1),
                    Expr.makeString(file),
                    Expr.vector(Collection(kind: .immutableVector, exprs: exprs))]
          case .repl:
            return [Expr.makeString(ev.identityString),
                    Expr.fixnum(2),
                    Expr.vector(Collection(kind: .immutableVector, exprs: exprs))]
          case .custom:
            return [Expr.makeString(ev.identityString),
                    Expr.fixnum(3),
                    Expr.vector(Collection(kind: .immutableVector, exprs: exprs))]
        }
      case .record(let col):
        switch col.kind {
          case .record(let icoll):
            if case .recordType = icoll.kind {
              var res: Exprs = [Expr.makeString(col.identityString)]
              for x in col.exprs {
                res.append(x)
              }
              return res
            }
          case .recordType:
            let syms = Collection.RecordType.fields(col)
            var allFields = Expr.null
            for sym in syms.reversed() {
              allFields = .pair(.symbol(sym), allFields)
            }
            return [Expr.makeString(col.identityString),
                    col.exprs[Collection.RecordType.typeTag.rawValue],
                    col.exprs[Collection.RecordType.parent.rawValue],
                    col.exprs[Collection.RecordType.fields.rawValue],
                    allFields]
          default:
            break
        }
      case .tagged(.pair(.symbol(_), _), let repr):
        return [repr]
      case .tagged(.object(_), let repr):
        return [repr]
      case .object(let obj):
        if let context {
          return obj.unpack(in: context)
        } else {
          return nil
        }
      case .error(let err):
        let filePath: Expr
        if let path = context?.sources.sourcePath(for: err.pos.sourceId) {
          filePath = .makeString(path)
        } else {
          filePath = .false
        }
        let position = Expr.pair(filePath,
                           .pair(err.pos.lineIsUnknown ? .false : .fixnum(Int64(err.pos.line)),
                           .pair(err.pos.columnIsUnknown ? .false : .fixnum(Int64(err.pos.column)),
                           .null)))
        let typeId: Int
        switch err.descriptor {
          case .lexical(_):
            typeId = 0
          case .syntax(_):
            typeId = 1
          case .type(_, _):
            typeId = 2
          case .range(_, _, _, _):
            typeId = 3
          case .argumentCount(_, _, _):
            typeId = 4
          case .eval(_):
            typeId = 5
          case .os(_):
            typeId = 6
          case .abortion:
            typeId = 7
          case .uncaught:
            typeId = 8
          case .custom(_, _):
            typeId = 9
        }
        var usedIrritants = Set<Int>()
        let message = err.replacePlaceholders(in: err.descriptor.messageTemplate,
                                              with: err.irritants,
                                              recordingUsage: &usedIrritants)
        var irritants: Exprs = []
        for index in err.irritants.indices {
          if !usedIrritants.contains(index) {
            irritants.append(err.irritants[index])
          }
        }
        var callTrace: Exprs = []
        if let trace = err.callTrace {
          for call in trace {
            callTrace.append(.makeString(call))
          }
        } else if let stackTrace = err.stackTrace {
          for proc in stackTrace {
            callTrace.append(.makeString(proc.name))
          }
        }
        return [position,
                Expr.makeNumber(typeId),
                Expr.makeString(err.descriptor.typeDescription),
                Expr.makeString(message),
                Expr.vector(Collection(kind: .immutableVector, exprs: irritants)),
                err.library ?? Expr.false,
                Expr.vector(Collection(kind: .immutableVector, exprs: callTrace))]
      default:
        break
    }
    return nil
  }
  
  /// Returns the position of this expression.
  public var pos: SourcePosition {
    switch self {
      case .syntax(let sourcePos, _):
        return sourcePos
      default:
        return SourcePosition.unknown
    }
  }
  
  // Predicate methods
  
  /// Returns true if this expression is undefined.
  public var isUndef: Bool {
    switch self {
      case .undef, .uninit(_):
        return true
      default:
        return false
    }
  }
  
  /// Returns true if this expression is null.
  public var isNull: Bool {
    switch self {
      case .null:
        return true
      default:
        return false
    }
  }
  
  /// Returns true if this is not the `#f` value.
  public var isTrue: Bool {
    switch self {
      case .false:
        return false
      default:
        return true
    }
  }
  
  /// Returns true if this is the `#f` value.
  public var isFalse: Bool {
    switch self {
      case .false:
        return true
      default:
        return false
    }
  }
  
  /// Returns true if this is an exact number.
  public var isExactNumber: Bool {
    switch self {
      case .fixnum(_), .bignum(_), .rational(_, _):
        return true
      default:
        return false
    }
  }
  
  /// Returns true if this is an inexact number.
  public var isInexactNumber: Bool {
    switch self {
      case .flonum(_), .complex(_):
        return true
      default:
        return false
    }
  }
  
  /// Normalizes the representation (relevant for numeric datatypes)
  public var normalized: Expr {
    switch self {
      case .bignum(let num):
        if let fn = num.intValue {
          return .fixnum(fn)
        }
        return self
      case .rational(let n, let d):
        switch d {
          case .fixnum(let fd):
            return fd == 1 ? n : self
          case .bignum(let bd):
            return bd == 1 ? n.normalized : self
          default:
            return self
        }
      case .complex(let num):
        return num.value.isReal ? .flonum(num.value.re) : self
      default:
        return self
    }
  }
  
  /// Returns the source position associated with this expression, or `outer` in case there is
  /// no syntax annotation.
  public func pos(_ outer: SourcePosition = SourcePosition.unknown) -> SourcePosition {
    switch self {
      case .syntax(let p, _):
        return p
      case .pair(.syntax(let p, _), _):
        return p
      default:
        return outer
    }
  }
  
  /// Returns the given expression with all symbols getting interned and syntax nodes removed.
  public var datum: Expr {
    switch self {
      case .symbol(let sym):
        return .symbol(sym.root)
      case .pair(let car0, .pair(let car1, .pair(let car2, let cdr))):
        return .pair(car0.datum, .pair(car1.datum, .pair(car2.datum, cdr.datum)))
      case .pair(let car0, .pair(let car1, let cdr)):
        return .pair(car0.datum, .pair(car1.datum, cdr.datum))
      case .pair(let car, let cdr):
        return .pair(car.datum, cdr.datum)
      case .syntax(_, let expr):
        return expr.datum
      default:
        return self
    }
  }
  
  /// Returns the given expression with all syntax nodes removed up to `depth` nested expression
  /// nodes.
  public func removeSyntax(depth: Int = 4) -> Expr {
    guard depth > 0 else {
      return self
    }
    switch self {
      case .pair(let car, let cdr):
        return .pair(car.removeSyntax(depth: depth - 1), cdr.removeSyntax(depth: depth - 1))
      case .syntax(_, let expr):
        return expr.removeSyntax(depth: depth)
      default:
        return self
    }
  }
  
  /// Inject the given position into the expression.
  public func at(pos: SourcePosition) -> Expr {
    switch self {
      case .pair(let car, let cdr):
        return .syntax(pos, .pair(car.at(pos: pos), cdr.at(pos: pos)))
      case .syntax(_, _):
        return self
      default:
        return .syntax(pos, self)
    }
  }
  
  /// Maps a list into an array of expressions and a tail (= null for proper lists)
  public func toExprs() -> (Exprs, Expr) {
    var exprs = Exprs()
    var expr = self
    while case .pair(let car, let cdr) = expr {
      exprs.append(car)
      expr = cdr
    }
    return (exprs, expr)
  }
  
  /// The length of this expression (all non-pair expressions have length 1).
  var length: Int {
    var expr = self
    var len = 0
    while case .pair(_, let cdr) = expr {
      len += 1
      expr = cdr
    }
    return len
  }
  
  /// Returns true if the expression isn't referring to other expressions directly or
  /// indirectly.
  public var isAtom: Bool {
    switch self {
      case .undef, .void, .eof, .null, .true, .false, .uninit(_), .symbol(_),
           .fixnum(_), .bignum(_), .rational(_, _), .flonum(_), .complex(_),
           .char(_), .string(_), .bytes(_), .env(_), .port(_):
        return true
      case .pair(let car0, .pair(let car1, .pair(let car2, .pair(let car3, let cdr)))):
        return car0.isSimpleAtom && car1.isSimpleAtom && car2.isSimpleAtom && car3.isSimpleAtom &&
               cdr.isSimpleAtom
      case .pair(let car0, .pair(let car1, .pair(let car2, let cdr))):
        return car0.isSimpleAtom && car1.isSimpleAtom && car2.isSimpleAtom && cdr.isSimpleAtom
      case .pair(let car0, .pair(let car1, let cdr)):
        return car0.isSimpleAtom && car1.isSimpleAtom && cdr.isSimpleAtom
      case .pair(let car, let cdr):
        return car.isSimpleAtom && cdr.isSimpleAtom
      case .tagged(let tag, let expr):
        return tag.isSimpleAtom && expr.isAtom
      case .values(let expr):
        return expr.isAtom
      case .object(let expr):
        return expr.isAtom
      default:
        return false
    }
  }

  public var isSimpleAtom: Bool {
    switch self {
      case .undef, .void, .eof, .null, .true, .false, .uninit(_), .symbol(_),
           .fixnum(_), .bignum(_), .rational(_, _), .flonum(_), .complex(_),
           .char(_), .string(_), .bytes(_), .env(_), .port(_):
        return true
      case .object(let expr):
        return expr.isAtom
      default:
        return false
    }
  }
  
  public func hash(into hasher: inout Hasher) {
    equalHash(self, into: &hasher)
  }
}


/// Extension adding static factory methods to `Expr`.
///
extension Expr {
  
  public static func makeBoolean(_ val: Bool) -> Expr {
    return val ? .true : .false
  }
  
  public static func makeNumber(_ num: Int) -> Expr {
    return .fixnum(Int64(num))
  }
  
  public static func makeNumber(_ num: Int64) -> Expr {
    return .fixnum(num)
  }
  
  public static func makeNumber(_ num: UInt64) -> Expr {
    return Expr.bignum(BigInt(num)).normalized
  }
  
  public static func makeNumber(_ num: BigInt) -> Expr {
    return Expr.bignum(num).normalized
  }
  
  public static func makeNumber(_ num: Rational<Int64>) -> Expr {
    return Expr.rational(.fixnum(num.numerator), .fixnum(num.denominator)).normalized
  }
  
  public static func makeNumber(_ num: Rational<BigInt>) -> Expr {
    return Expr.rational(.bignum(num.numerator), .bignum(num.denominator)).normalized
  }
  
  public static func makeNumber(_ num: Double) -> Expr {
    return .flonum(num)
  }
  
  public static func makeNumber(_ num: Complex<Double>) -> Expr {
    return Expr.complex(ImmutableBox(num)).normalized
  }
  
  public static func makeList(_ expr: Expr...) -> Expr {
    return Expr.makeList(fromStack: expr.reversed(), append: Expr.null)
  }
  
  public static func makeList(_ exprs: Exprs, append: Expr = Expr.null) -> Expr {
    return Expr.makeList(fromStack: exprs.reversed(), append: append)
  }
  
  public static func makeList(_ exprs: Arguments, append: Expr = Expr.null) -> Expr {
    return Expr.makeList(fromStack: exprs.reversed(), append: append)
  }
  
  public static func makeList(fromStack exprs: [Expr], append: Expr = Expr.null) -> Expr {
    var res = append
    for expr in exprs {
      res = pair(expr, res)
    }
    return res
  }
  
  public static func makeString(_ str: String) -> Expr {
    return .string(NSMutableString(string: str))
  }
}


/// This extension adds projections to `Expr`.
///
extension Expr {
  
  @inline(__always)
  public func assertType(at pos: SourcePosition = SourcePosition.unknown, _ types: Type...) throws {
    for type in types {
      for subtype in type.included {
        if self.type == subtype {
          return
        }
      }
    }
    throw RuntimeError.type(self, expected: Set(types)).at(pos)
  }
  
  @inline(__always)
  public func asInt64(at pos: SourcePosition = SourcePosition.unknown) throws -> Int64 {
    guard case .fixnum(let res) = self else {
      throw RuntimeError.type(self, expected: [.fixnumType]).at(pos)
    }
    return res
  }
  
  @inline(__always)
  public func asInt(above: Int = 0, below: Int = Int.max) throws -> Int {
    guard case .fixnum(let res) = self else {
      throw RuntimeError.type(self, expected: [.fixnumType])
    }
    guard res >= Int64(above) && res < Int64(below) else {
      throw RuntimeError.range(self,
                               min: Int64(above),
                               max: below == Int.max ? Int64.max : Int64(below - 1))
    }
    return Int(res)
  }
  
  @inline(__always) public func asUInt8() throws -> UInt8 {
    guard case .fixnum(let number) = self , number >= 0 && number <= 255 else {
      throw RuntimeError.type(self, expected: [.byteType])
    }
    return UInt8(number)
  }
  
  public func asDouble(coerce: Bool = false) throws -> Double {
    if !coerce {
      if case .flonum(let num) = self {
        return num
      }
      throw RuntimeError.type(self, expected: [.floatType])
    }
    switch self.normalized {
      case .fixnum(let num):
        return Double(num)
      case .bignum(let num):
        return num.doubleValue
      case .rational(.fixnum(let n), .fixnum(let d)):
        return Double(n) / Double(d)
      case .rational(.bignum(let n), .bignum(let d)):
        return n.doubleValue / d.doubleValue
      case .flonum(let num):
        return num
      default:
        throw RuntimeError.type(self, expected: [.realType])
    }
  }
  
  public func asComplex(coerce: Bool = false) throws -> Complex<Double> {
    if !coerce {
      switch self {
        case .flonum(let num):
          return Complex(num, 0.0)
        case .complex(let complex):
          return complex.value
        default:
          throw RuntimeError.type(self, expected: [.complexType])
      }
    }
    switch self.normalized {
      case .fixnum(let num):
        return Complex(Double(num), 0.0)
      case .bignum(let num):
        return Complex(num.doubleValue, 0.0)
      case .rational(.fixnum(let n), .fixnum(let d)):
        return Complex(Double(n) / Double(d), 0.0)
      case .rational(.bignum(let n), .bignum(let d)):
        return Complex(n.doubleValue / d.doubleValue, 0.0)
      case .flonum(let num):
        return Complex(num, 0.0)
      case .complex(let num):
        return num.value
      default:
        throw RuntimeError.type(self, expected: [.complexType])
    }
  }
  
  @inline(__always) public func asSymbol() throws -> Symbol {
    switch self {
      case .symbol(let sym):
        return sym
      default:
        throw RuntimeError.type(self, expected: [.symbolType])
    }
  }
  
  @inline(__always) public func toSymbol() -> Symbol? {
    switch self {
      case .symbol(let sym):
        return sym
      default:
        return nil
    }
  }
  
  @inline(__always) public func asUniChar() throws -> UniChar {
    guard case .char(let res) = self else {
      throw RuntimeError.type(self, expected: [.charType])
    }
    return res
  }
  
  @inline(__always) public func charAsString() throws -> String {
    guard case .char(let res) = self else {
      throw RuntimeError.type(self, expected: [.charType])
    }
    return String(unicodeScalar(res))
  }

  @inline(__always) public func charOrString() throws -> String {
    switch self {
      case .char(let res):
        return String(unicodeScalar(res))
      case .string(let res):
        return res as String
      default:
        throw RuntimeError.type(self, expected: [.strType])
    }
  }
  
  @inline(__always) public func asString() throws -> String {
    guard case .string(let res) = self else {
      throw RuntimeError.type(self, expected: [.strType])
    }
    return res as String
  }
  
  @inline(__always) public func asMutableStr() throws -> NSMutableString {
    guard case .string(let res) = self else {
      throw RuntimeError.type(self, expected: [.strType])
    }
    return res
  }
  
  @inline(__always) public func asPath() throws -> String {
    guard case .string(let res) = self else {
      throw RuntimeError.type(self, expected: [.strType])
    }
    return res.expandingTildeInPath
  }
  
  @inline(__always) public func asAbsolutePath(in context: Context) throws -> String {
    return context.fileHandler.path(try self.asPath(),
                                    relativeTo: context.evaluator.currentDirectoryPath)
  }
  
  @inline(__always) public func asURL() throws -> URL {
    guard case .string(let res) = self else {
      throw RuntimeError.type(self, expected: [.strType])
    }
    guard let url = URL(string: res as String) else {
      throw RuntimeError.eval(.invalidUrl, self)
    }
    return url
  }
  
  @inline(__always) public func asByteVector() throws -> ByteVector {
    guard case .bytes(let bvector) = self else {
      throw RuntimeError.type(self, expected: [.byteVectorType])
    }
    return bvector
  }
  
  @inline(__always) public func arrayAsCollection() throws -> Collection {
    guard case .array(let res) = self else {
      throw RuntimeError.type(self, expected: [.arrayType])
    }
    return res
  }
  
  @inline(__always) public func vectorAsCollection(growable: Bool? = nil) throws -> Collection {
    guard case .vector(let vec) = self else {
      let exp: Set<Type> = growable == nil ? [.vectorType, .gvectorType]
                                           : growable! ? [.gvectorType] : [.vectorType]
      throw RuntimeError.type(self, expected: exp)
    }
    if let growable = growable, growable != vec.isGrowableVector {
      throw RuntimeError.type(self, expected: growable ? [.gvectorType] : [.vectorType])
    }
    return vec
  }
  
  @inline(__always) public func recordAsCollection() throws -> Collection {
    guard case .record(let res) = self else {
      throw RuntimeError.type(self, expected: [.recordType])
    }
    return res
  }
  
  @inline(__always) public func asHashTable() throws -> HashTable {
    guard case .table(let map) = self else {
      throw RuntimeError.type(self, expected: [.tableType])
    }
    return map
  }
  
  @inline(__always) public func asProcedure() throws -> Procedure {
    guard case .procedure(let proc) = self else {
      throw RuntimeError.type(self, expected: [.procedureType])
    }
    return proc
  }
  
  @inline(__always) public func asEnvironment() throws -> Environment {
    guard case .env(let environment) = self else {
      throw RuntimeError.type(self, expected: [.envType])
    }
    return environment
  }
  
  @inline(__always) public func asPort() throws -> Port {
    guard case .port(let port) = self else {
      throw RuntimeError.type(self, expected: [.portType])
    }
    return port
  }
  
  @inline(__always) public func asObject(of type: Type) throws -> any CustomExpr {
    guard case .object(let obj) = self, obj.type == type else {
      throw RuntimeError.type(self, expected: [type])
    }
    return obj
  }
}


/// This extension makes `Expr` implement the `CustomStringConvertible`.
///
extension Expr: CustomStringConvertible, CLFormatConvertible {
  
  public var description: String {
    return self.toString()
  }
  
  public var unescapedDescription: String {
    return self.toString(escape: false)
  }
  
  public var clformatDescription: String {
    return self.toString(escape: false)
  }
  
  public func toString(escape: Bool = true) -> String {
    var enclObjs = Set<Reference>()
    var objId = [Reference: Int]()
    
    func objIdString(_ ref: Reference) -> String? {
      if let id = objId[ref] {
        return "#\(id)#"
      } else if enclObjs.contains(ref) {
        objId[ref] = objId.count
        return "#\(objId.count - 1)#"
      } else {
        return nil
      }
    }
    
    func fixString(_ ref: Reference, _ str: String) -> String {
      if let id = objId[ref] {
        return "#\(id)=\(str)"
      } else {
        return str
      }
    }
    
    func doubleString(_ val: Double) -> String {
      if val.isInfinite {
        return (val.sign == .minus) ? "-inf.0" : "+inf.0"
      } else if val.isNaN {
        return (val.sign == .minus) ? "-nan.0" : "+nan.0"
      } else {
        return String(val)
      }
    }
    
    func stringReprOf(_ expr: Expr) -> String {
      switch expr {
        case .undef:
          return "#?"
        case .void:
          return "#<void>"
        case .eof:
          return "#<eof>"
        case .null:
          return "()"
        case .true:
          return "#t"
        case .false:
          return "#f"
        case .uninit(let sym):
          guard escape else {
            return "#<? \(sym.rawIdentifier)>"
          }
          return "#<? \(sym.description)>"
        case .symbol(let sym):
          guard escape else {
            return sym.rawIdentifier
          }
          return sym.description
        case .fixnum(let val):
          return String(val)
        case .bignum(let val):
          return val.description
        case .rational(let n, let d):
          return stringReprOf(n) + "/" + stringReprOf(d)
        case .flonum(let val):
          return doubleString(val)
        case .complex(let val):
          var res = doubleString(val.value.re)
          if val.value.im.isNaN || val.value.im.isInfinite || val.value.im < 0.0 {
            res += doubleString(val.value.im)
          } else {
            res += "+" + doubleString(val.value.im)
          }
          return res + "i"
        case .char(let ch):
          guard escape else {
            return String(unicodeScalar(ch))
          }
          switch ch {
            case   7: return "#\\alarm"
            case   8: return "#\\backspace"
            case 127: return "#\\delete"
            case  27: return "#\\escape"
            case  10: return "#\\newline"
            case   0: return "#\\null"
            case  12: return "#\\page"
            case  13: return "#\\return"
            case  32: return "#\\space"
            case   9: return "#\\tab"
            case  11: return "#\\vtab"
            default :
              if WHITESPACES_NL.contains(unicodeScalar(ch)) ||
                 CONTROL_CHARS.contains(unicodeScalar(ch)) ||
                 ILLEGAL_CHARS.contains(unicodeScalar(ch)) ||
                 MODIFIER_CHARS.contains(unicodeScalar(ch)) ||
                 ch > 0xd7ff {
                return "#\\x\(String(ch, radix:16))"
              } else if let scalar = UnicodeScalar(ch) {
                return "#\\\(Character(scalar))"
              } else {
                return "#\\x\(String(ch, radix:16))"
              }
          }
        case .string(let str):
          guard escape else {
            return str as String
          }
          return "\"\(Expr.escapeStr(str as String))\""
        case .bytes(let boxedVec):
          var builder = StringBuilder(prefix: "#u8(", postfix: ")", separator: " ")
          for byte in boxedVec.value {
            builder.append(String(byte))
          }
          return builder.description
        case .pair(let head, let tail):
          var builder = StringBuilder(prefix: "(", separator: " ")
          builder.append(stringReprOf(head))
          var expr = tail
          while case .pair(let car, let cdr) = expr {
            builder.append(stringReprOf(car))
            expr = cdr
          }
          return builder.description + (expr.isNull ? ")" : " . \(stringReprOf(expr)))")
        case .box(let cell):
          if let res = objIdString(cell) {
            return res
          } else {
            enclObjs.insert(cell)
            let res = "#<box \(stringReprOf(cell.value))>"
            enclObjs.remove(cell)
            return fixString(cell, res)
          }
        case .mpair(let tuple):
          if let res = objIdString(tuple) {
            return res
          } else {
            enclObjs.insert(tuple)
            let res = "#<pair \(stringReprOf(tuple.fst)) \(stringReprOf(tuple.snd))>"
            enclObjs.remove(tuple)
            return fixString(tuple, res)
          }
        case .array(let array):
          if let res = objIdString(array) {
            return res
          } else if array.exprs.count == 0 {
            return "#<array>"
          } else {
            enclObjs.insert(array)
            var builder = StringBuilder(prefix: "#<array ", postfix: ">", separator: " ")
            for expr in array.exprs {
              builder.append(stringReprOf(expr))
            }
            enclObjs.remove(array)
            return fixString(array, builder.description)
          }
        case .vector(let vector):
          if let res = objIdString(vector) {
            return res
          } else if vector.exprs.count == 0 {
            return vector.isGrowableVector ? "#g()" : "#()"
          } else {
            enclObjs.insert(vector)
            var builder = StringBuilder(prefix: vector.isGrowableVector ? "#g(" : "#(",
                                        postfix: ")",
                                        separator: " ")
            for expr in vector.exprs {
              builder.append(stringReprOf(expr))
            }
            enclObjs.remove(vector)
            return fixString(vector, builder.description)
          }
        case .record(let record):
          guard case .record(let type) = record.kind else {
            guard record.exprs.count > 0 else {
              preconditionFailure("incorrect internal record type state: \(record.kind) | " +
                                  "\(record.description)")
            }
            guard case .symbol(let sym) = record.exprs[
                                            Collection.RecordType.typeTag.rawValue] else {
              preconditionFailure("incorrect encoding of record type")
            }
            if case .record(let coll) = record.exprs[Collection.RecordType.parent.rawValue],
               case .recordType = coll.kind,
               case .symbol(let psym) = coll.exprs[Collection.RecordType.typeTag.rawValue] {
              return "#<record-type \(sym.description): \(psym.description)>"
            } else {
              return "#<record-type \(sym.description)>"
            }
          }
          if let res = objIdString(record) {
            return res
          } else {
            guard case .symbol(let sym) = type.exprs[
                                            Collection.RecordType.typeTag.rawValue] else {
              preconditionFailure("incorrect encoding of record type")
            }
            enclObjs.insert(record)
            var builder = StringBuilder(prefix: "#<record \(sym.description)",
                                        postfix: ">",
                                        separator: ", ",
                                        initial: ": ")
            let fields = Collection.RecordType.fields(type)
            precondition(fields.count == record.exprs.count,
                         "record encoding error; field counts not matching")
            for i in 0..<fields.count {
              builder.append(fields[i].description, "=", stringReprOf(record.exprs[i]))
            }
            enclObjs.remove(record)
            return fixString(record, builder.description)
          }
        case .table(let map):
          if let res = objIdString(map) {
            return res
          } else {
            enclObjs.insert(map)
            let prefix = Context.simplifiedDescriptions ?
                           "#<hashtable" : "#<hashtable \(map.identityString)"
            var builder = StringBuilder(prefix: prefix,
                                        postfix: ">",
                                        separator: ", ",
                                        initial: ": ")
            for (key, value) in map.mappings {
              builder.append(stringReprOf(key), " -> ", stringReprOf(value))
            }
            enclObjs.remove(map)
            return fixString(map, builder.description)
          }
        case .promise(let promise):
          return "#<\(promise.kind) \(promise.identityString)>"
        case .values(let list):
          var builder = StringBuilder(prefix: "#<values",
                                      postfix: ">",
                                      separator: " ",
                                      initial: ": ")
          var expr = list
          while case .pair(let car, let cdr) = expr {
            builder.append(stringReprOf(car))
            expr = cdr
          }
          return builder.description
        case .procedure(let proc):
          switch proc.kind {
            case .parameter(let tuple):
              if let res = objIdString(proc) {
                return res
              } else {
                enclObjs.insert(proc)
                let res = "#<parameter \(proc.name): \(stringReprOf(tuple.snd))>"
                enclObjs.remove(proc)
                return fixString(proc, res)
              }
            case .rawContinuation(_):
              return "#<raw-continuation \(proc.embeddedName)>"
            case .closure(.continuation, _, _, _):
              return "#<continuation \(proc.embeddedName)>"
            default:
              return "#<procedure \(proc.embeddedName)>"
          }
        case .special(let special):
          return "#<special \(special.name)>"
        case .env(let environment):
          var type: String = ""
          switch environment.kind {
            case .library(let name):
              type = " " + name.description
            case .program(let filename):
              type = " " + filename
            case .repl:
              type = " interaction"
            case .custom:
              type = ""
          }
          var builder = StringBuilder(prefix: "#<env",
                                      postfix: ">",
                                      separator: ", ",
                                      initial: type + ": ")
          for sym in environment.boundSymbols {
            builder.append(sym.description)
          }
          return builder.description
        case .port(let port):
          return "#<\(port.typeDescription) \(port.identDescription)>"
        case .object(let obj):
          return obj.string
        case .tagged(.pair(let fst, _), let expr):
          var res = "#<"
          switch fst {
            case .pair(let head, let tail):
              var builder = StringBuilder(prefix: "", separator: " ")
              builder.append(stringReprOf(head))
              var expr = tail
              while case .pair(let car, let cdr) = expr {
                builder.append(stringReprOf(car))
                expr = cdr
              }
              if expr.isNull {
                res += builder.description + ": "
              } else {
                res += builder.description + " . \(stringReprOf(expr)): "
              }
            case .object(let obj):
              res += obj.tagString + " "
            default:
              res += stringReprOf(fst) + " "
          }
          switch expr {
            case .object(let obj):
              res += obj.tagString.truncated(limit: 100)
            case .pair(let head, let tail):
              var builder = StringBuilder(prefix: "", separator: " ")
              builder.append(stringReprOf(head))
              var expr = tail
              while case .pair(let car, let cdr) = expr {
                builder.append(stringReprOf(car))
                expr = cdr
              }
              res += (builder.description + (expr.isNull ? "" : " . \(stringReprOf(expr))"))
                       .truncated(limit: 100)
            default:
              res += stringReprOf(expr).truncated(limit: 100)
          }
          return res + ">"
        case .tagged(let tag, let expr):
          if case .object(let objTag) = tag {
            if case .object(let objExpr) = expr {
              return "#<\(objTag.tagString): \(objExpr.tagString)>"
            } else {
              return "#<\(objTag.tagString): \(stringReprOf(expr))>"
            }
          } else if case .object(let objExpr) = expr {
            return "#<tag \(stringReprOf(tag)): \(objExpr.tagString)>"
          } else {
            return "#<tag \(stringReprOf(tag)): \(stringReprOf(expr))>"
          }
        case .error(let error):
          return "#<\(error.inlineDescription)>"
        case .syntax(_, let expr):
          return stringReprOf(expr)
      }
    }
    
    return stringReprOf(self)
  }
  
  internal static func escapeStr(_ str: String) -> String {
    var res = ""
    for c in str {
      switch c {
        case "\u{7}": res += "\\a"
        case "\u{8}": res += "\\b"
        case "\t":    res += "\\t"
        case "\n":    res += "\\n"
        case "\u{b}": res += "\\v"
        case "\u{c}": res += "\\f"
        case "\r":    res += "\\r"
        case "\"":    res += "\\\""
        case "\\":    res += "\\\\"
        default:      res.append(c)
      }
    }
    return res
  }
  
  public static func ==(lhs: Expr, rhs: Expr) -> Bool {
    return equalExpr(rhs, lhs)
  }
}

public typealias ByteVector = MutableBox<[UInt8]>
public typealias DoubleComplex = ImmutableBox<Complex<Double>>
