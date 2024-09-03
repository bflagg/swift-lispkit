//
//  Code.swift
//  LispKit
//
//  Created by Matthias Zenger on 03/02/2016.
//  Copyright © 2016 ObjectHub. All rights reserved.
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

///
/// Class `Compiler` provides a framework for compiling LispKit expressions. Static method
/// `compile` invokes the compiler in a given environment and returns a `Code` object
/// which encapsulates the generated code.
/// 
public final class Compiler {
  
  /// Context in which this compiler is running
  public unowned let context: Context
  
  /// Set to the current syntax name
  internal var syntaxSym: Symbol? = nil
  
  /// Environment in which expressions should be compiled
  internal private(set) var env: Env
  
  /// Meta-environment in which macro expressions are evaluated
  internal let rulesEnv: Env
  
  /// Checkpointer for attaching information to help optimize the code in the second
  /// compilation phase.
  internal let checkpointer: Checkpointer
  
  /// Capture list
  private var captures: CaptureGroup!
  
  /// Current number of local values/variables
  internal var numLocals: Int = 0
  
  /// Maximum number of local values/variables
  private var maxLocals: Int = 0
  
  /// List of arguments
  private var arguments: BindingGroup?
  
  /// Constant pool
  private var constants: Exprs = []
  
  /// List of code fragments
  private var fragments: Fragments = []
  
  /// Instruction sequence
  private var instructions: Instructions = []
  
  /// Directory of the current source file
  internal private(set) var sourceDirectory: String
  
  /// Parent compiler (needed since `Compiler` objects are nested, e.g. if nested
  /// functions get compiled)
  public var parent: Compiler? {
    return self.captures.parent?.owner
  }
  
  /// Initializes a compiler object from the given context, environments, and checkpointer.
  private init(in env: Env,
               and rulesEnv: Env,
               usingCheckpointer cp: Checkpointer) {
    self.context = env.environment!.context
    self.env = env
    self.rulesEnv = rulesEnv
    self.checkpointer = cp
    self.arguments = nil
    self.sourceDirectory = env.environment!.context.fileHandler.currentDirectoryPath
    self.captures = CaptureGroup(owner: self, parent: env.bindingGroup?.owner.captures)
  }
  
  /// Compiles the given expression `expr` in the environment `env` and the rules environment
  /// `rulesEnv`. If `optimize` is set to true, the compiler will be invoked twice. The
  /// information collected in the first phase will be used to optimize the code in the second
  /// phase.
  public static func compile(expr: Expr,
                             in env: Env,
                             and rulesEnv: Env? = nil,
                             optimize: Bool = false,
                             inDirectory: String? = nil) throws -> Code {
    let checkpointer = Checkpointer()
    var compiler = Compiler(in: env,
                            and: rulesEnv ?? env,
                            usingCheckpointer: checkpointer)
    if let dir = inDirectory {
      compiler.sourceDirectory = dir
    }
    try compiler.compileBody(expr)
    if optimize {
      // log(checkpointer.description)
      checkpointer.reset()
      compiler = Compiler(in: env,
                          and: rulesEnv ?? env,
                          usingCheckpointer: checkpointer)
      if let dir = inDirectory {
        compiler.sourceDirectory = dir
      }
      try compiler.compileBody(expr)
      // log(checkpointer.description)
    }
    return compiler.bundle()
  }
  
  /// Expands the given expression `expr` in the environment `env` and the rules environment
  /// `rulesEnv` at the outermost expression. If the outermost expression does not refer to a
  /// macro, the function returns `nil`
  public static func macroExpand(expr: Expr,
                                 in env: Env,
                                 and rulesEnv: Env? = nil,
                                 inDirectory: String? = nil) throws -> Expr? {
    let compiler = Compiler(in: env,
                            and: rulesEnv ?? env,
                            usingCheckpointer: Checkpointer())
    if let dir = inDirectory {
      compiler.sourceDirectory = dir
    }
    return try compiler.macroExpand(expr, in: env)
  }
  
  /// Compiles the given list of arguments and returns the corresponding binding group as well
  /// as the remaining argument list
  private func collectArguments(_ arglist: Expr) -> (BindingGroup, Expr) {
    let arguments = BindingGroup(owner: self, parent: self.env)
    var next = arglist
    loop: while case .pair(let arg, let cdr) = next {
      switch arg {
        case .symbol(let sym):
          arguments.allocBindingFor(sym)
        default:
          break loop
      }
      next = cdr
    }
    return (arguments, next)
  }
  
  /// Compiles the given body of a function `expr` (or expression, if this compiler is not
  /// used to compile a function).
  /// When an `optionals` formal list of parameters is provided, the formals are matched
  /// against a list on the stack. The matching happens in the context of `optenv`. If
  /// `optenv` is not provided, the matching happens in the context of the environment
  /// constructed on top of `self.env`.
  /// When `localDefine` is set to true, local definitions are allowed.
  private func compileBody(_ expr: Expr,
                           optionals: Expr? = nil,
                           optenv: Env? = nil,
                           localDefine: Bool = false) throws {
    if expr.isNull {
      self.emit(.pushVoid)
      self.emit(.return)
    } else {
      // Reserve instruction for reserving local variables
      let reserveLocalIp = self.emitPlaceholder()
      // Turn arguments into local variables
      if let arguments = self.arguments {
        for sym in arguments.symbols {
          if let sym = sym, let binding = arguments.bindingFor(sym) , !binding.isValue {
            self.emit(.makeVariableArgument(binding.index))
          }
        }
      }
      // Compile body
      if let optionals = optionals {
        let initialLocals = self.numLocals
        let group = try self.compileOptionalBindings(optionals,
                                                     in: self.env,
                                                     optenv: optenv)
        let res = try self.compileSeq(expr,
                                      in: Env(group),
                                      inTailPos: true,
                                      localDefine: localDefine)
        if !self.finalizeBindings(group, exit: res, initialLocals: initialLocals) {
          self.emit(.return)
        }
      } else {
        if !(try compileSeq(expr, in: self.env, inTailPos: true, localDefine: localDefine)) {
          self.emit(.return)
        }
      }
      // Insert instruction to reserve local variables
      if self.maxLocals > self.arguments?.count ?? 0 {
        let n = self.maxLocals - (self.arguments?.count ?? 0)
        if optionals != nil {
          self.patch(.allocBelow(n), at: reserveLocalIp)
        } else {
          self.patch(.alloc(n), at: reserveLocalIp)
        }
      }
    }
    // Checkpoint argument mutability
    self.arguments?.finalize()
  }
  
