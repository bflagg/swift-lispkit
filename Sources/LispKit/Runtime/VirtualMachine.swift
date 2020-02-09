//
//  VirtualMachine.swift
//  LispKit
//
//  Created by Matthias Zenger on 13/02/2016.
//  Copyright © 2016-2019 ObjectHub. All rights reserved.
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
/// Class `VirtualMachine` implements a virtual stack machine for executing LispKit `Code`
/// objects. The virtual machine consists of the following components:
///    - *context*: This is a reference to the context in which this virtual machine is embedded.
///    - *stack*: This is the stack for passing parameters, storing intermediate results,
///      and for returning results.
///    - *sp*: The stack pointer, i.e. the index of the next available position on the stack.
///
/// The stack is segmented into frames, each representing the invocation of a procedure. The
/// layout of each stack frame looks like this:
///
///    │        ...        │
///    ╞═══════════════════╡
///    │        ...        │
///    │ Stack value 1     │
///    │ Stack value 0     │
///    │ Local variable 1  │
///    │ Local variable 0  │  ⟸ fp + args
///    │ Argument 1        │
///    │ Argument 0        │  ⟸ fp
///    │ Procedure         │  ⟸ fp - 1
///    ├───────────────────┤                 ⥥ makeFrame ⥥
///    │ Return address    │  ⟸ fp - 2
///    │ Dynamic link      │  ⟸ fp - 3
///    ╞═══════════════════╡
///    │        ...        │
///
public final class VirtualMachine: TrackedObject {
  
  /// Collects all registers in a single struct
  internal struct Registers {
    let rid: Int
    var code: Code
    var captured: Exprs
    var ip: Int
    var fp: Int
    let initialFp: Int
    
    init(code: Code, captured: Exprs, fp: Int, root: Bool) {
      if root {
        self.rid = 0
      } else {
        VirtualMachine.nextRid += 1
        self.rid = VirtualMachine.nextRid
      }
      self.code = code
      self.captured = captured
      self.ip = 0
      self.fp = fp
      self.initialFp = fp
    }
    
    @inline(__always) mutating func use(code: Code, captured: Exprs, fp: Int) {
      self.code = code
      self.captured = captured
      self.ip = 0
      self.fp = fp
    }
    
    var topLevel: Bool {
      return self.fp == self.initialFp
    }
    
    var isInitialized: Bool {
      return self.rid == 0 && self.code.instructions.count > 0
    }

    public func mark(in gc: GarbageCollector) {
      gc.mark(self.code)
      for i in self.captured.indices {
        gc.markLater(self.captured[i])
      }
    }
  }
  
  internal final class Winder: Reference {
    let before: Procedure
    let after: Procedure
    let handlers: Expr?
    let next: Winder?
    
    init(before: Procedure, after: Procedure, handlers: Expr?, next: Winder?) {
      self.before = before
      self.after = after
      self.handlers = handlers
      self.next = next
    }
    
    var id: Int64 {
      return Int64(bitPattern: UInt64(self.identity))
    }
    
    var count: Int {
      var ws: Winder? = self
      var n = 0
      while let next = ws {
        n += 1
        ws = next.next
      }
      return n
    }
    
    func commonPrefix(_ with: Winder?) -> Winder? {
      guard with != nil else {
        return nil
      }
      var this: Winder? = self
      var that: Winder? = with!
      let thisLen = self.count
      let thatLen = with!.count
      if thisLen > thatLen {
        for _ in thatLen..<thisLen {
          this = this!.next
        }
      } else if thatLen > thisLen {
        for _ in thisLen..<thatLen {
          that = that!.next
        }
      }
      while let thisWinder = this, let thatWinder = that , thisWinder !== thatWinder {
        this = thisWinder.next
        that = thatWinder.next
      }
      return this
    }

    public func mark(in gc: GarbageCollector) {
      gc.mark(self.before)
      gc.mark(self.after)
      if let handlers = self.handlers {
        gc.markLater(handlers)
      }
      self.next?.mark(in: gc)
    }
  }
  
  public enum CallTracingMode {
    case on
    case off
    case byProc
  }
  
  /// Counter for managing register ids
  private static var nextRid: Int = 0
  
  /// The context of this virtual machine
  private unowned let context: Context

  /// The evaluator of this virtual machine
  private unowned let evaluator: Evaluator

  /// The stack used by this virtual machine
  private var stack: Exprs
  
  /// The stack pointer (pointing at the next available position on the stack); this variable
  /// should be private, but since it's needed in tests, it remains internal.
  internal var sp: Int {
    didSet {
      if sp > self.maxSp {
        self.maxSp = self.sp
      }
    }
  }
  
  /// The maximum value of the stack pointer so far (used for debugging)
  public private(set) var maxSp: Int
  
  /// Registers
  private var registers: Registers
  
  /// Winders
  internal private(set) var winders: Winder?
  
  /// Parameters
  public internal(set) var parameters: HashTable
  private var setParameterProc: Procedure!
  
  /// Internal counter used for triggering the garbage collector.
  private var execInstr: UInt64
  
  /// When set to true, will print call and return traces
  public var traceCalls: CallTracingMode = .off
  
  /// Initializes a new virtual machine for the given context.
  public init(for evaluator: Evaluator) {
    self.context = evaluator.context
    self.evaluator = evaluator
    self.stack = Exprs(repeating: .undef, count: 1024)
    self.sp = 0
    self.maxSp = 0
    self.registers = Registers(code: Code([], [], []), captured: [], fp: 0, root: true)
    self.winders = nil
    self.parameters = HashTable(equiv: .eq)
    self.execInstr = 0
    super.init()
    self.setParameterProc = Procedure("_set-parameter", self.setParameter, nil)
  }

  /// Initializes a new virtual machine inheriting state based on the given virtual machine `vm`.
  public init(basedOn vm: VirtualMachine) {
    self.context = vm.context
    self.evaluator = vm.evaluator
    self.stack = Exprs(repeating: .undef, count: 1024)
    self.sp = 0
    self.maxSp = 0
    self.registers = Registers(code: Code([], [], []), captured: [], fp: 0, root: true)
    self.winders = vm.winders
    self.parameters = vm.parameters
    self.execInstr = 0
    self.traceCalls = vm.traceCalls
    super.init()
    self.setParameterProc = Procedure("_set-parameter", self.setParameter, nil)
  }
  
