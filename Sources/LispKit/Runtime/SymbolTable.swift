//
//  SymbolTable.swift
//  LispKit
//
//  Created by Matthias Zenger on 23/01/2016.
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

///
/// Class `SymbolTable` implements the symbol table for LispKit. It is used for managing
/// symbols and their textual representations. Instances of `SymbolTable` provide functionality
/// for creating interned symbols for a given identifier and for looking up the identifier
/// of a given symbol.
///
public final class SymbolTable: Sequence {
  
  public struct Enumeration<T: Hashable> {
    private let name: Expr
    public let `default`: Symbol?
    private let unknown: (Symbol) throws -> T?
    private let values: [Symbol : T]
    private let symbols: [T : Symbol]
    
    public init(name: String,
                default: T?,
                unknown: @escaping (Symbol) throws -> T?,
                cases: [(Symbol, T)]) {
      var values: [Symbol : T] = [:]
      var symbols: [T : Symbol] = [:]
      for c in cases {
        values[c.0] = c.1
        symbols[c.1] = c.0
      }
      self.name = .makeString(name)
      self.default = `default` == nil ? nil : symbols[`default`!]
      self.unknown = unknown
      self.values = values
      self.symbols = symbols
    }
    
    public func symbolList() -> Expr {
      var res = Expr.null
      for sym in self.values.keys {
        res = .pair(.symbol(sym), res)
      }
      return res
    }
    
    public func valueList() -> [T] {
      var res: [T] = []
      for key in self.symbols.keys {
        res.append(key)
      }
      return res
    }
    
    public func isValue(_ expr: Expr) -> Bool {
      guard case .symbol(let sym) = expr else {
        return false
      }
      return (try? self.values[sym] ?? unknown(sym)) != nil
    }
    
    public func isKey(_ key: T) -> Bool {
      return self.symbols[key] != nil
    }
    
    public func expr(for value: T?) -> Expr {
      guard let value else {
        return .false
      }
      guard let sym = self.symbols[value] else {
        return .null
      }
      return .symbol(sym)
    }
    
    public func value(for expr: Expr, default: T? = nil) throws -> T {
      if expr.isFalse {
        if let `default` {
          return `default`
        } else if let sym = self.default {
          guard let value = self.values[sym] else {
            throw RuntimeError.eval(.invalidSymbolicEnumValue, self.name, expr)
          }
          return value
        }
      }
      guard case .symbol(let sym) = expr,
            let value = try self.values[sym] ?? unknown(sym) else {
        throw RuntimeError.eval(.invalidSymbolicEnumValue, self.name, expr)
      }
      return value
    }
    
    public func optValue(for expr: Expr) throws -> T? {
      guard expr.isTrue else {
        return nil
      }
      guard case .symbol(let sym) = expr,
            let value = self.values[sym] else {
        throw RuntimeError.eval(.invalidSymbolicEnumValue, self.name, expr)
      }
      return value
    }
  }
  
  @resultBuilder
  public struct EnumBuilder<T> {
    public static func buildBlock(_ components: [(String, T)]...) -> [(String, T)] {
      return components.flatMap { $0 }
    }
    
    public static func buildExpression(_ expression: (String, T)) -> [(String, T)] {
      return [expression]
    }
    
    public static func buildExpression(_ expression: [(String, T)]) -> [(String, T)] {
      return expression
    }
  }
  
  private let lock = EmbeddedUnfairLock()
  private var symTable = [String : Symbol]()
  private let gensymLock = EmbeddedUnfairLock()
  private var gensymCounter: UInt64 = 0
  
  public let dotdotdot       = Symbol("…")
  public let ellipsis        = Symbol("...")
  public let wildcard        = Symbol("_")
  public let append          = Symbol("append")
  public let cons            = Symbol("cons")
  public let list            = Symbol("list")
  public let quote           = Symbol("quote")
  public let quasiquote      = Symbol("quasiquote")
  public let unquote         = Symbol("unquote")
  public let unquoteSplicing = Symbol("unquote-splicing")
  public let doubleArrow     = Symbol("=>")
  public let `else`          = Symbol("else")
  public let `if`            = Symbol("if")
  public let lambda          = Symbol("lambda")
  public let `let`           = Symbol("let")
  public let letStar         = Symbol("let*")
  public let letrec          = Symbol("letrec")
  public let define          = Symbol("define")
  public let defineValues    = Symbol("define-values")
  public let makePromise     = Symbol("make-promise")
  public let makeStream      = Symbol("make-stream")
  public let begin           = Symbol("begin")
  public let `import`        = Symbol("import")
  public let export          = Symbol("export")
  public let exportMutable   = Symbol("export-mutable")
  public let extern          = Symbol("extern")
  public let rename          = Symbol("rename")
  public let only            = Symbol("only")
  public let except          = Symbol("except")
  public let prefix          = Symbol("prefix")
  public let library         = Symbol("library")
  public let and             = Symbol("and")
  public let or              = Symbol("or")
  public let not             = Symbol("not")
  public let condExpand      = Symbol("cond-expand")
  public let include         = Symbol("include")
  public let includeCi       = Symbol("include-ci")
  public let includeLibDecls = Symbol("include-library-declarations")
  public let scheme          = Symbol("scheme")
  public let r5rs            = Symbol("r5rs")
  public let r5rsSyntax      = Symbol("r5rs-syntax")
  public let starOne         = Symbol("*1")
  public let starTwo         = Symbol("*2")
  public let starThree       = Symbol("*3")
  public let void            = Symbol("void")
  public let endOfFile       = Symbol("end-of-file")
  public let null            = Symbol("null")
  public let boolean         = Symbol("boolean")
  public let symbol          = Symbol("symbol")
  public let fixnum          = Symbol("fixnum")
  public let bignum          = Symbol("bignum")
  public let rational        = Symbol("rational")
  public let flonum          = Symbol("flonum")
  public let complex         = Symbol("complex")
  public let char            = Symbol("char")
  public let string          = Symbol("string")
  public let bytevector      = Symbol("bytevector")
  public let pair            = Symbol("pair")
  public let mpair           = Symbol("mpair")
  public let array           = Symbol("array")
  public let vector          = Symbol("vector")
  public let gvector         = Symbol("gvector")
  public let values          = Symbol("values")
  public let procedure       = Symbol("procedure")
  public let parameter       = Symbol("parameter")
  public let promise         = Symbol("promise")
  public let syntax          = Symbol("syntax")
  public let environment     = Symbol("environment")
  public let hashtable       = Symbol("hashtable")
  public let port            = Symbol("port")
  public let inputPort       = Symbol("input-port")
  public let outputPort      = Symbol("output-port")
  public let recordType      = Symbol("record-type")
  public let error           = Symbol("error")
  public let integer         = Symbol("integer")
  public let real            = Symbol("real")
  public let number          = Symbol("number")
  public let box             = Symbol("box")
  public let object          = Symbol("object")
  