  /// Allocates a new local value/variable.
  public func nextLocalIndex() -> Int {
    self.numLocals += 1
    if self.numLocals > self.maxLocals {
      self.maxLocals = self.numLocals
    }
    return self.numLocals - 1
  }
  
  /// Removes the last instruction from the instruction sequence.
  @discardableResult public func removeLastInstr() -> Int {
    self.instructions.removeLast()
    return self.instructions.count - 1
  }
  
  /// Appends the given instruction to the instruction sequence.
  @discardableResult public func emit(_ instr: Instruction) -> Int {
    self.instructions.append(instr)
    return self.instructions.count - 1
  }
  
  /// Replaces the instruction at the position `at` with the instruction `instr`.
  public func patch(_ instr: Instruction, at: Int) {
    self.instructions[at] = instr
  }
  
  /// Appends a placeholder instruction to the instruction sequence.
  @discardableResult public func emitPlaceholder() -> Int {
    return self.emit(.noOp)
  }
  
  /// Injects the name of a closure in form of an index into the constant pool into the
  /// `.makeClosure` operation.
  public func patchMakeClosure(_ nameIdx: Int) {
    guard let instr = self.instructions.last else {
      return
    }
    switch instr {
      case .makeClosure(-1, let n, let index):
        self.instructions[self.instructions.count - 1] = .makeClosure(nameIdx, n, index)
      case .pushProcedure(let i):
        guard nameIdx >= 0 && nameIdx < self.constants.count,
              case .symbol(let sym) = self.constants[nameIdx] else {
          return
        }
        if i >= 0 && i < self.constants.count,
           case .procedure(let proc) = self.constants[i],
           let newproc = proc.renamed(to: sym.description) {
          self.constants[i] = .procedure(newproc)
        }
      default:
        return
    }
  }
  
  /// Injects the name of a closure into the `.makeClosure` operation.
  public func patchMakeClosure(_ sym: Symbol) {
    guard let instr = self.instructions.last else {
      return
    }
    switch instr {
      case .makeClosure(-1, let n, let index):
        let nameIdx = self.registerConstant(.symbol(sym))
        self.instructions[self.instructions.count - 1] = .makeClosure(nameIdx, n, index)
      case .pushProcedure(let i):
        if i >= 0 && i < self.constants.count,
           case .procedure(let proc) = self.constants[i],
           let newproc = proc.renamed(to: sym.description) {
          self.constants[i] = .procedure(newproc)
        }
      default:
        return
    }
  }
  
  /// Calls a procedure on the stack with `n` arguments. Uses a tail call if `tail` is set
  /// to true.
  public func call(_ n: Int, inTailPos tail: Bool) -> Bool {
    if tail {
      self.emit(.tailCall(n))
      return true
    } else {
      self.emit(.call(n))
      return false
    }
  }
  
  /// Computes the offset between the next instruction and the given instruction pointer `ip`.
  public func offsetToNext(_ ip: Int) -> Int {
    return self.instructions.count - ip
  }
  
  /// Pushes the given expression onto the stack.
  public func pushConstant(_ expr: Expr) {
    self.emit(.pushConstant(self.registerConstant(expr)))
  }
  
  /// Pushes the given procedure onto the stack.
  public func pushProcedure(_ proc: Procedure) {
    self.emit(.pushProcedure(self.registerConstant(.procedure(proc))))
  }
  
  /// Attaches the given expression to the constant pool and returns the index into the constant
  /// pool. `registerConstant` makes sure that expressions are not added twice.
  public func registerConstant(_ expr: Expr) -> Int {
    for i in self.constants.indices {
      if eqExpr(expr, self.constants[i]) {
        return i
      }
    }
    self.constants.append(expr.datum)
    return self.constants.count - 1
  }
  
  /// Push the value of the given symbol in the given environment onto the stack.
  public func pushValueOf(_ sym: Symbol, in env: Env) throws {
    switch self.pushLocalValueOf(sym, in: env) {
      case .success:
        break // Nothing to do
      case .globalLookupRequired(let lexicalSym, let environment):
        let locRef = self.forceDefinedLocationRef(for: lexicalSym, in: environment)
        if case .immutableImport(let loc) = locRef {
          let value = self.context.heap.locations[loc]
          if value.isUndef {
            self.emit(.pushGlobal(locRef.location!))
          } else {
            try self.pushValue(value)
          }
        } else {
          self.emit(.pushGlobal(locRef.location!))
        }
      case .macroExpansionRequired(_):
        throw RuntimeError.eval(.illegalKeywordUsage, .symbol(sym))
    }
  }
  
  /// Result type of `pushLocalValueOf` method.
  public enum LocalLookupResult {
    
    /// `Success` indicates that a local value/variable was successfully pushed onto the stack
    case success
    
    /// `MacroExpansionRequired(proc)` indicates that the binding refers to a macro and the
    /// compiler needs to expand the expression with the macro expander procedure `proc`.
    case macroExpansionRequired(Procedure)
    
    /// `GlobalLookupRequired(gsym, genv)` indicates that a suitable binding wasn't found in the
    /// local environment and thus a lookup in the global environment `genv` needs to be made.
    /// Note that `gsym` and `sym` do not necessarily need to be the same due to the way how
    /// hygienic macro expansion is implemented.
    case globalLookupRequired(Symbol, Environment)
  }
  
  /// Pushes the value/variable bound to symbol `sym` in the local environment `env`. If this
  /// wasn't possible, the method returns an instruction on how to proceed.
  private func pushLocalValueOf(_ sym: Symbol, in env: Env) -> LocalLookupResult {
    var env = env
    // Iterate through the local binding groups until `sym` is found
    while case .local(let group) = env {
      if let binding = group.bindingFor(sym) {
        if case .macro(let proc) = binding.kind {
          return .macroExpansionRequired(proc)
        } else if group.owner === self {
          if binding.isValue {
            self.emit(.pushLocal(binding.index))
          } else {
            self.emit(.pushLocalValue(binding.index))
          }
        } else {
          let capturedIndex = self.captures.capture(binding, from: group)
          if binding.isValue {
            self.emit(.pushCaptured(capturedIndex))
          } else {
            self.emit(.pushCapturedValue(capturedIndex))
          }
        }
        return .success
      }
      env = group.parent
    }
    // If `sym` wasn't found, look into the lexical environment
    if let (lexicalSym, lexicalEnv) = sym.lexical {
      // If the lexical environment is a global environment, return that a global lookup is needed
      if case .global(_) = lexicalEnv {
        return .globalLookupRequired(sym, env.environment!)
      }
      // Find the new lexical symbol in the new lexcial environment
      let res = self.pushLocalValueOf(lexicalSym, in: lexicalEnv)
      // If this didn't succeed, return that a global lookup is needed
      guard case .globalLookupRequired(_, _) = res else {
        return res
      }
    }
    // Return global scope
    return .globalLookupRequired(sym, env.environment!)
  }
  