  /// Returns a copy of the current virtual machine state.
  public func getState() -> VirtualMachineState {
    return VirtualMachineState(stack: self.stack,
                               sp: self.sp,
                               spDelta: -2,
                               ipDelta: -1,
                               registers: self.registers,
                               winders: self.winders)
  }
  
  /// Returns true of the stack is empty
  internal var stackEmpty: Bool {
    return self.sp == 0
  }
  
  internal func cleanupTopLevelEval() {
    for i in 0..<self.sp {
      self.stack[i] = .undef
    }
    self.sp = 0
    self.winders = nil
  }

  /// Pushes the given expression onto the stack.
  @inline(__always) private func push(_ expr: Expr) {
    if self.sp < self.stack.count {
      self.stack[self.sp] = expr
    } else {
      if self.sp >= self.stack.capacity {
        self.stack.reserveCapacity(self.sp * 2)
      }
      self.stack.append(expr)
    }
    self.sp += 1
  }
  
  /// Pushes the given list of arguments onto the stack and returns the number of arguments pushed
  /// onto the stack.
  @inline(__always) @discardableResult private func pushArguments(_ arglist: Expr) throws -> Int {
    var args = arglist
    var n = 0
    while case .pair(let arg, let rest) = args {
      self.push(arg)
      n = n &+ 1
      args = rest
    }
    guard args.isNull else {
      throw RuntimeError.eval(.malformedArgumentList, arglist)
    }
    return n
  }
  
  /// Removes the top `n` elements from the stack.
  @inline(__always) private func pop(_ n: Int) {
    var i = self.sp
    self.sp = self.sp &- n
    while i > self.sp {
      i = i &- 1
      self.stack[self.sp] = .undef
    }
  }
  
  /// Removes the top element from the stack without resetting it and returns its value.
  @inline(__always) private func popUnsafe() -> Expr {
    self.sp = self.sp &- 1
    return self.stack[self.sp]
  }
  
  /// Returns the top element of the stack.
  @inline(__always) private func top() -> Expr {
    return self.stack[self.sp &- 1]
  }
  
  /// Removes the top element from the stack and returns it.
  @inline(__always) internal func pop() -> Expr {
    self.sp = self.sp &- 1
    let res = self.stack[self.sp]
    self.stack[self.sp] = .undef
    return res
  }
  
  /// Removes the top element from the stack
  @inline(__always) internal func drop() {
    self.sp = self.sp &- 1
    self.stack[self.sp] = .undef
  }
  
  @inline(__always) private func popAsList(_ n: Int) -> Expr {
    var res = Expr.null
    var i = n
    while i > 0 {
      res = .pair(self.pop(), res)
      i = i &- 1
    }
    return res
  }
  
  @inline(__always) private func captureExprs(_ n: Int) -> Exprs {
    var captures = Exprs()
    var i = self.sp &- n
    while i < self.sp {
      captures.append(self.stack[i])
      self.stack[i] = .undef
      i = i &+ 1
    }
    self.sp = self.sp &- n
    return captures
  }
  
  internal func windUp(before: Procedure, after: Procedure, handlers: Expr? = nil) {
    self.winders = Winder(before: before, after: after, handlers: handlers , next: self.winders)
  }
  
  internal func windDown() -> Winder? {
    guard let res = self.winders else {
      return nil
    }
    self.winders = res.next
    return res
  }
  
  internal func currentHandlers() -> Expr? {
    var winders = self.winders
    while let w = winders, w.handlers == nil {
      winders = w.next
    }
    return winders?.handlers
  }

  public func getParameter(_ param: Expr) -> Expr? {
    guard case .some(.pair(_, .box(let cell))) = self.parameters.get(param) else {
      guard case .procedure(let proc) = param,
            case .parameter(let tuple) = proc.kind else {
        return nil
      }
      return tuple.snd
    }
    return cell.value
  }

  public func setParameter(_ param: Expr, to value: Expr) -> Expr {
    guard case .some(.pair(_, .box(let cell))) = self.parameters.get(param) else {
      guard case .procedure(let proc) = param,
            case .parameter(let tuple) = proc.kind else {
        preconditionFailure("cannot set parameter \(param)")
      }
      tuple.snd = value
      return .void
    }
    cell.value = value
    return .void
  }
  
  internal func bindParameter(_ param: Expr, to value: Expr) -> Expr {
    self.parameters.add(key: param, mapsTo: .box(Cell(value)))
    return .void
  }

  private func exitFrame() {
    let fp = self.registers.fp
    // Determine former ip
    guard case .fixnum(let newip) = self.stack[fp &- 2] else {
      preconditionFailure()
    }
    self.registers.ip = Int(newip)
    // Determine former fp
    guard case .fixnum(let newfp) = self.stack[fp &- 3] else {
      preconditionFailure()
    }
    // Shift result down
    self.stack[fp &- 3] = self.stack[self.sp &- 1]
    // Clean up stack that is freed up
    for i in (fp &- 2)..<self.sp {
      self.stack[i] = .undef
    }
    // Set new fp and sp
    self.sp = fp &- 2
    self.registers.fp = Int(newfp)
    // Determine closure to which execution returns to
    guard case .procedure(let proc) = self.stack[Int(newfp) - 1] else {
      preconditionFailure()
    }
    // Extract code and capture list
    guard case .closure(_, let newcaptured, let newcode) = proc.kind else {
      preconditionFailure()
    }
    // Set new code and capture list
    self.registers.captured = newcaptured
    self.registers.code = newcode
  }
  
  public func getStackTrace(current: Procedure? = nil) -> [Procedure] {
    var stackTrace: [Procedure] = []
    if let current = current {
      stackTrace.append(current)
    }
    var fp = self.registers.fp
    while fp > 0 {
      guard case .procedure(let proc) = self.stack[fp &- 1] else {
        // This may happen if an error is thrown
        return stackTrace
      }
      stackTrace.append(proc)
      if fp > 2 {
        guard case .fixnum(let newfp) = self.stack[fp &- 3] else {
          // This may happen if an error is thrown
          return stackTrace
        }
        fp = Int(newfp)
      } else {
        fp = 0
      }
    }
    return stackTrace
  }
  
  @inline(__always) private func printCallTrace(_ n: Int, tailCall: Bool = false) -> Procedure? {
    if self.traceCalls != .off && self.sp > (n &+ 1) {
      if case .procedure(let proc) = self.stack[self.sp &- n &- 1],
         self.traceCalls == .on || proc.traced {
        var args = Exprs()
        for i in 0..<n {
          args.append(self.stack[self.sp &- n &+ i])
        }
        self.context.delegate.trace(call: proc,
                                    args: args,
                                    tailCall: tailCall,
                                    in: self)
        return proc
      }
    }
    return nil
  }
  