  public init() {
    self.registerNativeSymbols()
  }
  
  deinit {
    self.lock.release()
    self.gensymLock.release()
  }
  
  /// Register internally used symbols.
  public func registerNativeSymbols() {
    func register(_ sym: Symbol) {
      self.symTable[sym.identifier] = sym
    }
    register(self.ellipsis)
    register(self.wildcard)
    register(self.append)
    register(self.cons)
    register(self.list)
    register(self.quote)
    register(self.quasiquote)
    register(self.unquote)
    register(self.unquoteSplicing)
    register(self.doubleArrow)
    register(self.else)
    register(self.if)
    register(self.lambda)
    register(self.let)
    register(self.letStar)
    register(self.letrec)
    register(self.define)
    register(self.defineValues)
    register(self.makePromise)
    register(self.makeStream)
    register(self.begin)
    register(self.`import`)
    register(self.export)
    register(self.exportMutable)
    register(self.extern)
    register(self.rename)
    register(self.only)
    register(self.except)
    register(self.prefix)
    register(self.library)
    register(self.and)
    register(self.or)
    register(self.not)
    register(self.condExpand)
    register(self.include)
    register(self.includeCi)
    register(self.includeLibDecls)
    register(self.scheme)
    register(self.r5rs)
    register(self.r5rsSyntax)
    register(self.starOne)
    register(self.starTwo)
    register(self.starThree)
    register(self.endOfFile)
    register(self.null)
    register(self.boolean)
    register(self.symbol)
    register(self.fixnum)
    register(self.bignum)
    register(self.rational)
    register(self.flonum)
    register(self.complex)
    register(self.char)
    register(self.string)
    register(self.bytevector)
    register(self.pair)
    register(self.mpair)
    register(self.array)
    register(self.vector)
    register(self.gvector)
    register(self.values)
    register(self.procedure)
    register(self.parameter)
    register(self.promise)
    register(self.syntax)
    register(self.environment)
    register(self.hashtable)
    register(self.port)
    register(self.recordType)
    register(self.error)
    register(self.object)
  }
  
  /// Returns true if there is already an interned symbol for identifier `ident`.
  public func exists(_ ident: String) -> Bool {
    self.lock.lock()
    defer {
      self.lock.unlock()
    }
    return self.symTable[ident] != nil
  }
  
  /// Return a new interned symbol for the given identifier `ident`.
  public func intern(_ ident: String) -> Symbol {
    self.lock.lock()
    defer {
      self.lock.unlock()
    }
    if let sym = self.symTable[ident] {
      return sym
    } else {
      let sym = Symbol(ident)
      self.symTable[ident] = sym
      return sym
    }
  }
  
  /// Generates a new interned symbol.
  public func gensym(_ basename: String, intern: Bool = true) -> Symbol {
    self.gensymLock.lock()
    defer {
      self.gensymLock.unlock()
    }
    var ident: String
    repeat {
      ident = basename + String(self.gensymCounter)
      self.gensymCounter &+= 1
    } while self.exists(ident)
    return intern ? self.intern(ident) : Symbol(uninterned: ident)
  }
  
  /// Generates an interned symbol by concatenating `prefix` and `sym`.
  public func prefix(_ sym: Symbol, with prefix: Symbol) -> Symbol {
    return self.intern(prefix.identifier + sym.identifier)
  }
  
  /// Returns a generator for iterating over all symbols of this symbol table.
  public func makeIterator() -> AnyIterator<Symbol> {
    var generator = self.symTable.values.makeIterator()
    return AnyIterator { return generator.next() }
  }
  
  /// Reset symbol table.
  public func release() {
    self.symTable = [:]
    self.gensymCounter = 0
    self.registerNativeSymbols()
  }
  
  /// Returns a new symbolic enumeration.
  public func Enum<T: Hashable>(_ name: String,
                                _ default: T? = nil,
                                _ unknown: @escaping (Symbol) throws -> T? = { _ in nil },
                                @EnumBuilder<T> _ build: () -> [(String, T)]) -> Enumeration<T> {
    return Enumeration(name: name,
                       default: `default`,
                       unknown: unknown,
                       cases: build().map { (str, value) in (self.intern(str), value) })
  }
}