  /// Checks if the symbol `sym` is bound in the local environment `env`.
  private func lookupLocalValueOf(_ sym: Symbol, in env: Env) -> LocalLookupResult {
    var env = env
    // Iterate through the local binding groups until `sym` is found
    while case .local(let group) = env {
      if let binding = group.bindingFor(sym) {
        if case .macro(let proc) = binding.kind {
          return .macroExpansionRequired(proc)
        }
        return .success
      }
      env = group.parent
    }
    // If `sym` wasn't found, look into the lexical environment
    if let (lexicalSym, lexicalEnv) = sym.lexical {
      // If the lexical environment is a global environment, return that a global lookup is needed
      if case .global(_) = lexicalEnv {
        return .globalLookupRequired(sym, env.environment!)
      }
      // Find the new lexical symbol in the new lexcial environment
      let res = self.lookupLocalValueOf(lexicalSym, in: lexicalEnv)
      // If this didn't succeed, return that a global lookup is needed
      guard case .globalLookupRequired(_, _) = res else {
        return res
      }
    }
    // Return global scope
    return .globalLookupRequired(sym, env.environment!)
  }
  
  /// Generates instructions to push the given expression onto the stack.
  public func pushValue(_ value: Expr) throws {
    let expr = value.datum
    switch expr {
      case .undef, .uninit(_):
        self.emit(.pushUndef)
      case .void:
        self.emit(.pushVoid)
      case .eof:
        self.emit(.pushEof)
      case .null:
        self.emit(.pushNull)
      case .true:
        self.emit(.pushTrue)
      case .false:
        self.emit(.pushFalse)
      case .fixnum(let num):
        self.emit(.pushFixnum(num))
      case .bignum(let num):
        self.emit(.pushBignum(num))
      case .rational(.fixnum(let n), .fixnum(let d)):
        self.emit(.pushRat(Rational(n, d)))
      case .rational(.bignum(let n), .bignum(let d)):
        self.emit(.pushBigrat(Rational(n, d)))
      case .rational(_, _):
        preconditionFailure("incorrectly encoded rational number")
      case .flonum(let num):
        self.emit(.pushFlonum(num))
      case .complex(let num):
        self.emit(.pushComplex(num.value))
      case .char(let char):
        self.emit(.pushChar(char))
      case .symbol(_), .string(_), .bytes(_), .pair(_, _), .box(_), .mpair(_), .array(_),
           .vector(_), .record(_), .table(_), .promise(_), .procedure(_), .env(_),
           .port(_), .object(_), .tagged(_, _), .error(_):
        self.pushConstant(expr)
      case .special(_):
        throw RuntimeError.eval(.illegalKeywordUsage, expr)
      case .values(_):
        preconditionFailure("cannot push multiple values onto stack")
      case .syntax(_, _):
        preconditionFailure("cannot push syntax onto stack")
    }
  }
  
  /// Pushes the given list of expressions `expr` onto the stack. This method returns the
  /// number of expressions whose result has been stored on the stack.
  public func pushValues(_ expr: Expr) throws -> Int {
    var n = 0
    var next = expr
    while case .pair(let car, let cdr) = next {
      try self.pushValue(car)
      n += 1
      next = cdr
    }
    guard next.isNull else {
      throw RuntimeError.type(expr, expected: [.properListType])
    }
    return n
  }
  
  /// Bind symbol `sym` to the value on top of the stack in environment `env`.
  public func setValueOf(_ sym: Symbol, in env: Env) throws {
    switch self.setLocalValueOf(sym, in: env) {
      case .success:
        break; // Nothing to do
      case .globalLookupRequired(let lexicalSym, let environment):
        let ref = self.forceDefinedLocationRef(for: lexicalSym, in: environment)
        if case .repl = environment.kind {
          // allow re-assigning values to immutable imports if this happens in the REPL
        } else if ref.isImmutable {
          throw RuntimeError.eval(.bindingImmutable, .symbol(sym))
        }
        self.emit(.setGlobal(ref.location!))
      case .macroExpansionRequired(_):
        preconditionFailure("setting bindings should never trigger macro expansion")
    }
  }
  
  /// Bind symbol `sym` to the value on top of the stack assuming `lenv` is a local
  /// environment (i.e. the bindings are located on the stack). If this
  /// wasn't possible, the method returns an instruction on how to proceed.
  private func setLocalValueOf(_ sym: Symbol, in lenv: Env) -> LocalLookupResult {
    var env = lenv
    // Iterate through the local binding groups until `sym` is found
    while case .local(let group) = env {
      if let binding = group.bindingFor(sym) {
        if group.owner === self {
          self.emit(.setLocalValue(binding.index))
        } else {
          self.emit(.setCapturedValue(self.captures.capture(binding, from: group)))
        }
        binding.wasMutated()
        return .success
      }
      env = group.parent
    }
    // If `sym` wasn't found, look into the lexical environment
    if let (lexicalSym, lexicalEnv) = sym.lexical {
      // If the lexical environment is a global environment, return that a global lookup is needed
      if case .global(_) = lexicalEnv {
        return .globalLookupRequired(sym, env.environment!)
      }
      // Find the new lexical symbol in the new lexcial environment
      let res = self.setLocalValueOf(lexicalSym, in: lexicalEnv)
      // If this didn't succeed, return that a global lookup is needed
      guard case .globalLookupRequired(_, _) = res else {
        return res
      }
    }
    return .globalLookupRequired(sym, env.environment!)
  }
  
  private func locationRef(for sym: Symbol,
                           in environment: Environment) -> Environment.LocationRef {
    var environment = environment
    var res = environment.locationRef(for: sym)
    var sym = sym
    while case .undefined = res, let (lexicalSym, lexicalEnv) = sym.lexical {
      sym = lexicalSym
      environment = lexicalEnv.environment!
      res = environment.locationRef(for: sym)
    }
    return res
  }
  
