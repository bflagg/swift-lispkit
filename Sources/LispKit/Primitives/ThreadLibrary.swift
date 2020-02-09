//
//  ThreadLibrary.swift
//  LispKit
//
//  Created by Matthias Zenger on 03/02/2020.
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

///
/// Thread library
///
public final class ThreadLibrary: NativeLibrary {

  /// Name of the library.
  public override class var name: [String] {
    return ["lispkit", "thread"]
  }

  /// Dependencies of the library.
  public override func dependencies() {
    self.`import`(from: ["lispkit", "core"], "define")
  }

  /// Declarations of the library.
  public override func declarations() {
    self.define(Procedure("thread?", isThread))
    self.define(Procedure("current-thread", currentThread))
    self.define(Procedure("make-thread", makeThread))
    self.define(Procedure("thread-name", threadName))
    self.define(Procedure("thread-specific", threadSpecific))
    self.define(Procedure("thread-specific-set!", threadSpecificSet))
    self.define(Procedure("thread-start!", threadStart))
    self.define(Procedure("thread-sleep!", threadSleep))
    self.define(Procedure("thread-terminate!", threadTerminate))
    self.define(Procedure("thread-join!", threadJoin))
    self.define(SpecialForm("_yield-thread-now", compileYieldThreadNow))
    self.define("thread-yield!", via: "(define (thread-yield!) (_yield-thread-now))")
  }

  private func thread(from expr: Expr) throws -> Thread {
    guard case .object(let obj) = expr,
          let thread = obj as? Thread else {
      throw RuntimeError.type(expr, expected: [Thread.type])
    }
    return thread
  }

  private func isThread(expr: Expr) -> Expr {
    guard case .object(let obj) = expr, obj is Thread else {
      return .false
    }
    return .true
  }

  private func currentThread() -> Expr {
    return .object(self.context.evaluator.current)
  }

  private func makeThread(thunk: Expr, name: Expr?) throws -> Expr {
    guard let thread = self.context.evaluator.makeThread(thunk: try thunk.asProcedure(),
                                                         name: name) else {
      return .false
    }
    return .object(thread)
  }

  private func threadName(expr: Expr) throws -> Expr {
    let thread = try self.thread(from: expr)
    return thread.name ?? .fixnum(Int64(thread.identity))
  }

  private func threadSpecific(expr: Expr) throws -> Expr {
    return try self.thread(from: expr).specific
  }

  private func threadSpecificSet(expr: Expr, value: Expr) throws -> Expr {
    try self.thread(from: expr).specific = value
    return .void
  }

  private func threadStart(expr: Expr) throws -> Expr {
    self.context.evaluator.start(thread: try self.thread(from: expr))
    return .void
  }
  
  private func threadSleep(timeout: Expr) throws -> Expr {
    return .void
  }

  private func threadTerminate(expr: Expr) throws -> Expr {
    self.context.evaluator.terminate(thread: try self.thread(from: expr))
    return .void
  }

  private func threadJoin(expr: Expr, timeout: Expr?, value: Expr?) throws -> Expr {
    return .void
  }

  private func compileYieldThreadNow(compiler: Compiler,
                                     expr: Expr,
                                     env: Env,
                                     tail: Bool) throws -> Bool {
    guard case .pair(_, .null) = expr else {
      throw RuntimeError.argumentCount(of: "yield-thread-now", num: 0, expr: expr)
    }
    compiler.emit(.threadYield)
    compiler.emit(.pushVoid)
    return false
  }
}