  @inline(__always) private func printReturnTrace(_ proc: Procedure, tailCall: Bool = false) {
    if (self.traceCalls == .on || (self.traceCalls == .byProc && proc.traced)) && self.sp > 0 {
      self.context.delegate.trace(return: proc,
                                  result: self.stack[self.sp &- 1],
                                  tailCall: tailCall,
                                  in: self)
    }
  }
  
  private func invoke(_ n: inout Int, _ overhead: Int) throws -> Procedure {
    // Get procedure to call
    guard case .procedure(let p) = self.stack[self.sp &- n &- 1] else {
      throw RuntimeError.eval(.nonApplicativeValue, self.stack[self.sp &- n &- 1])
    }
    var proc = p
    // Handle parameter procedures
    if case .parameter(let tuple) = proc.kind {
      switch n {
        case 0:                             // Return parameter value
          self.pop(overhead)
          self.push(self.getParameter(.procedure(proc))!)
          return proc
        case 1 where tuple.fst.isNull:      // Set parameter value without setter
          let a0 = self.pop()
          self.pop(overhead)
          self.push(self.setParameter(.procedure(proc), to: a0))
          return proc
        case 1:                             // Set parameter value with setter
          let a0 = self.pop()
          self.drop()
          self.push(tuple.fst)
          self.push(.procedure(proc))
          self.push(a0)
          self.push(.procedure(self.setParameterProc))
          n = 3
          proc = try tuple.fst.asProcedure()
        default:
          throw RuntimeError.argumentCount(min: 1, max: 1, args: self.popAsList(n))
      }
    }
    // Handle primitive procedures; this is required to loop because of applicators
    do {
      loop: while case .primitive(_, let impl, _) = proc.kind {
        switch impl {
          case .eval(let eval):
            let generated = Procedure(try eval(self.stack[(self.sp &- n)..<self.sp]))
            self.pop(n + 1)
            self.push(.procedure(generated))
            n = 0
            return generated
          case .apply(let apply):
            let (next, args) = try apply(self.stack[(self.sp &- n)..<self.sp])
            self.pop(n + 1)
            self.push(.procedure(next))
            for arg in args {
              self.push(arg)
            }
            n = args.count
            proc = next
          case .native0(let exec):
            guard n == 0 else {
              throw RuntimeError.argumentCount(min: 0, max: 0, args: self.popAsList(n))
            }
            self.pop(overhead)
            self.push(try exec())
            return proc
          case .native1(let exec):
            guard n == 1 else {
              throw RuntimeError.argumentCount(min: 1, max: 1, args: self.popAsList(n))
            }
            let a0 = self.pop()
            self.pop(overhead)
            self.push(try exec(a0))
            return proc
          case .native2(let exec):
            guard n == 2 else {
              throw RuntimeError.argumentCount(min: 2, max: 2, args: self.popAsList(n))
            }
            let a1 = self.pop()
            let a0 = self.pop()
            self.pop(overhead)
            self.push(try exec(a0, a1))
            return proc
          case .native3(let exec):
            guard n == 3 else {
              throw RuntimeError.argumentCount(min: 3, max: 3, args: self.popAsList(n))
            }
            let a2 = self.pop()
            let a1 = self.pop()
            let a0 = self.pop()
            self.pop(overhead)
            self.push(try exec(a0, a1, a2))
            return proc
          case .native4(let exec):
            guard n == 4 else {
              throw RuntimeError.argumentCount(min: 4, max: 4, args: self.popAsList(n))
            }
            let a3 = self.pop()
            let a2 = self.pop()
            let a1 = self.pop()
            let a0 = self.pop()
            self.pop(overhead)
            self.push(try exec(a0, a1, a2, a3))
            return proc
          case .native0O(let exec):
            if n == 0 {
              self.pop(overhead)
              self.push(try exec(nil))
            } else if n == 1 {
              let a0 = self.pop()
              self.pop(overhead)
              self.push(try exec(a0))
            } else {
              throw RuntimeError.argumentCount(min: 1, max: 1, args: self.popAsList(n))
            }
            return proc
          case .native1O(let exec):
            if n == 1 {
              let a0 = self.pop()
              self.pop(overhead)
              self.push(try exec(a0, nil))
            } else if n == 2 {
              let a1 = self.pop()
              let a0 = self.pop()
              self.pop(overhead)
              self.push(try exec(a0, a1))
            } else {
              throw RuntimeError.argumentCount(min: 2, max: 2, args: self.popAsList(n))
            }
            return proc
          case .native2O(let exec):
            if n == 2 {
              let a1 = self.pop()
              let a0 = self.pop()
              self.pop(overhead)
              self.push(try exec(a0, a1, nil))
            } else if n == 3 {
              let a2 = self.pop()
              let a1 = self.pop()
              let a0 = self.pop()
              self.pop(overhead)
              self.push(try exec(a0, a1, a2))
            } else {
              throw RuntimeError.argumentCount(min: 3, max: 3, args: self.popAsList(n))
            }
            return proc
          case .native3O(let exec):
            if n == 3 {
              let a2 = self.pop()
              let a1 = self.pop()
              let a0 = self.pop()
              self.pop(overhead)
              self.push(try exec(a0, a1, a2, nil))
            } else if n == 4 {
              let a3 = self.pop()
              let a2 = self.pop()
              let a1 = self.pop()
              let a0 = self.pop()
              self.pop(overhead)
              self.push(try exec(a0, a1, a2, a3))
            } else {
              throw RuntimeError.argumentCount(min: 3, max: 3, args: self.popAsList(n))
            }
            return proc
          case .native0OO(let exec):
            if n == 0 {
              self.pop(overhead)
              self.push(try exec(nil, nil))
            } else if n == 1 {
              let a0 = self.pop()
              self.pop(overhead)
              self.push(try exec(a0, nil))
            } else if n == 2 {
              let a1 = self.pop()
              let a0 = self.pop()
              self.pop(overhead)
              self.push(try exec(a0, a1))
            } else {
              throw RuntimeError.argumentCount(min: 2, max: 2, args: self.popAsList(n))
            }
            return proc
          case .native1OO(let exec):
            if n == 1 {
              let a0 = self.pop()
              self.pop(overhead)
              self.push(try exec(a0, nil, nil))
            } else if n == 2 {
              let a1 = self.pop()
              let a0 = self.pop()
              self.pop(overhead)
              self.push(try exec(a0, a1, nil))
            } else if n == 3 {
              let a2 = self.pop()
              let a1 = self.pop()
              let a0 = self.pop()
              self.pop(overhead)
              self.push(try exec(a0, a1, a2))
            } else {
              throw RuntimeError.argumentCount(min: 3, max: 3, args: self.popAsList(n))
            }
            return proc
          case .native2OO(let exec):
            if n == 2 {
              let a1 = self.pop()
              let a0 = self.pop()
              self.pop(overhead)
              self.push(try exec(a0, a1, nil, nil))
            } else if n == 3 {
              let a2 = self.pop()
              let a1 = self.pop()
              let a0 = self.pop()
              self.pop(overhead)
              self.push(try exec(a0, a1, a2, nil))
            } else if n == 4 {
              let a3 = self.pop()
              let a2 = self.pop()
              let a1 = self.pop()
              let a0 = self.pop()
              self.pop(overhead)
              self.push(try exec(a0, a1, a2, a3))
            } else {
              throw RuntimeError.argumentCount(min: 4, max: 4, args: self.popAsList(n))
            }
            return proc
          case .native3OO(let exec):
            if n == 3 {
              let a2 = self.pop()
              let a1 = self.pop()
              let a0 = self.pop()
              self.pop(overhead)
              self.push(try exec(a0, a1, a2, nil, nil))
            } else if n == 4 {
              let a3 = self.pop()
              let a2 = self.pop()
              let a1 = self.pop()
              let a0 = self.pop()
              self.pop(overhead)
              self.push(try exec(a0, a1, a2, a3, nil))
            } else if n == 5 {
              let a4 = self.pop()
              let a3 = self.pop()
              let a2 = self.pop()
              let a1 = self.pop()
              let a0 = self.pop()
              self.pop(overhead)
              self.push(try exec(a0, a1, a2, a3, a4))
            } else {
              throw RuntimeError.argumentCount(min: 5, max: 5, args: self.popAsList(n))
            }
            return proc
          case .native0R(let exec):
            let res = try exec(self.stack[(self.sp &- n)..<self.sp])
            self.pop(n &+ overhead)
            self.push(res)
            return proc
          case .native1R(let exec):
            if n >= 1 {
              let res = try exec(self.stack[self.sp &- n], self.stack[(self.sp &- n &+ 1)..<self.sp])
              self.pop(n &+ overhead)
              self.push(res)
            } else {
              throw RuntimeError.argumentCount(min: 1, args: self.popAsList(n))
            }
            return proc
          case .native2R(let exec):
            if n >= 2 {
              let res = try exec(self.stack[self.sp &- n],
                                 self.stack[self.sp &- n &+ 1],
                                 self.stack[(self.sp &- n &+ 2)..<self.sp])
              self.pop(n &+ overhead)
              self.push(res)
            } else {
              throw RuntimeError.argumentCount(min: 2, args: self.popAsList(n))
            }
            return proc
          case .native3R(let exec):
            if n >= 3 {
              let res = try exec(self.stack[self.sp &- n],
                                 self.stack[self.sp &- n &+ 1],
                                 self.stack[self.sp &- n &+ 2],
                                 self.stack[(self.sp &- n &+ 3)..<self.sp])
              self.pop(n &+ overhead)
              self.push(res)
            } else {
              throw RuntimeError.argumentCount(min: 3, args: self.popAsList(n))
            }
            return proc
        }
      }
    } catch let error as RuntimeError {
      if error.stackTrace == nil {
        error.attach(stackTrace: self.getStackTrace(current: proc))
      }
      throw error
    } catch let error as NSError {
      throw RuntimeError.os(error).attach(stackTrace: self.getStackTrace(current: proc))
    }
    // Handle continuations
    if case .rawContinuation(let vmState) = proc.kind {
      // Check that we apply the continuation in the right context
      guard vmState.registers.rid == self.registers.rid else {
        throw RuntimeError.eval(.illegalContinuationApplication,
                                .procedure(proc),
                                .makeNumber(self.registers.rid))
      }
      // Continuations accept exactly one argument
      guard n == 1 else {
        throw RuntimeError.argumentCount(min: 1, max: 1, args: self.popAsList(n))
      }
      // Retrieve argument
      let arg = self.pop()
      // Restore virtual machine from state encapsulated in continuation
      self.stack = vmState.stack
      self.sp = vmState.sp
      self.registers = vmState.registers
      // Push identity function and argument onto restored virtual machine stack
      self.push(.procedure(CoreLibrary.idProc))
      self.push(arg)
    }
    return proc
  }
  