  private func forceDefinedLocationRef(for sym: Symbol,
                                       in environment: Environment) -> Environment.LocationRef {
    var environment = environment
    var res = environment.locationRef(for: sym)
    var sym = sym
    while case .undefined = res, let (lexicalSym, lexicalEnv) = sym.lexical {
      sym = lexicalSym
      environment = lexicalEnv.environment!
      res = environment.locationRef(for: sym)
    }
    if case .undefined = res {
      return environment.forceDefinedLocationRef(for: sym)
    }
    return res
  }
  
  private func value(of sym: Symbol, in environment: Environment) -> Expr? {
    var environment = environment
    var res = environment[sym]
    var sym = sym
    while res == nil, let (lexicalSym, lexicalEnv) = sym.lexical {
      sym = lexicalSym
      environment = lexicalEnv.environment!
      res = environment[sym]
    }
    return res
  }
  
  /// Expand expression `expr` in environment `env`.
  private func expand(_ expr: Expr, in env: Env) throws -> Expr? {
    switch expr {
      case .pair(.symbol(let sym), let cdr):
        let cp = self.checkpointer.checkpoint()
        switch self.lookupLocalValueOf(sym, in: env) {
          case .success:
            return nil
          case .globalLookupRequired(let lexicalSym, let environment):
            if let value = self.checkpointer.fromGlobalEnv(cp) ??
                           value(of: lexicalSym, in: environment) {
              self.checkpointer.associate(.fromGlobalEnv(value), with: cp)
              switch value {
                case .special(let special):
                  switch special.kind {
                    case .primitive(_):
                      return nil
                    case .macro(let transformer):
                      let expanded = try
                        self.checkpointer.expansion(cp) ??
                      self.context.evaluator.machine.apply(.procedure(transformer),
                                                           to: .pair(cdr, .null))
                      self.checkpointer.associate(.expansion(expanded), with: cp)
                      // log("expanded = \(expanded)")
                      return expanded
                  }
                default:
                  return nil
              }
            } else {
              return nil
            }
          case .macroExpansionRequired(let transformer):
            let expanded = try self.context.evaluator.machine.apply(.procedure(transformer),
                                                                    to: .pair(cdr, .null))
            // log("expanded = \(expanded)")
            return expanded
        }
      default:
        return nil
    }
  }
  
  /// Expand expression `expr` in environment `env`.
  private func expand(_ expr: Expr, in env: Env, into: inout Exprs, depth: Int = 20) throws {
    guard depth > 0 else {
      into.append(expr)
      return
    }
    if case .pair(.symbol(let fun), let embedded) = expr,
       fun.root == self.context.symbols.begin,
       env.isImmutable(fun) {
      var lst = embedded
      while case .pair(let e, let next) = lst {
        try self.expand(e, in: env, into: &into, depth: depth)
        lst = next
      }
    } else if let expanded = try self.expand(expr, in: env) {
      try self.expand(expanded, in: env, into: &into, depth: depth - 1)
    } else {
      into.append(expr)
    }
  }
  
  /// Expand expression `expr` in environment `env`.
  public func macroExpand(_ expr: Expr, in env: Env) throws -> Expr? {
    switch expr {
      case .pair(.symbol(let sym), let cdr):
        switch self.lookupLocalValueOf(sym, in: env) {
          case .success:
            return nil
          case .globalLookupRequired(let lexicalSym, let environment):
            if case .special(let special) = self.value(of: lexicalSym, in: environment) {
              switch special.kind {
                case .primitive(_):
                  return nil
                case .macro(let transformer):
                  return try self.context.evaluator.machine.apply(.procedure(transformer),
                                                                  to: .pair(cdr, .null))
              }
            }
            return nil
          case .macroExpansionRequired(let transformer):
            return try self.context.evaluator.machine.apply(.procedure(transformer),
                                                            to: .pair(cdr, .null))
        }
      default:
        return nil
    }
  }
  
  /// Compile expression `expr` in environment `env`. Parameter `tail` specifies if `expr`
  /// is located in a tail position. This allows compile to generate code with tail calls.
  @discardableResult public func compile(_ expr: Expr,
                                         in env: Env,
                                         inTailPos tail: Bool) throws -> Bool {
    let cp = self.checkpointer.checkpoint()
    switch expr {
      case .null:
        throw RuntimeError.eval(.executeEmptyList)
      case .symbol(let sym):
        try self.pushValueOf(sym, in: env)
      case .pair(.symbol(let sym), let cdr):
        let pushFrameIp = self.emit(.makeFrame)
        // Try to push the function if locally defined
        switch self.pushLocalValueOf(sym, in: env) {
          case .success:
            break // Nothing to do
          case .globalLookupRequired(let lexicalSym, let environment):
            // Is there a special compiler plugin for this global binding, or is this a
            // keyword/special form)?
            if let value = self.checkpointer.fromGlobalEnv(cp) ??
                           self.value(of: lexicalSym, in: environment) {
              self.checkpointer.associate(.fromGlobalEnv(value), with: cp)
              switch value {
                case .procedure(let proc):
                  if case .primitive(_, _, .some(let formCompiler)) = proc.kind,
                     self.checkpointer.systemDefined(cp) || environment.isImmutable(lexicalSym) {
                    self.checkpointer.associate(.systemDefined, with: cp)
                    self.removeLastInstr()
                    return try formCompiler(self, expr, env, tail)
                  }
                case .special(let special):
                  self.removeLastInstr()
                  switch special.kind {
                    case .primitive(let formCompiler):
                      return try formCompiler(self, expr, env, tail)
                    case .macro(let transformer):
                      let expanded = try
                        self.checkpointer.expansion(cp) ??
                        self.context.evaluator.machine.apply(.procedure(transformer),
                                                             to: .pair(cdr, .null))
                      self.checkpointer.associate(.expansion(expanded), with: cp)
                      // log("expanded = \(expanded)")
                      return try self.compile(expanded, in: env, inTailPos: tail)
                  }
                default:
                  break // Compile as normal global function call
              }
            }
            // Push function from global binding
            let locRef = self.forceDefinedLocationRef(for: lexicalSym, in: environment)
            if case .immutableImport(let loc) = locRef {
              let value = self.context.heap.locations[loc]
              if value.isUndef {
                self.emit(.pushGlobal(loc))
              } else {
                try self.pushValue(value)
              }
            } else {
              self.emit(.pushGlobal(locRef.location!))
            }
          case .macroExpansionRequired(let transformer):
            let expanded = try self.context.evaluator.machine.apply(.procedure(transformer),
                                                                    to: .pair(cdr, .null))
            // log("expanded = \(expanded)")
            return try self.compile(expanded, in: env, inTailPos: tail)
        }
        // Push arguments and call function
        if self.call(try self.compileExprs(cdr, in: env), inTailPos: tail) {
          // Remove MakeFrame if this was a tail call
          self.patch(.noOp, at: pushFrameIp)
          return true
        }
      case .pair(.procedure(let proc), let cdr):
        let pushFrameIp = self.emit(.makeFrame)
        // Push function
        try self.pushValue(.procedure(proc))
        // Push arguments
        let n = proc == self.context.evaluator.loader
                  ? try self.pushValues(cdr)        
                  : try self.compileExprs(cdr, in: env)
        // Call procedure
        if self.call(n, inTailPos: tail) {
          // Remove MakeFrame if this was a tail call
          self.patch(.noOp, at: pushFrameIp)
          return true
        }
      case .pair(let car, let cdr):
        let pushFrameIp = self.emit(.makeFrame)
        // Push function
        try self.compile(car, in: env, inTailPos: false)
        // Push arguments and call function
        if self.call(try self.compileExprs(cdr, in: env), inTailPos: tail) {
          // Remove MakeFrame if this was a tail call
          self.patch(.noOp, at: pushFrameIp)
          return true
        }
      default:
        try self.pushValue(expr)
    }
    return false
  }
  
