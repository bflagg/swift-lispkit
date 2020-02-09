//
//  Evaluator.swift
//  LispKit
//
//  Created by Matthias Zenger on 31/01/2020.
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


public final class Evaluator: TrackedObject {

  /// The context of this evaluator.
  internal unowned let context: Context

  /// The thread using the main virtual machine.
  public internal(set) var main: Thread! = nil

  /// The currently executing virtual machine.
  public internal(set) var current: Thread! = nil

  /// The currently active virtual machines.
  internal private(set) var threads: Thread! = nil

  /// When set to true, it will trigger an abortion of the evaluator as soon as possible.
  public private(set) var abortionRequested: Bool = false

  /// Error handler procedure.
  public var raiseProc: Procedure? = nil

  /// Will be set to true if the `exit` function was invoked in a thread
  public internal(set) var exitTriggered: Bool = false
  
  /// Initializer of evaluator in the given context.
  internal init(for context: Context) {
    self.context = context
    super.init()
    self.main = Thread(evaluator: self,
                       machine: VirtualMachine(for: self),
                       completionHandler: { res in .paused },
                       errorHandler: { err in .paused })
    self.main.state = .paused
    self.current = self.main
    self.threads = self.main
  }

  /// The main virtual machine.
  public var machine: VirtualMachine {
    return self.main.machine
  }

  /// Requests abortion of the machine evaluator.
  public func abort() {
    self.abortionRequested = true
  }

  /// Returns true if an abortion was requested.
  public func isAbortionRequested() -> Bool {
    return self.abortionRequested
  }

  /// Executes all threads.
  public func execute(until: () -> Bool) {
    var blocked: Thread? = nil
    while let current = self.current {
      switch current.state {
        case .new:
          preconditionFailure("new thread in list of active threads")
        case .runnable:
          blocked = nil
          current.state = current.run()
          if case .terminated = current.state {
            fallthrough
          }
        case .terminated:
          blocked = nil
          if let prev = current.prev {
            current.next?.prev = prev
            prev.next = current.next
          } else {
            current.next?.prev = nil
            self.threads = current.next
          }
          self.current = current.next ?? self.threads
          current.next = nil
          current.prev = nil
          if until() {
            return
          }
          continue
        case .paused, .blocked(_, _):
          if blocked === current {
            let err = RuntimeError.eval(.allThreadsDeadlocked)
            var thread = self.threads
            while let th = thread {
              th.error = .error(err)
              th.state = th.errorHandler(err)
              thread = th.next
            }
            blocked = nil
          } else if blocked == nil {
            blocked = current
          }
      }
      self.current = current.next ?? self.threads
      if until() {
        return
      }
    }
  }

  public func makeThread(thunk: Procedure, name: Expr? = nil) -> Thread? {
    let thread = Thread(evaluator: self,
                        name: name,
                        machine: VirtualMachine(basedOn: self.current.machine),
                        completionHandler: { res in .terminated },
                        errorHandler: { res in .terminated })
    if case .closure(_, let captured, let code) = thunk.kind {
      _ = thread.machine.repurpose(proc: thunk, code: code, args: 0, captured: captured)
      return thread
    } else {
      return nil
    }
  }

  public func start(thread: Thread?) {
    guard let thread = thread,
          case .new = thread.state else {
      return
    }
    thread.state = .runnable
    thread.next = self.threads
    self.threads.prev = thread
    self.threads = thread
  }

  // TODO: handle case that thread is current thread
  public func terminate(thread: Thread?) {
    guard let thread = thread, thread !== self.main else {
      return
    }
    let err = RuntimeError.eval(.threadTerminationForced)
    thread.error = .error(err)
    thread.state = thread.errorHandler(err)
  }
  
  public func onMainThreadDo(_ eval: (Thread) throws -> Expr) -> Expr {
    // Guarantee that we are running at the top level
    guard case .paused = self.main.state,
          self.machine.stackEmpty,
          !self.abortionRequested else {
      preconditionFailure("preconditions for top-level evaluation not met")
    }
    // Prepare for the evaluation
    self.exitTriggered = false
    // Reset machine once evaluation finished
    defer {
      self.machine.cleanupTopLevelEval()
      self.abortionRequested = false
    }
    // Perform evaluation
    var exception: RuntimeError? = nil
    do {
      return try eval(self.main)
    } catch let error as RuntimeError { // handle Lisp-related issues
      exception = error
    } catch let error as NSError { // handle OS-related issues
      exception = RuntimeError.os(error)
    }
    // Abortions ignore dynamic environments
    guard !self.abortionRequested else {
      return .error(exception!)
    }
    // Return thrown exception if there is no `raise` procedure. In such a case, there is no
    // unwind of the dynamic environment.
    guard let raiseProc = self.raiseProc else {
      return .error(exception!)
    }
    // Raise thrown exceptions
    while let obj = exception {
      do {
        return try self.main.apply(.procedure(raiseProc), to: .pair(.error(obj), .null))
      } catch let error as RuntimeError { // handle Lisp-related issues
        exception = error
      } catch let error as NSError { // handle OS-related issues
        exception = RuntimeError.os(error)
      }
    }
    // Never happens
    return .void
  }

  /// Parses the given file and returns a list of parsed expressions.
  public func parse(file path: String, foldCase: Bool = false) throws -> Expr {
    let (sourceId, text) = try self.context.sources.readSource(for: path)
    return try self.parse(str: text, sourceId: sourceId, foldCase: foldCase)
  }

  /// Parses the given string and returns a list of parsed expressions.
  public func parse(str: String, sourceId: UInt16, foldCase: Bool = false) throws -> Expr {
    return .makeList(try self.parseExprs(str: str, sourceId: sourceId, foldCase: foldCase))
  }

  /// Parses the given string and returns an array of parsed expressions.
  public func parseExprs(file path: String, foldCase: Bool = false) throws -> Exprs {
    let (sourceId, text) = try self.context.sources.readSource(for: path)
    return try self.parseExprs(str: text,
                               sourceId: sourceId,
                               foldCase: foldCase)
  }

  /// Parses the given string and returns an array of parsed expressions.
  public func parseExprs(str: String, sourceId: UInt16, foldCase: Bool = false) throws -> Exprs {
    let input = TextInput(string: str,
                          abortionCallback: self.isAbortionRequested)
    let parser = Parser(symbols: self.context.symbols,
                        input: input,
                        sourceId: sourceId,
                        foldCase: foldCase)
    var exprs = Exprs()
    while !parser.finished {
      exprs.append(try parser.parse().datum) // TODO: remove .datum
    }
    return exprs
  }

  public func getParam(_ param: Procedure) -> Expr? {
    return self.getParameter(.procedure(param))
  }

  public func getParameter(_ param: Expr) -> Expr? {
    return self.current.machine.getParameter(param)
  }

  public func setParam(_ param: Procedure, to value: Expr) -> Expr {
    return self.setParameter(.procedure(param), to: value)
  }

  public func setParameter(_ param: Expr, to value: Expr) -> Expr {
    return self.current.machine.setParameter(param, to: value)
  }
  
  /// Mark all objects in use by the evaluator.
  public override func mark(in gc: GarbageCollector) {
    self.threads.mark(in: gc)
    if let proc = self.raiseProc {
      gc.mark(proc)
    }
  }

  /// Release memory occupied by evaluator.
  public func release() {
    self.threads.release()
    self.raiseProc = nil
    self.exitTriggered = false
    self.abortionRequested = false
  }
}