  @inline(__always) private func collectGarbageIfNeeded() {
    self.execInstr = self.execInstr &+ 1
    if self.execInstr % 0b011111111111111111111 == 0 {
      // let res =
      _ = self.context.objects.collectGarbage()
      // log("[collect garbage; freed up objects: \(res)]")
    }
  }

  internal func pushAndInvoke(_ fun: Expr, to args: Expr) throws -> (Procedure, Int) {
    self.push(fun)
    var n = try self.pushArguments(args)
    let proc = try self.invoke(&n, 1)
    return (proc, n)
  }

  internal func repurpose(proc: Procedure? = nil,
                          code: Code,
                          args: Int,
                          captured: Exprs) -> Registers {
    if let proc = proc {
      self.push(.procedure(proc))
    }
    let savedRegisters = self.registers
    self.registers = Registers(code: code,
                               captured: captured,
                               fp: self.sp &- args,
                               root: !savedRegisters.isInitialized)
    return savedRegisters
  }

  internal func repurpose(_ registers: Registers) -> Registers {
    let savedRegisters = self.registers
    self.registers = registers
    return savedRegisters
  }
  
  internal func execute() throws -> Expr? {
    let startTime = Timer.currentTimeInMSec
    while self.registers.ip >= 0 && self.registers.ip < self.registers.code.instructions.count {
      guard !self.evaluator.abortionRequested else {
        throw RuntimeError.abortion(stackTrace: self.getStackTrace())
      }
      if self.evaluator.threads?.next != nil && Timer.currentTimeInMSec > startTime + 100 {
        return nil
      }
      self.collectGarbageIfNeeded()
      /*
      print("╔══════════════════════════════════════════════════════")
      if self.registers.ip > 0 {
        print("║     \(self.registers.ip - 1)  \(self.registers.code.instructions[self.registers.ip - 1])")
      }
      print("║    [\(self.registers.ip)] \(self.registers.code.instructions[self.registers.ip])")
      if self.registers.ip < self.registers.code.instructions.count - 1 {
        print("║     \(self.registers.ip + 1)  \(self.registers.code.instructions[self.registers.ip + 1])")
      }
      print(stackFragmentDescr(self.registers.ip, self.registers.fp, header: "╟──────────────────────────────────────────────────────\n"))
      */
      let ip = self.registers.ip
      self.registers.ip = ip &+ 1
      switch self.registers.code.instructions[ip] {
        case .noOp:
          break
        case .pop:
          self.sp = self.sp &- 1
          self.stack[self.sp] = .undef
        case .dup:
          self.push(self.stack[self.sp &- 1])
        case .swap:
          let top = self.stack[self.sp &- 1]
          self.stack[self.sp &- 1] = self.stack[self.sp &- 2]
          self.stack[self.sp &- 2] = top
        case .pushGlobal(let index):
          let value = self.context.heap.locations[index]
          switch value {
            case .undef:
              throw RuntimeError.eval(.variableUndefined, .undef)
            case .uninit(let sym):
              throw RuntimeError.eval(.variableNotYetInitialized, .symbol(sym))
            case .special(_):
              throw RuntimeError.eval(.illegalKeywordUsage, value)
            default:
              self.push(value)
          }
        case .setGlobal(let index):
          let value = self.context.heap.locations[index]
          switch value {
            case .undef:
              throw RuntimeError.eval(.variableNotYetInitialized, .undef)
            case .uninit(let sym):
              throw RuntimeError.eval(.unboundVariable, .symbol(sym))
            default:
              self.context.heap.locations[index] = self.pop()
          }
        case .defineGlobal(let index):
          self.context.heap.locations[index] = self.pop()
        case .pushCaptured(let index):
          self.push(self.registers.captured[index])
        case .pushCapturedValue(let index):
          guard case .box(let cell) = self.registers.captured[index] else {
            preconditionFailure("pushCapturedValue cannot push \(self.registers.captured[index])")
          }
          if case .undef = cell.value {
            throw RuntimeError.eval(.variableNotYetInitialized, .undef)
          }
          self.push(cell.value)
        case .setCapturedValue(let index):
          guard case .box(let cell) = self.registers.captured[index] else {
            preconditionFailure("setCapturedValue cannot set value of \(self.registers.captured[index])")
          }
          cell.value = self.pop()
          if !cell.managed && !cell.value.isAtom {
            self.context.objects.manage(cell)
          }
        case .pushLocal(let index):
          self.push(self.stack[self.registers.fp &+ index])
        case .setLocal(let index):
          self.stack[self.registers.fp &+ index] = self.pop()
        case .setLocalValue(let index):
          guard case .box(let cell) = self.stack[self.registers.fp &+ index] else {
            preconditionFailure(
              "setLocalValue cannot set value of \(self.stack[self.registers.fp &+ index])")
          }
          cell.value = self.pop()
          if !cell.managed && !cell.value.isAtom {
            self.context.objects.manage(cell)
          }
        case .makeLocalVariable(let index):
          let cell = Cell(self.pop())
          // TODO: I can't think of a reason to manage such cells since they only live on the
          // stack and are never stored anywhere else.
          // self.context.objects.manage(cell)
          self.stack[self.registers.fp &+ index] = .box(cell)
        case .makeVariableArgument(let index):
          let cell = Cell(self.stack[self.registers.fp &+ index])
          // TODO: I can't think of a reason to manage such cells since they only live on the
          // stack and are never stored anywhere else.
          // self.context.objects.manage(cell)
          self.stack[self.registers.fp &+ index] = .box(cell)
        case .pushLocalValue(let index):
          guard case .box(let cell) = self.stack[self.registers.fp &+ index] else {
            preconditionFailure(
              "pushLocalValue cannot push \(self.stack[self.registers.fp &+ index])")
          }
          if case .undef = cell.value {
            throw RuntimeError.eval(.variableNotYetInitialized, .undef)
          }
          self.push(cell.value)
        case .pushConstant(let index):
          self.push(self.registers.code.constants[index])
        case .pushUndef:
          self.push(.undef)
        case .pushVoid:
          self.push(.void)
        case .pushEof:
          self.push(.void)
        case .pushNull:
          self.push(.null)
        case .pushTrue:
          self.push(.true)
        case .pushFalse:
          self.push(.false)
        case .pushFixnum(let num):
          self.push(.fixnum(num))
        case .pushBignum(let num):
          self.push(.bignum(num))
        case .pushRat(let num):
          self.push(.rational(.fixnum(num.numerator), .fixnum(num.denominator)))
        case .pushBigrat(let num):
          self.push(.rational(.bignum(num.numerator), .bignum(num.denominator)))
        case .pushFlonum(let num):
          self.push(.flonum(num))
        case .pushComplex(let num):
          self.push(.complex(ImmutableBox(num)))
        case .pushChar(let char):
          self.push(.char(char))
        case .pack(let n):
          var list = Expr.null
          for _ in 0..<n {
            list = .pair(self.pop(), list)
          }
          self.push(.values(list))
        case .unpack(let n, let overflow):
          switch self.top() {
            case .void:
              guard n == 0 else {
                throw RuntimeError.eval(.multiValueCountError, .makeNumber(n), .null)
              }
              self.drop()
              if overflow {
                self.push(.null)
              }
            case .values(let list):
              self.drop()
              var m = n
              var next = list
              while case .pair(let value, let rest) = next {
                if m <= 0 {
                  if overflow {
                    break
                  } else {
                    throw RuntimeError.eval(.multiValueCountError, .makeNumber(n), list)
                  }
                }
                self.push(value)
                m -= 1
                next = rest
              }
              guard m == 0 else {
                throw RuntimeError.eval(.multiValueCountError, .makeNumber(n), list)
              }
              if overflow {
                self.push(next)
              }
            default:
              if n == 1 {
                if overflow {
                  self.push(.null)
                }
              } else if n == 0 && overflow {
                self.push(.pair(self.popUnsafe(), .null))
              } else {
                throw RuntimeError.eval(.multiValueCountError,
                                        .makeNumber(n),
                                        .pair(self.top(), .null))
              }
          }
        case .makeClosure(let i, let n, let index):
          if i >= 0 {
            guard case .symbol(let sym) = self.registers.code.constants[i] else {
              preconditionFailure(
                "makeClosure has broken closure name \(self.registers.code.constants[i])")
            }
            self.push(.procedure(Procedure(.named(sym.description),
                                           self.captureExprs(n),
                                           self.registers.code.fragments[index])))
          } else if i == -2 {
            self.push(.procedure(Procedure(.continuation,
                                           self.captureExprs(n),
                                           self.registers.code.fragments[index])))
          } else {
            self.push(.procedure(Procedure(.anonymous,
                                           self.captureExprs(n),
                                           self.registers.code.fragments[index])))
          }
        case .makePromise:
          let top = self.pop()
          guard case .procedure(let proc) = top else {
            preconditionFailure("makePromise cannot create promise from \(top)")
          }
          let future = Promise(kind: .promise, thunk: proc)
          future.managementRef = self.context.objects.reference(to: future)
          self.push(.promise(future))
        case .makeStream:
          let top = self.pop()
          guard case .procedure(let proc) = top else {
            preconditionFailure("makeStream cannot create stream from \(top)")
          }
          let future = Promise(kind: .stream, thunk: proc)
          future.managementRef = self.context.objects.reference(to: future)
          self.push(.promise(future))
        case .makeSyntax(let i):
          let transformer = self.pop()
          guard case .procedure(let proc) = transformer else {
            throw RuntimeError.eval(.malformedTransformer, transformer)
          }
          if i >= 0 {
            guard case .symbol(let sym) = self.registers.code.constants[i] else {
              preconditionFailure(
                "makeSyntax has broken syntax name \(self.registers.code.constants[i])")
            }
            self.push(.special(SpecialForm(sym.identifier, proc)))
          } else {
            self.push(.special(SpecialForm(nil, proc)))
          }
        case .compile:
          let environment = try self.pop().asEnvironment()
          let code = try Compiler.compile(expr: .makeList(self.pop()),
                                          in: .global(environment),
                                          optimize: true)
          self.push(.procedure(Procedure(code)))
        case .apply(let m):
          let arglist = self.pop()
          var args = arglist
          var n = m &- 1
          while case .pair(let arg, let rest) = args {
            self.push(arg)
            n = n &+ 1
            args = rest
          }
          guard args.isNull else {
            throw RuntimeError.eval(.malformedArgumentList, arglist)
          }
          // Store instruction pointer
          self.stack[self.sp &- n &- 2] = .fixnum(Int64(self.registers.ip))
          // Invoke native function
          if case .closure(_, let newcaptured, let newcode) = try self.invoke(&n, 3).kind {
            self.registers.use(code: newcode, captured: newcaptured, fp: self.sp &- n)
          }
        case .makeFrame:
          // Push frame pointer
          self.push(.fixnum(Int64(self.registers.fp)))
          // Reserve space for instruction pointer
          self.push(.undef)
        case .injectFrame:
          let top = self.pop()
          // Push frame pointer
          self.push(.fixnum(Int64(self.registers.fp)))
          // Reserve space for instruction pointer
          self.push(.undef)
          // Push top value onto stack again
          self.push(top)
        case .call(let n):
          let tproc = self.printCallTrace(n, tailCall: false)
          // Store instruction pointer
          self.stack[self.sp &- n &- 2] = .fixnum(Int64(self.registers.ip))
          // Invoke native function
          var m = n
          if case .closure(_, let newcaptured, let newcode) = try self.invoke(&m, 3).kind {
            self.registers.use(code: newcode, captured: newcaptured, fp: self.sp &- m)
          } else if let tproc = tproc {
            self.printReturnTrace(tproc, tailCall: false)
          }
        case .tailCall(let m):
          _ = self.printCallTrace(m, tailCall: true)
          // Invoke native function
          var n = m
          let proc = try self.invoke(&n, 1)
          if case .closure(_, let newcaptured, let newcode) = proc.kind {
            // Execute closure
            self.registers.use(code: newcode, captured: newcaptured, fp: self.registers.fp)
            // Shift stack frame down to next stack frame
            for i in 0...n {
              self.stack[self.registers.fp &- 1 &+ i] = self.stack[self.sp &- n &- 1 &+ i]
            }
            // Wipe the now empty part of the stack
            for i in (self.registers.fp &+ n)..<self.sp {
              self.stack[i] = .undef
            }
            // Adjust the stack pointer
            self.sp = self.registers.fp &+ n
          } else if case .rawContinuation(_) = proc.kind {
            break
          } else if self.registers.topLevel {
            if self.registers.fp > 0,
               case .procedure(let tproc) = self.stack[self.registers.fp &- 1] {
              self.printReturnTrace(tproc, tailCall: true)
            }
            // Return to interactive environment
            let res = self.pop()
            // Wipe the stack
            for i in (self.registers.initialFp &- 1)..<self.sp {
              self.stack[i] = .undef
            }
            self.sp = self.registers.initialFp &- 1
            return res
          } else {
            if case .procedure(let tproc) = self.stack[self.registers.fp &- 1] {
              self.printReturnTrace(tproc, tailCall: true)
            }
            self.exitFrame()
          }
        case .assertArgCount(let n):
          guard self.sp &- n == self.registers.fp else {
            throw RuntimeError.argumentCount(min: n,
                                             max: n,
                                             args: self.popAsList(self.sp &- self.registers.fp))
          }
        case .assertMinArgCount(let n):
          guard self.sp &- n >= self.registers.fp else {
            throw RuntimeError.argumentCount(min: n,
                                             args: self.popAsList(self.sp &- self.registers.fp))
          }
        case .noMatchingArgCount:
          throw RuntimeError.eval(.noMatchingCase,
                                  self.popAsList(self.sp &- self.registers.fp),
                                  self.pop())
        case .collectRest(let n):
          var rest = Expr.null
          while self.sp > self.registers.fp &+ n {
            rest = .pair(self.pop(), rest)
          }
          self.push(rest)
        case .alloc(let n):
          if self.sp &+ n > self.stack.count {
            if self.sp &+ n >= self.stack.capacity {
              self.stack.reserveCapacity(self.sp * 2)
            }
            for _ in 0..<(self.sp &+ n &- self.stack.count) {
              self.stack.append(.undef)
            }
          }
          self.sp += n
        case .reset(let index, let n):
          for i in (self.registers.fp &+ index)..<(self.registers.fp &+ index &+ n) {
            self.stack[i] = .undef
          }
        case .return:
          // Return to interactive environment
          if self.registers.topLevel {
            if self.registers.fp > 0,
               case .procedure(let tproc) = self.stack[self.registers.fp &- 1] {
              self.printReturnTrace(tproc, tailCall: true)
            }
            let res = self.pop()
            // Wipe the stack
            for i in (self.registers.initialFp &- 1)..<self.sp {
              self.stack[i] = .undef
            }
            // Reset stack and frame pointer
            self.sp = self.registers.initialFp &- 1
            return res
          } else {
            if case .procedure(let tproc) = self.stack[self.registers.fp &- 1] {
              self.printReturnTrace(tproc, tailCall: true)
            }
            self.exitFrame()
          }
        case .branch(let offset):
          self.registers.ip = self.registers.ip &+ offset &- 1
        case .branchIf(let offset):
          if self.pop().isTrue {
            self.registers.ip = self.registers.ip &+ offset &- 1
          }
        case .branchIfNot(let offset):
          if self.pop().isFalse {
            self.registers.ip = self.registers.ip &+ offset &- 1
          }
        case .keepOrBranchIfNot(let offset):
          let top = self.pop()
          if top.isFalse {
            self.registers.ip = self.registers.ip &+ offset &- 1
          } else {
            self.push(top)
          }
        case .branchIfArgMismatch(let n, let offset):
          if self.sp &- n != self.registers.fp {
            self.registers.ip = self.registers.ip &+ offset &- 1
          }
        case .branchIfMinArgMismatch(let n, let offset):
          if self.sp &- n < self.registers.fp {
            self.registers.ip = self.registers.ip &+ offset &- 1
          }
        case .and(let offset):
          if self.stack[self.sp &- 1].isFalse {
            self.registers.ip = self.registers.ip &+ offset &- 1
          } else {
            self.drop()
          }
        case .or(let offset):
          if self.stack[self.sp &- 1].isTrue {
            self.registers.ip = self.registers.ip &+ offset &- 1
          } else {
            self.drop()
          }
        case .force:
          if case .promise(let future) = self.stack[self.sp &- 1] {
            switch future.state {
              case .lazy(let proc):
                // Push frame pointer
                self.push(.fixnum(Int64(self.registers.fp)))
                // Push instruction pointer
                self.push(.fixnum(Int64(self.registers.ip)))
                // Push procedure that yields the forced result
                self.push(.procedure(proc))
                // Invoke native function
                var n = 0
                if case .closure(_, let newcaptured, let newcode) = try self.invoke(&n, 3).kind {
                  self.registers.use(code: newcode, captured: newcaptured, fp: self.sp)
                }
              case .shared(let future):
                // Replace the promise with the shared promise on the stack
                self.stack[self.sp &- 1] = .promise(future)
                // Execute force with the new promise on the stack
                self.registers.ip = self.registers.ip &- 1
              case .value(let value):
                // Replace the promise with the value on the stack
                self.stack[self.sp &- 1] = value
                // Jump over StoreInPromise operation
                self.registers.ip = self.registers.ip &+ 1
            }
          }
        case .storeInPromise:
          guard case .promise(let future) = self.stack[self.sp &- 2] else {
            preconditionFailure()
          }
          switch future.state {
            case .lazy(_), .shared(_):
              guard case .promise(let result) = self.stack[self.sp &- 1],
                    future.kind == result.kind else {
                let type: Type = future.kind == Promise.Kind.promise ? .promiseType : .streamType
                throw RuntimeError.type(self.stack[self.sp &- 1], expected: [type])
              }
              future.state = result.state
              result.state = .shared(future)
              if let ref = result.managementRef {
                self.context.objects.unmanage(ref)
                result.managementRef = nil
              }
              if let ref = future.managementRef, case .value(_) = future.state {
                self.context.objects.unmanage(ref)
                future.managementRef = nil
              }
            default:
              break
          }
          // Pop result of execution of thunk from stack
          self.sp = self.sp &- 1
          self.stack[self.sp] = .undef
          // Re-execute force
          self.registers.ip = self.registers.ip &- 2
        case .threadYield:
          return nil
        case .raiseError(let err, let n):
          var irritants: [Expr] = []
          for _ in 0..<n {
            irritants.insert(self.pop(), at: 0)
          }
          throw RuntimeError(SourcePosition.unknown,
                             ErrorDescriptor.eval(EvalError(rawValue: err)!),
                             irritants)
        case .pushCurrentTime:
          self.push(.flonum(Timer.currentTimeInSec))
        case .display:
          let obj = self.pop()
          switch obj {
            case .string(let str):
              self.context.delegate.print(str as String)
            default:
              self.context.delegate.print(obj.description)
          }
        case .newline:
          self.context.delegate.print("\n")
        case .eq:
          self.push(.makeBoolean(eqExpr(self.pop(), self.popUnsafe())))
        case .eqv:
          self.push(.makeBoolean(eqvExpr(self.pop(), self.popUnsafe())))
        case .equal:
          self.push(.makeBoolean(equalExpr(self.pop(), self.popUnsafe())))
        case .isPair:
          if case .pair(_, _) = self.popUnsafe() {
            self.push(.true)
          } else {
            self.push(.false)
          }
        case .isNull:
          self.push(.makeBoolean(self.popUnsafe() == .null))
        case .isUndef:
          self.push(.makeBoolean(self.popUnsafe() == .undef))
        case .cons:
          let cdr = self.pop()
          self.push(.pair(self.popUnsafe(), cdr))
        case .decons:
          let expr = self.popUnsafe()
          guard case .pair(let car, let cdr) = expr else {
            throw RuntimeError.type(expr, expected: [.pairType])
          }
          self.push(cdr)
          self.push(car)
        case .deconsKeyword:
          let expr = self.popUnsafe()
          guard case .pair(let fst, .pair(let snd, let cdr)) = expr else {
            throw RuntimeError.eval(.expectedKeywordArg, expr)
          }
          self.push(cdr)
          self.push(snd)
          self.push(fst)
        case .car:
          let expr = self.popUnsafe()
          guard case .pair(let car, _) = expr else {
            throw RuntimeError.type(expr, expected: [.pairType])
          }
          self.push(car)
        case .cdr:
          let expr = self.popUnsafe()
          guard case .pair(_, let cdr) = expr else {
            throw RuntimeError.type(expr, expected: [.pairType])
          }
          self.push(cdr)
        case .list(let n):
          var res = Expr.null
          for _ in 0..<n {
            res = .pair(self.pop(), res)
          }
          self.push(res)
        case .vector(let n):
          let vector = Collection(kind: .vector)
          var i = self.sp &- n
          while i < self.sp {
            vector.exprs.append(self.stack[i])
            i = i &+ 1
          }
          self.pop(n)
          self.push(.vector(vector))
        case .listToVector:
          let expr = self.popUnsafe()
          let vector = Collection(kind: .vector)
          var list = expr
          while case .pair(let car, let cdr) = list {
            vector.exprs.append(car)
            list = cdr
          }
          guard list.isNull else {
            throw RuntimeError.type(expr, expected: [.properListType])
          }
          self.push(.vector(vector))
        case .vectorAppend(let n):
          let vector = Collection(kind: .vector)
          var i = self.sp &- n
          while i < self.sp {
            vector.exprs.append(contentsOf: try self.stack[i].vectorAsCollection().exprs)
            i = i &+ 1
          }
          self.pop(n)
          self.push(.vector(vector))
        case .isVector:
          if case .vector(let vector) = self.popUnsafe(), !vector.isGrowableVector {
            self.push(.true)
          } else {
            self.push(.false)
          }
        case .not:
          if case .false = self.popUnsafe() {
            self.push(.true)
          } else {
            self.push(.false)
          }
        case .fxPlus:
          let rhs = self.pop()
          self.push(.fixnum(try self.popUnsafe().asInt64() &+ rhs.asInt64()))
        case .fxMinus:
          let rhs = self.pop()
          self.push(.fixnum(try self.popUnsafe().asInt64() &- rhs.asInt64()))
        case .fxMult:
          let rhs = self.pop()
          self.push(.fixnum(try self.popUnsafe().asInt64() &* rhs.asInt64()))
        case .fxDiv:
          let rhs = self.pop()
          self.push(.fixnum(try self.popUnsafe().asInt64() / rhs.asInt64()))
        case .fxInc:
          let idx = self.sp &- 1
          switch self.stack[idx] {
            case .fixnum(let x):
              self.stack[idx] = .fixnum(x &+ 1)
            default:
              throw RuntimeError.type(self.stack[idx], expected: [.exactIntegerType])
          }
        case .fxDec:
          let idx = self.sp &- 1
          switch self.stack[idx] {
            case .fixnum(let x):
              self.stack[idx] = .fixnum(x &- 1)
            default:
              throw RuntimeError.type(self.stack[idx], expected: [.exactIntegerType])
          }
        case .fxIsZero:
          let idx = self.sp &- 1
          switch self.stack[idx] {
            case .fixnum(let x):
              self.stack[idx] = x == 0 ? .true : .false
            default:
              throw RuntimeError.type(self.stack[idx], expected: [.exactIntegerType])
          }
        case .fxEq:
          let rhs = self.pop()
          self.push(.makeBoolean(try self.popUnsafe().asInt64() == rhs.asInt64()))
        case .fxLt:
          let rhs = self.pop()
          self.push(.makeBoolean(try self.popUnsafe().asInt64() < rhs.asInt64()))
        case .fxGt:
          let rhs = self.pop()
          self.push(.makeBoolean(try self.popUnsafe().asInt64() > rhs.asInt64()))
        case .fxLtEq:
          let rhs = self.pop()
          self.push(.makeBoolean(try self.popUnsafe().asInt64() <= rhs.asInt64()))
        case .fxGtEq:
          let rhs = self.pop()
          self.push(.makeBoolean(try self.popUnsafe().asInt64() >= rhs.asInt64()))
        case .flPlus:
          let rhs = self.pop()
          self.push(.flonum(try self.popUnsafe().asDouble() + rhs.asDouble()))
        case .flMinus:
          let rhs = self.pop()
          self.push(.flonum(try self.popUnsafe().asDouble() - rhs.asDouble()))
        case .flMult:
          let rhs = self.pop()
          self.push(.flonum(try self.popUnsafe().asDouble() * rhs.asDouble()))
        case .flDiv:
          let rhs = self.pop()
          self.push(.flonum(try self.popUnsafe().asDouble() / rhs.asDouble()))
        case .flEq:
          let rhs = self.pop()
          self.push(.makeBoolean(try self.popUnsafe().asDouble() == rhs.asDouble()))
        case .flLt:
          let rhs = self.pop()
          self.push(.makeBoolean(try self.popUnsafe().asDouble() < rhs.asDouble()))
        case .flGt:
          let rhs = self.pop()
          self.push(.makeBoolean(try self.popUnsafe().asDouble() > rhs.asDouble()))
        case .flLtEq:
          let rhs = self.pop()
          self.push(.makeBoolean(try self.popUnsafe().asDouble() <= rhs.asDouble()))
        case .flGtEq:
          let rhs = self.pop()
          self.push(.makeBoolean(try self.popUnsafe().asDouble() >= rhs.asDouble()))
      }
    }
    return .null
  }
  