  /// Compile the given list of expressions `expr` in environment `env` and push each result
  /// onto the stack. This method returns the number of expressions that were evaluated and
  /// whose result has been stored on the stack.
  public func compileExprs(_ expr: Expr, in env: Env) throws -> Int {
    var n = 0
    var next = expr
    while case .pair(let car, let cdr) = next {
      try self.compile(car, in: env, inTailPos: false)
      n += 1
      next = cdr
    }
    guard next.isNull else {
      throw RuntimeError.type(expr, expected: [.properListType])
    }
    return n
  }
  
  /// Returns `nil` if `sym` does not refer to any definition special form. Returns `true` if
  /// `sym` refers to special form `define`. Returns `false` if `sym` refers to special form
  /// `defineValues`.
  private func refersToDefine(_ sym: Symbol, in env: Env) -> Bool? {
    // This is the old logic; kept it here as a fallback if `define` is not available via the
    // corresponding virtual machine
    if self.context.evaluator.defineSpecial == nil {
      let root = sym.root
      if env.isImmutable(sym) {
        if root == self.context.symbols.define {
          return true
        } else if root == self.context.symbols.defineValues {
          return false
        }
      }
      return nil
    // This is the correct logic that determines if `sym` refers to a definition special
    // form or not
    } else {
      switch self.lookupLocalValueOf(sym, in: env) {
        case .globalLookupRequired(let glob, let environment):
          if let expr = self.value(of: glob, in: environment),
             case .special(let special) = expr {
            if special == self.context.evaluator.defineSpecial {
              return true
            } else if special == self.context.evaluator.defineValuesSpecial {
              return false
            }
          }
          fallthrough
        default:
          return nil
      }
    }
  }
  
  /// Compile the sequence of expressions `expr` in environment `env`. Parameter `tail`
  /// specifies if `expr` is located in a tail position. This allows the compiler to generate
  /// code with tail calls.
  @discardableResult public func compileSeq(_ expr: Expr,
                                            in env: Env,
                                            inTailPos tail: Bool,
                                            localDefine: Bool = true,
                                            inDirectory: String? = nil) throws -> Bool {
    // Return void for empty sequences
    guard !expr.isNull else {
      self.emit(.pushVoid)
      return false
    }
    // Override the source directory if the code comes from a different file
    let oldDir = self.sourceDirectory
    if let dir = inDirectory {
      self.sourceDirectory = dir
    }
    defer {
      self.sourceDirectory = oldDir
    }
    // Partially expand expressions in the sequence
    var next = expr
    var exprs = Exprs()
    while case .pair(let car, let cdr) = next {
      if localDefine {
        try self.expand(car, in: env, into: &exprs)
      } else {
        exprs.append(car)
      }
      next = cdr
    }
    // Throw error if the sequence is not a proper list
    guard next.isNull else {
      throw RuntimeError.type(expr, expected: [.properListType])
    }
    // Identify internal definitions
    var i = 0
    var bindings = Exprs()
    if localDefine {
      loop: while i < exprs.count {
        guard case .pair(.symbol(let fun), let binding) = exprs[i],
              let isDefine = self.refersToDefine(fun, in: env) else {
          break loop
        }
        // Distinguish value definitions from function definitions
        if isDefine {
          switch binding {
            case .pair(.symbol(let sym), .pair(let def, .null)):
              bindings.append(.pair(.pair(.symbol(sym), .null), .pair(def, .null)))
            case .pair(.pair(.symbol(let sym), let args), let def):
              bindings.append(
                .pair(.pair(.symbol(sym), .null),
                      .pair(.pair(.symbol(Symbol(self.context.symbols.lambda, env.global)),
                                  .pair(args, def)),
                            .null)))
            default:
              break loop
          }
        // Handle multi-value definitions
        } else {
          switch binding {
            case .pair(.null, .pair(let def, .null)):
              bindings.append(.pair(.null, .pair(def, .null)))
            case .pair(.pair(.symbol(let sym), let more), .pair(let def, .null)):
              bindings.append(.pair(.pair(.symbol(sym), more), .pair(def, .null)))
            default:
              break loop
          }
        }
        i += 1
      }
    }
    // Compile the sequence
    var exit = false
    if i == 0 {
      // Compilation with no internal definitions
      if exprs.isEmpty {
        // There are no expressions left
        self.emit(.pushVoid)
      } else {
        // Compile sequence of expressions
        while i < exprs.count {
          if i > 0 {
            self.emit(.pop)
          }
          exit = try self.compile(exprs[i], in: env, inTailPos: tail && (i == exprs.count - 1))
          i += 1
        }
      }
      return exit
    } else {
      // Compilation with internal definitions
      let initialLocals = self.numLocals
      let group = try self.compileMultiBindings(.makeList(bindings),
                                                in: env,
                                                atomic: true,
                                                predef: true)
      let lenv = Env(group)
      var first = true
      while i < exprs.count {
        if !first {
          self.emit(.pop)
        }
        exit = try self.compile(exprs[i], in: lenv, inTailPos: tail && (i == exprs.count - 1))
        first = false
        i += 1
      }
      // Push void in case there is no non-define expression left
      if first {
        self.emit(.pushVoid)
      }
      return self.finalizeBindings(group, exit: exit, initialLocals: initialLocals)
    }
  }
  
