//
//  BoxLibrary.swift
//  LispKit
//
//  Created by Matthias Zenger on 18/07/2016.
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

///
/// Box library: based on Racket spec.
/// 
public final class BoxLibrary: NativeLibrary {
  
  /// Name of the library.
  public override class var name: [String] {
    return ["lispkit", "box"]
  }
  
  /// Dependencies of the library.
  public override func dependencies() {
    self.`import`(from: ["lispkit", "base"], "define")
  }
  
  /// Declarations of the library.
  public override func declarations() {
    // Boxes
    self.define(Procedure("box?", isBox))
    self.define(Procedure("box", box))
    self.define(Procedure("unbox", unbox))
    self.define(Procedure("set-box!", setBox))
    self.define("update-box!", via:
      "(define (update-box! box proc) (set-box! box (proc (unbox box))))")
    
    // Mutable pairs
    self.define(Procedure("mpair?", isMpair))
    self.define(Procedure("mcons", mcons))
    self.define(Procedure("mcar", mcar))
    self.define(Procedure("mcdr", mcdr))
    self.define(Procedure("set-mcar!", setMcar))
    self.define(Procedure("set-mcdr!", setMcdr))
  }
  
  //-------- MARK: - Boxes
  
  func box(_ expr: Expr?) -> Expr {
    return .box(Cell(expr ?? .undef))
  }
  
  func unbox(_ expr: Expr) throws -> Expr {
    guard case .box(let cell) = expr else {
      throw EvalError.typeError(expr, [.boxType])
    }
    return cell.value
  }
  
  func setBox(_ expr: Expr, value: Expr) throws -> Expr {
    guard case .box(let cell) = expr else {
      throw EvalError.typeError(expr, [.boxType])
    }
    // Set cell value. Guarantee that cells for which `set-box!` is called are managed
    // by a managed object pool.
    (value.isAtom ? cell : self.context.objects.manage(cell)).value = value
    return .void
  }
  
  func isBox(_ expr: Expr) -> Expr {
    guard case .box(_) = expr else {
      return .false
    }
    return .true
  }
  
  //-------- MARK: - Mutable pairs
  
  func isMpair(_ expr: Expr) -> Expr {
    guard case .mpair(_) = expr else {
      return .false
    }
    return .true
  }

  func mcons(_ car: Expr, cdr: Expr) throws -> Expr {
    return .mpair(Tuple(car, cdr))
  }
  
  func mcar(_ expr: Expr) throws -> Expr {
    guard case .mpair(let tuple) = expr else {
      throw EvalError.typeError(expr, [.mpairType])
    }
    return tuple.fst
  }
  
  func mcdr(_ expr: Expr) throws -> Expr {
    guard case .mpair(let tuple) = expr else {
      throw EvalError.typeError(expr, [.mpairType])
    }
    return tuple.snd
  }
  
  func setMcar(_ expr: Expr, value: Expr) throws -> Expr {
    guard case .mpair(let tuple) = expr else {
      throw EvalError.typeError(expr, [.mpairType])
    }
    // Set car of tuple. Guarantee that tuples for which `set-mcar!` is called are managed
    // by a managed object pool.
    (value.isAtom ? tuple : self.context.objects.manage(tuple)).fst = value
    return .void
  }
  
  func setMcdr(_ expr: Expr, value: Expr) throws -> Expr {
    guard case .mpair(let tuple) = expr else {
      throw EvalError.typeError(expr, [.mpairType])
    }
    // Set cdr of tuple. Guarantee that tuples for which `set-mcdr!` is called are managed
    // by a managed object pool.
    (value.isAtom ? tuple : self.context.objects.manage(tuple)).snd = value
    return .void
  }
}