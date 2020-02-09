//
//  Thread.swift
//  LispKit
//
//  Created by Matthias Zenger on 02/02/2020.
//  Copyright © 2020 ObjectHub. All rights reserved.
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

public final class Thread: NativeObject {

  public enum State {
    case new
    case runnable
    case terminated
    case blocked(Double, Thread?)
    case paused
  }

  /// Type representing threads.
  public static let type = Type.objectType(Symbol(uninterned: "thread"))

  /// The evaluator which owns this thread.
  unowned let evaluator: Evaluator

  /// The name of the thread.
  let name: Expr?

  /// The specific field.
  var specific: Expr

  /// The result field.
  var result: Expr

  /// The error field.
  var error: Expr

  /// The state of the thread.
  var state: State

  /// The virtual machine executing this thread.
  let machine: VirtualMachine

  /// The completion handler.
  var completionHandler: (Expr) -> State

  /// The error handler.
  var errorHandler: (RuntimeError) -> State

  /// The thread to join
  var join: Thread?

  /// The previous thread.
  unowned var prev: Thread?

  /// The next thread.
  var next: Thread?

  /// Thread initializer
  init(evaluator: Evaluator,
       name: Expr? = nil,
       machine: VirtualMachine,
       completionHandler: @escaping (Expr) -> State,
       errorHandler: @escaping (RuntimeError) -> State) {
    self.evaluator = evaluator
    self.name = name
    self.specific = .undef
    self.result = .undef
    self.error = .undef
    self.state = .new
    self.machine = machine
    self.completionHandler = completionHandler
    self.errorHandler = errorHandler
    self.join = nil
    self.prev = nil
    self.next = nil
  }

  public override var type: Type {
    return Self.type
  }

  public override var string: String {
    return "#<\(self.type) \(self.name?.description ?? self.identityString)>"
  }

  public func run() -> State {
    switch self.state {
      case .runnable, .blocked(_, _):
        break
      default:
        return self.state
    }
    do {
      if case .blocked(let max, let joinOpt) = self.state {
        if Date().timeIntervalSince1970 >= max {

        }
        if let join = joinOpt {

        }
      }
      let res = try self.machine.execute()
      if self.evaluator.abortionRequested {
        throw RuntimeError.abortion(stackTrace: self.machine.getStackTrace())
      } else if let res = res {
        self.result = res
        return self.completionHandler(res)
      } else {
        return .runnable
      }
    } catch let err as RuntimeError {
      if err.stackTrace == nil {
        err.attach(stackTrace: self.machine.getStackTrace())
      }
      self.error = .error(err)
      return self.errorHandler(err)
    } catch let nserr as NSError {
      let err = RuntimeError.os(nserr).attach(stackTrace: self.machine.getStackTrace())
      self.error = .error(err)
      return self.errorHandler(err)
    }
  }

  public func execute(_ code: Code) throws -> Expr {
    return try self.execute(proc: Procedure(code), code: code, args: 0, captured: noExprs)
  }

  public func execute(_ code: Code, as name: String) throws -> Expr {
    return try self.execute(proc: Procedure(name, code),
                            code: code,
                            args: 0,
                            captured: noExprs)
  }

  public func execute(proc: Procedure? = nil,
                      code: Code?,
                      args: Int,
                      captured: Exprs) throws -> Expr {
    let savedState = self.state
    var savedRegisters: VirtualMachine.Registers? = nil
    if let code = code {
      savedRegisters = self.machine.repurpose(proc: proc,
                                              code: code,
                                              args: args,
                                              captured: captured)
    }
    let savedCompletionHandler = self.completionHandler
    let savedErrorHandler = self.errorHandler
    let savedResult = self.result
    let savedError = self.error
    var result: Expr? = nil
    var error: RuntimeError? = nil
    self.completionHandler = { res in
      result = res
      self.completionHandler = savedCompletionHandler
      self.errorHandler = savedErrorHandler
      if let savedRegisters = savedRegisters {
        _ = self.machine.repurpose(savedRegisters)
      }
      self.result = savedResult
      self.error = savedError
      return savedState
    }
    self.errorHandler = { err in
      error = err
      self.completionHandler = savedCompletionHandler
      self.errorHandler = savedErrorHandler
      if let savedRegisters = savedRegisters {
        _ = self.machine.repurpose(savedRegisters)
      }
      self.result = savedResult
      self.error = savedError
      return savedState
    }
    self.state = .runnable
    self.evaluator.execute(until: { result != nil || error != nil })
    if let error = error {
      throw error
    } else if let result = result {
      return result
    } else {
      return .void
    }
  }