  /// Compiles the given binding list of the form
  /// ```((ident init) ...)```
  /// and returns a `BindingGroup` with information about the established local bindings.
  public func compileBindings(_ bindingList: Expr,
                              in lenv: Env,
                              atomic: Bool,
                              predef: Bool,
                              postset: Bool = false) throws -> BindingGroup {
    let group = BindingGroup(owner: self, parent: lenv)
    let env = atomic && !predef ? lenv : .local(group)
    var bindings = bindingList
    if predef || postset {
      while case .pair(.pair(.symbol(let sym), _), let rest) = bindings {
        let binding = group.allocBindingFor(sym)
        // This is a hack for now; we need to make sure forward references work, e.g. in
        // lambda expressions. A way to do this is to allocate variables for all bindings that
        // are predefined.
        binding.wasMutated()
        self.emit(.pushUndef)
        self.emit(binding.isValue ? .setLocal(binding.index) : .makeLocalVariable(binding.index))
        bindings = rest
      }
      bindings = bindingList
    }
    var definitions: [Definition] = []
    var prevIndex = -1
    while case .pair(let binding, let rest) = bindings {
      guard case .pair(.symbol(let sym), .pair(let expr, .null)) = binding else {
        throw RuntimeError.eval(.malformedBinding, binding, bindingList)
      }
      try self.compile(expr, in: env, inTailPos: false)
      self.patchMakeClosure(sym)
      let binding = group.allocBindingFor(sym)
      guard !atomic || (predef && !postset) || binding.index > prevIndex else {
        throw RuntimeError.eval(.duplicateBinding, .symbol(sym), bindingList)
      }
      if postset {
        definitions.append(binding)
      } else if binding.isValue {
        self.emit(.setLocal(binding.index))
      } else if predef {
        self.emit(.setLocalValue(binding.index))
      } else {
        self.emit(.makeLocalVariable(binding.index))
      }
      prevIndex = binding.index
      bindings = rest
    }
    guard bindings.isNull else {
      throw RuntimeError.eval(.malformedBindings, bindingList)
    }
    for binding in definitions.reversed() {
      if binding.isValue {
        self.emit(.setLocal(binding.index))
      } else {
        self.emit(.setLocalValue(binding.index))
      }
    }
    return group
  }
  
  /// Compiles the given binding list of the form
  /// ```(((ident ...) init) ...)```
  /// and returns a `BindingGroup` with information about the established local bindings.
  public func compileMultiBindings(_ bindingList: Expr,
                                   in lenv: Env,
                                   atomic: Bool,
                                   predef: Bool = false) throws -> BindingGroup {
    let group = BindingGroup(owner: self, parent: lenv)
    let env = atomic && !predef ? lenv : .local(group)
    var bindings = bindingList
    if predef {
      while case .pair(.pair(let variables, _), let rest) = bindings {
        var vars = variables
        while case .pair(.symbol(let sym), let more) = vars {
          let binding = group.allocBindingFor(sym)
          // This is a hack for now; we need to make sure forward references work, e.g. in
          // lambda expressions. A way to do this is to allocate variables for all bindings that
          // are predefined.
          binding.wasMutated()
          self.emit(.pushUndef)
          self.emit(binding.isValue ? .setLocal(binding.index) : .makeLocalVariable(binding.index))
          vars = more
        }
        bindings = rest
      }
      bindings = bindingList
    }
    var prevIndex = -1
    while case .pair(let binding, let rest) = bindings {
      guard case .pair(let variables, .pair(let expr, .null)) = binding else {
        throw RuntimeError.eval(.malformedBinding, binding, bindingList)
      }
      try self.compile(expr, in: env, inTailPos: false)
      var vars = variables
      var syms = [Symbol]()
      while case .pair(.symbol(let sym), let rest) = vars {
        syms.append(sym)
        vars = rest
      }
      switch vars {
        case .null:
          if syms.count == 1 {
            self.patchMakeClosure(syms[0])
          } else {
            self.emit(.unpack(syms.count, false))
          }
        case .symbol(let sym):
          self.emit(.unpack(syms.count, true))
          let binding = group.allocBindingFor(sym)
          if binding.isValue {
            self.emit(.setLocal(binding.index))
          } else if predef {
            self.emit(.setLocalValue(binding.index))
          } else {
            self.emit(.makeLocalVariable(binding.index))
          }
          prevIndex = binding.index
        default:
          throw RuntimeError.eval(.malformedBinding, binding, bindingList)
      }
      for sym in syms.reversed() {
        let binding = group.allocBindingFor(sym)
        guard predef || binding.index > prevIndex else {
          throw RuntimeError.eval(.duplicateBinding, .symbol(sym), bindingList)
        }
        if binding.isValue {
          self.emit(.setLocal(binding.index))
        } else if predef {
          self.emit(.setLocalValue(binding.index))
        } else {
          self.emit(.makeLocalVariable(binding.index))
        }
        prevIndex = binding.index
      }
      bindings = rest
    }
    guard bindings.isNull else {
      throw RuntimeError.eval(.malformedBindings, bindingList)
    }
    return group
  }
  
  func compileOptionalBindings(_ bindingList: Expr,
                               in lenv: Env,
                               optenv: Env?) throws -> BindingGroup {
    let group = BindingGroup(owner: self, parent: lenv)
    let env = optenv ?? .local(group)
    var bindings = bindingList
    var prevIndex = -1
    while case .pair(.symbol(let sym), let rest) = bindings {
      self.emit(.decons)
      let binding = group.allocBindingFor(sym)
      guard binding.index > prevIndex else {
        throw RuntimeError.eval(.duplicateBinding, .symbol(sym), bindingList)
      }
      if binding.isValue {
        self.emit(.setLocal(binding.index))
      } else {
        self.emit(.makeLocalVariable(binding.index))
      }
      prevIndex = binding.index
      bindings = rest
    }
    while case .pair(let binding, let rest) = bindings {
      guard case .pair(.symbol(let sym), .pair(let expr, .null)) = binding else {
        throw RuntimeError.eval(.malformedBinding, binding, bindingList)
      }
      self.emit(.dup)
      self.emit(.isNull)
      let branchIfIp = self.emitPlaceholder()
      self.emit(.decons)
      let branchIp = self.emitPlaceholder()
      self.patch(.branchIf(self.offsetToNext(branchIfIp)), at: branchIfIp)
      try self.compile(expr, in: env, inTailPos: false)
      self.patch(.branch(self.offsetToNext(branchIp)), at: branchIp)
      let binding = group.allocBindingFor(sym)
      guard binding.index > prevIndex else {
        throw RuntimeError.eval(.duplicateBinding, .symbol(sym), bindingList)
      }
      if binding.isValue {
        self.emit(.setLocal(binding.index))
      } else {
        self.emit(.makeLocalVariable(binding.index))
      }
      prevIndex = binding.index
      bindings = rest
    }
    switch bindings {
      case .null:
        self.emit(.failIfNotNull)
      case .symbol(let sym):
        let binding = group.allocBindingFor(sym)
        guard binding.index > prevIndex else {
          throw RuntimeError.eval(.duplicateBinding, .symbol(sym), bindingList)
        }
        if binding.isValue {
          self.emit(.setLocal(binding.index))
        } else {
          self.emit(.makeLocalVariable(binding.index))
        }
      default:
        throw RuntimeError.eval(.malformedBindings, bindingList)
    }
    return group
  }
  