  public override func mark(in gc: GarbageCollector) {
    for i in 0..<self.sp {
      gc.markLater(self.stack[i])
    }
    self.registers.mark(in: gc)
    self.winders?.mark(in: gc)
    gc.mark(self.parameters)
  }
  
  /// Debugging output
  private func stackFragmentDescr(_ ip: Int, _ fp: Int, header: String? = nil) -> String {
    var res = header ?? "╔══════════════════════════════════════════════════════\n"
    res += "║ ip = \(ip), fp = \(fp), sp = \(self.sp), max_sp = \(self.maxSp)\n"
    res += "╟──────────────────────────────────────────────────────\n"
    let start = fp > 2 ? fp - 3 : 0
    for i in start..<self.sp {
      if i == fp {
        res += "║  ➤ [\(i)] \(self.stack[i])\n"
      } else {
        res += "║    [\(i)] \(self.stack[i])\n"
      }
    }
    res += "╚══════════════════════════════════════════════════════\n"
    return res
  }
  
  /// Reset virtual machine
  public func release() {
    self.stack = Exprs(repeating: .undef, count: 1024)
    self.sp = 0
    self.maxSp = 0
    self.registers = Registers(code: Code([], [], []), captured: [], fp: 0, root: true)
    self.winders = nil
    self.parameters = HashTable(equiv: .eq)
    self.execInstr = 0
    self.setParameterProc = nil
    self.traceCalls = .off
  }
}