  /// Compiles the given expression `expr` in the environment `env` and executes it using
  /// this virtual machine.
  public func eval(expr: Expr,
                   in env: Env,
                   as name: String? = nil,
                   usingRulesEnv renv: Env? = nil,
                   optimize: Bool = true,
                   inDirectory: String? = nil) throws -> Expr {
    let code = try Compiler.compile(expr: .makeList(expr),
                                    in: env,
                                    and: renv,
                                    on: self,
                                    optimize: optimize,
                                    inDirectory: inDirectory)
    let proc = name == nil ? Procedure(code) : Procedure(name!, code)
    return try self.apply(.procedure(proc), to: .null)
  }

  /// Applies the given function `fun` to the given arguments `args`.
  public func apply(_ fun: Expr, to args: Expr) throws -> Expr {
    let (proc, n) = try self.machine.pushAndInvoke(fun, to: args)
    switch proc.kind {
      case .closure(_, let captured, let code):
        return try self.execute(code: code, args: n, captured: captured)
      case .rawContinuation(_):
        return try self.execute(code: nil, args: 0, captured: noExprs)
      case .transformer(let rules):
        if n != 1 {
          throw RuntimeError.argumentCount(min: 1, max: 1, args: args)
        }
        let res = try rules.expand(self.machine.pop())
        self.machine.drop()
        return res
      default:
        return self.machine.pop()
    }
  }

  /// Loads the file at file patch `path`, compiles it in the interaction environment, and
  /// executes it using this thread.
  public func eval(file path: String,
                   in env: Env,
                   as name: String? = nil,
                   optimize: Bool = true,
                   foldCase: Bool = false) throws -> Expr {
    let (sourceId, text) = try self.evaluator.context.sources.readSource(for: path)
    return try self.eval(str: text,
                         sourceId: sourceId,
                         in: env,
                         as: name,
                         optimize: optimize,
                         inDirectory: self.evaluator.context.fileHandler.directory(path),
                         foldCase: foldCase)
  }

  /// Parses the given string, compiles it in the interaction environment, and executes it using
  /// this thread.
  public func eval(str: String,
                   sourceId: UInt16,
                   in env: Env,
                   as name: String? = nil,
                   optimize: Bool = true,
                   inDirectory: String? = nil,
                   foldCase: Bool = false) throws -> Expr {
    return try self.eval(exprs: self.evaluator.parse(str: str,
                                                     sourceId: sourceId,
                                                     foldCase: foldCase),
                         in: env,
                         as: name,
                         optimize: optimize,
                         inDirectory: inDirectory)
  }

  /// Compiles the given expression in the interaction environment and executes it using this
  /// thread.
  public func eval(expr: Expr,
                   in env: Env,
                   as name: String? = nil,
                   optimize: Bool = true,
                   inDirectory: String? = nil) throws -> Expr {
    return try self.eval(exprs: .makeList(expr),
                         in: env,
                         as: name,
                         optimize: optimize,
                         inDirectory: inDirectory)
  }

  /// Compiles the given list of expressions in the interaction environment and executes
  /// it using this thread.
  public func eval(exprs: Expr,
                   in env: Env,
                   as name: String? = nil,
                   optimize: Bool = true,
                   inDirectory: String? = nil) throws -> Expr {
    var exprlist = exprs
    var res = Expr.void
    while case .pair(let expr, let rest) = exprlist {
      let code = try Compiler.compile(expr: .makeList(expr),
                                      in: env,
                                      on: self,
                                      optimize: optimize,
                                      inDirectory: inDirectory)
      // log(code.description)
      if let name = name {
        res = try self.execute(code, as: name)
      } else {
        res = try self.execute(code)
      }
      exprlist = rest
    }
    guard exprlist.isNull else {
      throw RuntimeError.type(exprs, expected: [.properListType])
    }
    return res
  }

  public func mark(in gc: GarbageCollector) {
    self.machine.mark(in: gc)
    self.next?.mark(in: gc)
  }

  public func release() {
    self.machine.release()
    self.next?.release()
  }
}