  /// This function should be used for finalizing the compilation of blocks with local
  /// bindings. It finalizes the binding group and resets the local bindings so that the
  /// garbage collector can deallocate the objects that are not used anymore.
  public func finalizeBindings(_ group: BindingGroup, exit: Bool, initialLocals: Int) -> Bool {
    group.finalize()
    if !exit && self.numLocals > initialLocals {
      self.emit(.reset(initialLocals, self.numLocals - initialLocals))
    }
    self.numLocals = initialLocals
    return exit
  }
  
  /// Binds a list of keywords to macro transformers in the given local environment `lenv`.
  /// If `recursive` is set to true, the macro transformers are evaluated in an environment that
  /// includes their own definition.
  public func compileMacros(_ bindingList: Expr,
                            in lenv: Env,
                            recursive: Bool) throws -> BindingGroup {
    var numMacros = 0
    let group = BindingGroup(owner: self, parent: lenv, nextIndex: {
      numMacros += 1
      return numMacros - 1
    })
    let env = recursive ? Env(group) : lenv
    var bindings = bindingList
    while case .pair(let binding, let rest) = bindings {
      guard case .pair(.symbol(let sym), .pair(let transformer, .null)) = binding else {
        throw RuntimeError.eval(.malformedBinding, binding, bindingList)
      }
      let procExpr = try self.context.evaluator.machine.compileAndEval(expr: transformer,
                                                                       in: env.syntacticalEnv,
                                                                       usingRulesEnv: env)
      guard case .procedure(let proc) = procExpr else {
        throw RuntimeError.eval(.malformedTransformer, transformer) //FIXME: Find better error message
      }
      guard group.bindingFor(sym) == nil else {
        throw RuntimeError.eval(.duplicateBinding, .symbol(sym), bindingList)
      }
      group.defineMacro(sym, proc: proc)
      bindings = rest
    }
    guard bindings.isNull else {
      throw RuntimeError.eval(.malformedBindings, bindingList)
    }
    return group
  }
  
  /// Compiles a closure consisting of a list of formal arguments `arglist`, a list of
  /// expressions `body`, and a local environment `env`. It puts the closure on top of the
  /// stack.
  /// When `optionals` is set to true, optional parameters are supported.
  /// When `atomic` is set to true, defaults of optional parameters are evaluated in `env`.
  /// When `tagged` is set to true, it is assumed a tag is on the stack and this tag is stored
  /// in the resulting closure.
  /// When `continuation` is set to true, the resulting closure is represented as a continuation.
  public func compileLambda(_ nameIdx: Int?,
                            _ arglist: Expr,
                            _ body: Expr,
                            _ env: Env,
                            optionals: Bool = false,
                            atomic: Bool = true,
                            tagged: Bool = false,
                            continuation: Bool = false) throws {
    // Create closure compiler as child of the current compiler
    let closureCompiler = Compiler(in: env,
                                   and: env,
                                   usingCheckpointer: self.checkpointer)
    // Compile arguments
    let (arguments, next) = closureCompiler.collectArguments(arglist)
    switch next {
      case .null:
        // Handle arguments
        closureCompiler.emit(.assertArgCount(arguments.count))
        closureCompiler.arguments = arguments
        closureCompiler.env = .local(arguments)
        // Compile body
        try closureCompiler.compileBody(body, localDefine: true)
      case .symbol(let sym):
        // Handle arguments
        if arguments.count > 0 {
          closureCompiler.emit(.assertMinArgCount(arguments.count))
        }
        closureCompiler.emit(.collectRest(arguments.count))
        arguments.allocBindingFor(sym)
        closureCompiler.arguments = arguments
        closureCompiler.env = .local(arguments)
        // Compile body
        try closureCompiler.compileBody(body, localDefine: true)
      case .pair(.pair(.symbol(_), _), _):
        // Handle arguments
        if arguments.count > 0 {
          closureCompiler.emit(.assertMinArgCount(arguments.count))
        }
        closureCompiler.emit(.collectRest(arguments.count))
        closureCompiler.arguments = arguments
        closureCompiler.env = .local(arguments)
        // Compile body
        try closureCompiler.compileBody(body,
                                        optionals: next,
                                        optenv: atomic ? env : nil,
                                        localDefine: true)
      default:
        throw RuntimeError.eval(.malformedArgumentList, arglist)
    }
    // Link compiled closure in the current compiler
    let codeIndex = self.fragments.count
    let code = closureCompiler.bundle()
    // Try to create procedure statically and store in constant pool
    if !tagged && !continuation && closureCompiler.captures.count == 0 {
      let type: Procedure.ClosureType
      if let idx = nameIdx, case .symbol(let sym) = self.constants[idx] {
        type = .named(sym.description)
      } else {
        type = .anonymous
      }
      self.pushProcedure(Procedure(type, [], code))
    } else {
      // Store code fragment
      self.fragments.append(code)
      // Generate code for pushing captured bindings onto the stack
      for def in closureCompiler.captures.definitions {
        if let def = def, let capture = closureCompiler.captures.captureFor(def) {
          if capture.origin.owner === self {
            self.emit(.pushLocal(def.index))
          } else {
            self.emit(.pushCaptured(self.captures.capture(def, from: capture.origin)))
          }
        }
      }
      // Return captured binding count and index of compiled closure
      if tagged {
        self.emit(.makeTaggedClosure(nameIdx ?? (continuation ? -2 : -1),
                                     closureCompiler.captures.count,
                                     codeIndex))
      } else {
        self.emit(.makeClosure(nameIdx ?? (continuation ? -2 : -1),
                               closureCompiler.captures.count,
                               codeIndex))
      }
    }
  }
  
  /// Compiles a closure consisting of a list of formal arguments `arglist`, a list of
  /// expressions `body`, and a local environment `env`. It puts the closure on top of the
  /// stack.
  public func compileCaseLambda(_ nameIdx: Int?,
                                _ cases: Expr,
                                _ env: Env,
                                tagged: Bool = false) throws {
    // Create closure compiler as child of the current compiler
    let closureCompiler = Compiler(in: env,
                                   and: env,
                                   usingCheckpointer: self.checkpointer)
    // Iterate through all cases
    var current = cases
    loop: while case .pair(.pair(let args, let body), let nextCase) = current {
      // Reset compiler
      closureCompiler.env = env
      closureCompiler.numLocals = 0
      closureCompiler.maxLocals = 0
      closureCompiler.arguments = nil
      // Compile arguments
      let (arguments, next) = closureCompiler.collectArguments(args)
      var exactIp = -1
      var minIp = -1
      let numArgs = arguments.count
      switch next {
        case .null:
          exactIp = closureCompiler.emitPlaceholder()
        case .symbol(let sym):
          if arguments.count > 0 {
            minIp = closureCompiler.emitPlaceholder()
          }
          closureCompiler.emit(.collectRest(arguments.count))
          arguments.allocBindingFor(sym)
        default:
          throw RuntimeError.eval(.malformedArgumentList, args)
      }
      closureCompiler.arguments = arguments
      closureCompiler.env = .local(arguments)
      // Compile body
      try closureCompiler.compileBody(body)
      // Fix jumps
      if exactIp >= 0 {
        closureCompiler.patch(
          .branchIfArgMismatch(numArgs, closureCompiler.offsetToNext(exactIp)), at: exactIp)
      } else if minIp >= 0 {
        closureCompiler.patch(
          .branchIfMinArgMismatch(numArgs, closureCompiler.offsetToNext(minIp)), at: minIp)
      } else {
        break loop
      }
      // Move to next case
      current = nextCase
    }
    // Compile final "else" case
    switch current {
      case .pair(.pair(_, _), _):
        break // early exit
      case .null:
        closureCompiler.emit(.noMatchingArgCount)
      default:
        throw RuntimeError.eval(.malformedCaseLambda, current)
    }
    // Link compiled closure in the current compiler
    let codeIndex = self.fragments.count
    let code = closureCompiler.bundle()
    // Try to create procedure statically and store in constant pool
    if !tagged && closureCompiler.captures.count == 0 {
      let type: Procedure.ClosureType
      if let idx = nameIdx, case .symbol(let sym) = self.constants[idx] {
        type = .named(sym.description)
      } else {
        type = .anonymous
      }
      self.pushProcedure(Procedure(type, [], code))
    } else {
      // Store code fragment
      self.fragments.append(code)
      // Generate code for pushing captured bindings onto the stack
      for def in closureCompiler.captures.definitions {
        if let def = def, let capture = closureCompiler.captures.captureFor(def) {
          if capture.origin.owner === self {
            self.emit(.pushLocal(def.index))
          } else {
            self.emit(.pushCaptured(self.captures.capture(def, from: capture.origin)))
          }
        }
      }
      // Return captured binding count and index of compiled closure
      if tagged {
        self.emit(.makeTaggedClosure(nameIdx ?? -1,
                                     closureCompiler.captures.count,
                                     codeIndex))
      } else {
        self.emit(.makeClosure(nameIdx ?? -1,
                               closureCompiler.captures.count,
                               codeIndex))
      }
    }
  }
  
  /// Bundles the code generated by this compiler into a `Code` object.
  public func bundle() -> Code {
    // Performce peephole optimization
    self.optimize()
    // Create code object
    return Code(self.instructions, self.constants, self.fragments)
  }
  
  /// This is a simple peephole optimizer. For now, it eliminates NOOPs and combinations
  /// of PUSH/POP.
  private func optimize() {
    var instrIndex: [Int] = []
    var numInstr = 0
    var ip = 0
    while ip < self.instructions.count {
      instrIndex.append(numInstr)
      switch self.instructions[ip] {
        case .noOp:
          ip += 1
        case .pushNull, .pushVoid, .pushTrue,  .pushFalse, .pushUndef, .pushEof, .pushFixnum(_),
             .pushFlonum(_), .pushChar(_), .pushBignum(_), .pushBigrat(_), .pushComplex(_),
             .pushCaptured(_), .pushConstant(_), .pushProcedure(_), .pushLocalValue(_),
             .pushCapturedValue(_):
          if ip + 1 < self.instructions.count, case .pop = self.instructions[ip + 1] {
            instrIndex.append(numInstr)
            self.instructions[ip] = .noOp
            self.instructions[ip + 1] = .noOp
            ip += 2
            continue
          }
          fallthrough
        default:
          ip += 1
          numInstr += 1
      }
    }
    ip = 0
    while ip < self.instructions.count {
      switch self.instructions[ip] {
        case .branch(let offset):
          switch self.instructions[ip + offset] {
            case .tailCall(let n):
              self.instructions[ip] = .tailCall(n)
            case .return:
              self.instructions[ip] = .return
            case .branch(let offset2):
              self.instructions[ip] = .branch(instrIndex[ip + offset + offset2] - instrIndex[ip])
            default:
              self.instructions[ip] = .branch(instrIndex[ip + offset] - instrIndex[ip])
          }
        case .branchIf(let offset):
          self.instructions[ip] = .branchIf(instrIndex[ip + offset] - instrIndex[ip])
        case .branchIfNot(let offset):
          self.instructions[ip] = .branchIfNot(instrIndex[ip + offset] - instrIndex[ip])
        case .keepOrBranchIfNot(let offset):
          self.instructions[ip] = .keepOrBranchIfNot(instrIndex[ip + offset] - instrIndex[ip])
        case .branchIfArgMismatch(let n, let offset):
          self.instructions[ip] = .branchIfArgMismatch(n, instrIndex[ip + offset] - instrIndex[ip])
        case .branchIfMinArgMismatch(let n, let offset):
          self.instructions[ip] = .branchIfMinArgMismatch(n, instrIndex[ip + offset] -
                                                               instrIndex[ip])
        case .or(let offset):
          self.instructions[ip] = .or(instrIndex[ip + offset] - instrIndex[ip])
        case .and(let offset):
          self.instructions[ip] = .and(instrIndex[ip + offset] - instrIndex[ip])
        default:
          break
      }
      ip += 1
    }
    ip = 0
    while ip < self.instructions.count {
      if case .noOp = self.instructions[ip] {
        self.instructions.remove(at: ip)
      } else {
        ip += 1
      }
    }
  }
}
