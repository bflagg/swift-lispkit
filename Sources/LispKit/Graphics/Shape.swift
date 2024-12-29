//
//  Shape.swift
//  LispKit
//
//  Created by Matthias Zenger on 30/06/2018.
//  Copyright © 2018-2021 ObjectHub. All rights reserved.
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
import CoreGraphics
#if os(iOS) || os(watchOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

///
/// A `Shape` object consist of straight and curved line segments joined together.
/// Rectangles, ovals, arcs, glypths, polygons etc. all can be represented as a
/// `Shape` object.
///
/// The `Shape` object model is prototype-based. Any `Shape` object can be used
/// as a prototype for a new `Shape` object, either as it was defined or transformed
/// by a given transformation. In addition, there is a range of predefined `Shape`
/// prototypes to bootstrap the object model.
///
/// `Shape` objects refine their prototype with a sequence of shape constructors.
/// The following constructors are supported:
///    - _move(to: CGPoint):_ Sets a new point.
///    - _line(to: CGPoint):_ Draws a line from the current point to the given point.
///    - _curve(to: CGPoint, controlCurrent: CGPoint, controlTarget: CGPoint):_ Draws a
///      curve from the current point to the given point using a control point each
///      for determining the tangents of the curve at the end points.
///    - _text(String, in: NSFont, width: Double, height: Double):_ Includes glypths
///      for the given text in the given font at the current point assuming a bounding
///      box defined by `width` and `height`.
///    - _include(Shape):_ Includes another `Shape` object at the current point.
///
/// The `Shape` object model is fully dynamic. If a `Shape` object depends on other
/// `Shape` objects, e.g. via prototype or inclusion relationships, then, whenever
/// one of those objects changes, the changes get reflected immediately also for this
/// `Shape` object. This makes it possible to evolve dependent shapes independently of
/// each other.
///
public final class Shape: NativeObject {

  /// Type representing shapes.
  public static let type = Type.objectType(Symbol(uninterned: "shape"))

  /// The prototype of this shape.
  public let prototype: ShapePrototype
  
  /// The constructors refining the prototype.
  public private(set) var constructors: [ShapeConstructor]
  
  /// If this shape is drawn in a graphics context with a flipped coordinate system and
  /// the construction of the shape does not consider this, then setting `flipped` to
  /// true will automatically flip the shape vertically. This is, in particular, important
  /// for the inclusion of glypths which are otherwise mirrored vertically.
  public let flipped: Bool
  
  /// If a shape is defined as a closed shape, then the start and end point are the same;
  /// e.g. in this case, it will be drawn as a closed polygon.
  public let closed: Bool
  
  /// This is the internally generated `BezierPath` object. This is a cache only and gets
  /// reset whenever a shape gets changed directly or indirectly.
  private var bezierPath: BezierPath?
  
  /// Other `Shape` objects in which this shape is included. Dependency management is
  /// necessary to refresh dependent shapes whenever this shape changes.
  private var owners: Owners<Shape>
  
  /// Initializer copying another shape.
  public init(copy shape: Shape) {
    self.prototype = shape.prototype
    self.constructors = shape.constructors
    self.flipped = shape.flipped
    self.closed = shape.closed
    self.bezierPath = nil
    self.owners = Owners<Shape>()
    super.init()
    switch self.prototype {
      case .shape(let shape),
           .transformed(let shape, _),
           .flipped(let shape, _, _, _):
        shape.owners.compact()
        shape.owners.include(self)
      default:
        break
    }
  }
  
  /// Initializer of a shape. `Shape` objects are initialized with a prototype, and optionally,
  /// information on whether this shape is a closed and flipped shape.
  public init(_ prototype: ShapePrototype = ShapePrototype.none,
              closed: Bool = false,
              flipped: Bool = false) {
    self.prototype = prototype
    self.constructors = []
    self.flipped = flipped
    self.closed = closed
    self.bezierPath = nil
    self.owners = Owners<Shape>()
    super.init()
    switch prototype {
      case .shape(let shape),
           .transformed(let shape, _),
           .flipped(let shape, _, _, _):
        shape.owners.compact()
        shape.owners.include(self)
      default:
        break
    }
  }

  /// Return native object type.
  public override var type: Type {
    return Self.type
  }
  
  /// Returns true if there are no shape constructors yet
  public var isEmpty: Bool {
    return self.constructors.isEmpty
  }
  
  /// Appends a new shape constructor to this shape. This method returns true if it was
  /// possible to include the constructor. On rare occasions, this is not possible. For
  /// instance, it is not possible to define mutually dependent shapes. It is guaranteed
  /// that the shape dependency graph is always acyclic.
  @discardableResult public func append(_ constructor: ShapeConstructor) -> Bool {
    if case .include(let other) = constructor {
      other.owners.compact()
      // Do not allow recursive dependencies
      if other.includes(self) {
        return false
      }
      other.owners.include(self)
    }
    self.markDirty()
    self.constructors.append(constructor)
    return true
  }
  
  /// Checks if this shape depends on the given shape.
  public func includes(_ shape: Shape) -> Bool {
    guard self !== shape else {
      return true
    }
    switch self.prototype {
      case .shape(let other),
           .transformed(let other, _),
           .flipped(let other, _, _, _):
        if other.includes(shape) {
          return true
        }
      default:
        break
    }
    for constructor in self.constructors {
      if case .include(let other) = constructor, other.includes(shape) {
        return true
      }
    }
    return false
  }
  
  /// Returns true if the given point is contained in this shape.
  public func contains(_ point: CGPoint) -> Bool {
    return self.compile().contains(point)
  }
  
  /// Draws this shape as a stroke with the given line width into the current graphics context.
  /// This method uses the current stroke color of the drawing.
  public func stroke(lineWidth: Double = 1.0) {
    let path = self.compile()
    path.lineWidth = CGFloat(lineWidth)
    path.setLineDash(nil, count: 0, phase: 0.0)
    path.stroke()
  }
  
  /// Draws this shape as a dashed stroke with the given line width, dash phase, and dash lengths
  /// into the current graphics context. This method uses the current stroke color of the
  /// drawing.
  public func stroke(lineWidth: Double = 1.0,
                     lineDashPhase: Double = 0.0,
                     lineDashLengths: [Double]) {
    let path = self.compile()
    path.lineWidth = CGFloat(lineWidth)
    var cgLineDashLengths: [CGFloat] = []
    for len in lineDashLengths {
      cgLineDashLengths.append(CGFloat(len))
    }
    path.setLineDash(cgLineDashLengths,
                     count: cgLineDashLengths.count,
                     phase: CGFloat(lineDashPhase))
    path.stroke()
  }
  
  /// Fills this shape in the current graphics context with the current fill color.
  public func fill() {
    self.compile().fill()
  }
  
  /// Returns a bounding box for this shape.
  public var bounds: CGRect {
    return self.compile().bounds
  }
  
  /// Method for computing the `BezierPath` object from the shape definition.
  public func compile() -> BezierPath {
    if let bezierPath = self.bezierPath {
      return bezierPath
    }
    self.bezierPath = self.compileNew()
    return self.bezierPath!
  }
  
  func compileNew() -> BezierPath {
    let bezierPath = self.prototype.compile()
    for constructor in self.constructors {
      constructor.compile(into: bezierPath)
    }
    if self.flipped {
      let bounds = bezierPath.bounds
      #if os(iOS) || os(watchOS) || os(tvOS)
      bezierPath.apply(CGAffineTransform(translationX: 0.0, y: -bounds.origin.y))
      bezierPath.apply(CGAffineTransform(scaleX: 1.0, y: -1.0))
      bezierPath.apply(CGAffineTransform(translationX: 0.0,
                                         y: bounds.origin.y + bounds.height))
      #elseif os(macOS)
      bezierPath.transform(using: AffineTransform(translationByX: 0.0, byY: -bounds.origin.y))
      bezierPath.transform(using: AffineTransform(scaleByX: 1.0, byY: -1.0))
      bezierPath.transform(using: AffineTransform(translationByX: 0.0,
                                                  byY: bounds.origin.y + bounds.height))
      #endif
    }
    if self.closed {
      bezierPath.close()
    }
    return bezierPath
  }
  
  /// Internal method for invalidating the cached `BezierPath` object of this shape and all
  /// shapes that depend on it either directly or indirectly.
  func markDirty() {
    if self.bezierPath != nil {
      self.owners.compact()
      self.bezierPath = nil
      for owner in self.owners {
        owner.markDirty()
      }
    }
  }
}

///
/// Enumeration listing all supported shape prototypes:
///    - _none:_ The empty shape
///    - _line(CGPoint, CGPoint):_ A line between two given points
///    - _rect(CGRect):_ A rectangle defined by the lower left corner and a width and height
///    - _roundedRect(CGRect, xradius: Double, yradius: Double):_ A rounded rectangle defined
///       by the lower left corner, a width and height, and x/y radius for the rounded corners
///    - _oval(CGRect):_ An oval whose bounding box is the given rectangle.
///    - _arc(center: CGPoint, radius: Double, startAngle: Double, endAngle: Double,
///      clockwise: Bool)_: An arc around a center defined by a radius, a start angle and an
///      end angle.
///    - _glyphs(String, in: CGRect, font: NSFont):_ Includes glypths for the given text in
///      the given font at the position `in.origin` assuming a bounding box defined by `in.size`.
///    - _interpolated([CGPoint], method: InterpolationMethod):_ A smooth curve drawn through the
///      given points via a provided interpolation method.
///    - _shape(Shape):_ Another shape object.
///    - _transformed(Shape, Transformation):_ Another shape transformed by a given transformation.
///    - _flipped(Shape, CGRect?, vertical, horizontal):_ Flips the given shape in the given
///      rectangle either horizontally, vertically or both. If no rectangle is given, the
///      bounding box of the shape is used.
///
public enum ShapePrototype {
  case none
  case line(CGPoint, CGPoint)
  case rect(CGRect)
  case roundedRect(CGRect, xradius: Double, yradius: Double)
  case oval(CGRect)
  case arc(center: CGPoint, radius: Double, startAngle: Double, endAngle: Double, clockwise: Bool)
  case glyphs(String, in: CGRect, font: Font, flipped: Bool)
  case interpolated([CGPoint], method: InterpolationMethod)
  case path(BezierPath)
  case shape(Shape)
  case transformed(Shape, Transformation)
  case flipped(Shape, CGRect?, vertical: Bool, horizontal: Bool)
  
  func compile() -> BezierPath {
    switch self {
      case .none:
        let bezierPath = BezierPath()
        bezierPath.move(to: CGPoint(x: 0.0, y: 0.0))
        return bezierPath
      case .line(let start, let end):
        let bezierPath = BezierPath()
        bezierPath.move(to: start)
        #if os(iOS) || os(watchOS) || os(tvOS)
        bezierPath.addLine(to: end)
        #elseif os(macOS)
        bezierPath.line(to: end)
        #endif
        return bezierPath
      case .rect(let rect):
        return BezierPath(rect: rect)
      case .roundedRect(let rect, let xrad, let yrad):
        #if os(iOS) || os(watchOS) || os(tvOS)
        return BezierPath(roundedRect: rect,
                          byRoundingCorners: .allCorners,
                          cornerRadii: CGSize(width: CGFloat(xrad), height: CGFloat(yrad)))
        #elseif os(macOS)
        return BezierPath(roundedRect: rect, xRadius: CGFloat(xrad), yRadius: CGFloat(yrad))
        #endif
      case .oval(let rect):
        let bezierPath = BezierPath(ovalIn: rect)
        bezierPath.close()
        return bezierPath
      case .arc(let center, let radius, let start, let end, let clockwise):
        let bezierPath = BezierPath()
        #if os(iOS) || os(watchOS) || os(tvOS)
        bezierPath.addArc(withCenter: center,
                          radius: CGFloat(radius),
                          startAngle: CGFloat(start),
                          endAngle: CGFloat(end),
                          clockwise: clockwise)
        #elseif os(macOS)
        bezierPath.appendArc(withCenter: center,
                             radius: CGFloat(radius),
                             startAngle: CGFloat(start * 180 / .pi), // Seriously? In degrees?
                             endAngle: CGFloat(end * 180 / .pi),
                             clockwise: !clockwise)
        #endif
        return bezierPath
      case .glyphs(let str, let rect, let font, let flipped):
        let bezierPath = BezierPath()
        bezierPath.move(to: rect.origin)
        #if os(iOS) || os(watchOS) || os(tvOS)
        // This does not exactly do what's implemented for macOS as it ignores the width and
        // height of `rect`.
        let textPath = CGMutablePath()
        let ctFont = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
        let attributedString =
          NSAttributedString(string: str,
                             attributes: [kCTFontAttributeName as NSAttributedString.Key : ctFont])
        let line = CTLineCreateWithAttributedString(attributedString)
        let runs = (CTLineGetGlyphRuns(line) as [AnyObject]) as! [CTRun]
        for run in runs {
          let attributes: NSDictionary = CTRunGetAttributes(run)
          let ctfont = attributes[kCTFontAttributeName as String] as! CTFont
          let count = CTRunGetGlyphCount(run)
          for index in 0..<count {
            let range = CFRangeMake(index, 1)
            var glyph = CGGlyph()
            CTRunGetGlyphs(run, range, &glyph)
            var position = CGPoint()
            CTRunGetPositions(run, range, &position)
            let letter = CTFontCreatePathForGlyph(ctfont, glyph, nil)
            if let letter = letter  {
              textPath.addPath(
                letter,
                transform: CGAffineTransform(translationX: position.x, y: position.y))
            }
          }
        }
        bezierPath.append(UIBezierPath(cgPath: textPath))
        #elseif os(macOS)
        let storage = NSTextStorage(string: str, attributes: [NSAttributedString.Key.font : font])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: rect.size)
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        let glyphRange = manager.glyphRange(for: container)
        var glyphBuffer = [CGGlyph](repeating: 0, count: glyphRange.length)
        let glyphCount = manager.getGlyphs(in: glyphRange,
                                           glyphs: &glyphBuffer,
                                           properties: nil,
                                           characterIndexes: nil,
                                           bidiLevels: nil)
        bezierPath.append(withCGGlyphs: &glyphBuffer, count: glyphCount, in: font)
        #endif
        var bounds = bezierPath.bounds
        #if os(iOS) || os(watchOS) || os(tvOS)
        bezierPath.apply(CGAffineTransform(translationX: rect.origin.x - bounds.origin.x,
                                           y: rect.origin.y - bounds.origin.y))
        #elseif os(macOS)
        bezierPath.transform(using: AffineTransform(translationByX: rect.origin.x - bounds.origin.x,
                                                    byY: rect.origin.y - bounds.origin.y))
        #endif
        if flipped {
          bounds = bezierPath.bounds
          #if os(iOS) || os(watchOS) || os(tvOS)
          bezierPath.apply(CGAffineTransform(translationX: 0.0, y: -bounds.origin.y))
          bezierPath.apply(CGAffineTransform(scaleX: 1.0, y: -1.0))
          bezierPath.apply(CGAffineTransform(translationX: 0.0, y: bounds.origin.y + bounds.height))
          #elseif os(macOS)
          bezierPath.transform(using: AffineTransform(translationByX: 0.0, byY: -bounds.origin.y))
          bezierPath.transform(using: AffineTransform(scaleByX: 1.0, byY: -1.0))
          bezierPath.transform(using: AffineTransform(translationByX: 0.0,
                                                      byY: bounds.origin.y + bounds.height))
          #endif
        }
        return bezierPath
      case .interpolated(let points, let method):
        return method.compile(points)
      case .path(let bp):
        return bp.mutableCopy() as! BezierPath
      case .shape(let shape):
        return shape.compileNew()
      case .transformed(let shape, let transform):
        #if os(iOS) || os(watchOS) || os(tvOS)
        let bezierPath = shape.compile().copy() as! BezierPath
        bezierPath.apply(transform.affineTransform)
        return bezierPath
        #elseif os(macOS)
        return NSAffineTransform(transform: transform.affineTransform).transform(shape.compile())
        #endif
      case .flipped(let shape, let box, let vertical, let horizontal):
        var bezierPath = shape.compile()
        let bounds = box ?? bezierPath.bounds
        #if os(iOS) || os(watchOS) || os(tvOS)
        bezierPath = bezierPath.copy() as! BezierPath
        bezierPath.apply(CGAffineTransform(translationX: -bounds.origin.x,
                                           y: -bounds.origin.y))
        bezierPath.apply(CGAffineTransform(scaleX: horizontal ? -1.0 : 1.0,
                                           y: vertical ? -1.0 : 1.0))
        bezierPath.apply(CGAffineTransform(translationX: bounds.origin.x +
                                                         (horizontal ? bounds.width : 0.0),
                                           y: bounds.origin.y + (vertical ? bounds.height : 0.0)))
        #elseif os(macOS)
        bezierPath = NSAffineTransform(transform:
          AffineTransform(translationByX: -bounds.origin.x,
                          byY: -bounds.origin.y)).transform(bezierPath)
        bezierPath.transform(using: AffineTransform(scaleByX: horizontal ? -1.0 : 1.0,
                                                    byY: vertical ? -1.0 : 1.0))
        bezierPath.transform(using: AffineTransform(translationByX: bounds.origin.x +
                                                                    (horizontal ? bounds.width : 0.0),
                                                    byY: bounds.origin.y +
                                                         (vertical ? bounds.height : 0.0)))
        #endif
        return bezierPath
    }
  }
}

///
/// Enumeration of the supported interpolation methods. There are two methods supported currently:
///    - _Catmull Rom_, and
///    - _Hermite_.
///
public enum InterpolationMethod {
  case catmullRom(closed: Bool, alpha: Double)
  case hermite(closed: Bool, alpha: Double)
  
  func compile(_ points: [CGPoint]) -> BezierPath {
    switch self {
      case .catmullRom(let closed, let alpha):
        return self.catmullRom(points: points, closed: closed, alpha: CGFloat(alpha))! // FIXME
      case .hermite(let closed, let alpha):
        return self.hermite(points: points, closed: closed, alpha: CGFloat(alpha))! // FIXME
    }
  }
  
  func hermite(points: [CGPoint],
               closed: Bool,
               alpha: CGFloat = 1.0 / 3.0) -> BezierPath? {
    guard points.count > 1 else {
        return nil
    }
    let nCurves = closed ? points.count : points.count - 1
    let path = BezierPath()
    for i in 0..<nCurves {
      var curPt = points[i]
      if i == 0 {
        path.move(to: curPt)
      }
      var prevPt = points[i < 1 ? points.count - 1 : i - 1]
      var nextPt = points[(i + 1) % points.count]
      var mx = (nextPt.x - (closed || i > 0 ? prevPt.x : curPt.x)) * 0.5
      var my = (nextPt.y - (closed || i > 0 ? prevPt.y : curPt.y)) * 0.5
      let ctrlPt1 = CGPoint(x: curPt.x + mx * alpha, y: curPt.y + my * alpha)
      prevPt = curPt
      curPt = nextPt
      nextPt = points[(i + 2) % points.count]
      mx = ((closed || i < nCurves - 1 ? nextPt.x : curPt.x) - prevPt.x) * 0.5
      my = ((closed || i < nCurves - 1 ? nextPt.y : curPt.y) - prevPt.y) * 0.5
      let ctrlPt2 = CGPoint(x: curPt.x - mx * alpha, y: curPt.y - my * alpha)
      #if os(iOS) || os(watchOS) || os(tvOS)
      path.addCurve(to: curPt, controlPoint1: ctrlPt1, controlPoint2: ctrlPt2)
      #elseif os(macOS)
      path.curve(to: curPt, controlPoint1: ctrlPt1, controlPoint2: ctrlPt2)
      #endif
    }
    if closed {
      path.close()
    }
    return path
  }
  
  func catmullRom(points: [CGPoint],
                  closed: Bool,
                  alpha: CGFloat = 1.0 / 3.0) -> BezierPath? {
    guard points.count > 3,
          alpha >= 0.0 && alpha <= 1.0 else {
      return nil
    }
    let endIndex = closed ? points.count : (points.count - 2)
    var path: BezierPath? = nil
    var i = closed ? 0 : 1
    while i < endIndex {
      let p0 = points[i < 1 ? (points.count - 1) : (i - 1)]
      let p1 = points[i]
      let p2 = points[(i + 1) % points.count]
      let p3 = points[(i + 2) % points.count]
      let d1 = pointLength(pointSub(p1, p0))
      let d2 = pointLength(pointSub(p2, p1))
      let d3 = pointLength(pointSub(p3, p2))
      var b1: CGPoint
      if abs(d1) < InterpolationMethod.epsilon {
        b1 = p1
      } else {
        b1 = pointMult(p2, pow(d1, 2.0 * alpha))
        b1 = pointSub(b1, pointMult(p0, pow(d2, 2.0 * alpha)))
        b1 = pointAdd(b1, pointMult(p1, 2.0 * pow(d1, 2.0 * alpha) +
                                        3.0 * pow(d1, alpha) * pow(d2, alpha) +
                                        pow(d2, 2.0 * alpha)))
        b1 = pointMult(b1, 1.0 / (3.0 * pow(d1, alpha) * (pow(d1, alpha) + pow(d2, alpha))))
      }
      var b2: CGPoint
      if abs(d3) < InterpolationMethod.epsilon {
        b2 = p2
      } else {
        b2 = pointMult(p1, pow(d3, 2.0 * alpha))
        b2 = pointSub(b2, pointMult(p3, pow(d2, 2.0 * alpha)))
        b2 = pointAdd(b2, pointMult(p2, 2.0 * pow(d3, 2.0 * alpha) +
                                        3.0 * pow(d3, alpha) * pow(d2, alpha) +
                                        pow(d2, 2.0 * alpha)))
        b2 = pointMult(b2, 1.0 / (3.0 * pow(d3, alpha) * (pow(d3, alpha) + pow(d2, alpha))))
      }
      if let path = path {
        #if os(iOS) || os(watchOS) || os(tvOS)
        path.addCurve(to: p2, controlPoint1: b1, controlPoint2: b2)
        #elseif os(macOS)
        path.curve(to: p2, controlPoint1: b1, controlPoint2: b2)
        #endif
      } else {
        path = BezierPath()
        path?.move(to: p1)
        #if os(iOS) || os(watchOS) || os(tvOS)
        path?.addCurve(to: p2, controlPoint1: b1, controlPoint2: b2)
        #elseif os(macOS)
        path?.curve(to: p2, controlPoint1: b1, controlPoint2: b2)
        #endif
      }
      i += 1
    }
    if closed {
      path?.close()
    }
    return path
  }
  
  private func pointLength(_ v: CGPoint) -> CGFloat {
    return (v.x * v.x + v.y * v.y).squareRoot()
  }
  
  private func pointAdd(_ v1: CGPoint, _ v2: CGPoint) -> CGPoint {
    return CGPoint(x: v1.x + v2.x, y: v1.y + v2.y)
  }
  
  private func pointSub(_ v1: CGPoint, _ v2: CGPoint) -> CGPoint {
    return CGPoint(x: v1.x - v2.x, y: v1.y - v2.y)
  }
  
  private func pointMult(_ v: CGPoint, _ s: CGFloat) -> CGPoint {
    return CGPoint(x: v.x * CGFloat(s), y: v.y * CGFloat(s))
  }
  
  public static let epsilon: CGFloat = 1.0e-5
}

///
/// Enumeration of all supported shape constructors:
///    - _move(to: CGPoint):_ Sets a new point.
///    - _line(to: CGPoint):_ Draws a line from the current point to the given point.
///    - _curve(to: CGPoint, controlCurrent: CGPoint, controlTarget: CGPoint):_ Draws a
///      curve from the current point to the given point using a control point each
///      for determining the tangents of the curve at the end points.
///    - _relativeMove(to: CGPoint):_ Sets a new point relative to the current point.
///    - _relativeLine(to: CGPoint):_ Draws a line from the current point to the given point
///      which is specified relative to the current point.
///    - _relativeCurve(to: CGPoint, controlCurrent: CGPoint, controlTarget: CGPoint):_ Draws a
///      curve from the current point to the given point using a control point each
///      for determining the tangents of the curve at the end points. All points are relative to
///      the current point.
///    - _include(Shape):_ Includes another `Shape` object at the current point.
///
public enum ShapeConstructor {
  case move(to: CGPoint)
  case line(to: CGPoint)
  case curve(to: CGPoint, controlCurrent: CGPoint, controlTarget: CGPoint)
  case relativeMove(to: CGPoint)
  case relativeLine(to: CGPoint)
  case relativeCurve(to: CGPoint, controlCurrent: CGPoint, controlTarget: CGPoint)
  case include(Shape)
  
  func compile(into path: BezierPath) {
    #if os(iOS) || os(watchOS) || os(tvOS)
    switch self {
      case .move(let point):
        path.move(to: point)
      case .line(let point):
        path.addLine(to: point)
      case .curve(let target, let controlCurrent, let controlTarget):
        path.addCurve(to: target, controlPoint1: controlCurrent, controlPoint2: controlTarget)
      case .relativeMove(let point):
        path.move(to: CGPoint(x: path.currentPoint.x + point.x, y: path.currentPoint.y + point.y))
      case .relativeLine(let point):
        path.addLine(to: CGPoint(x: path.currentPoint.x + point.x, y: path.currentPoint.y + point.y))
      case .relativeCurve(let target, let controlCurrent, let controlTarget):
        path.addCurve(to: CGPoint(x: path.currentPoint.x + target.x,
                                  y: path.currentPoint.y + target.y),
                      controlPoint1: CGPoint(x: path.currentPoint.x + controlCurrent.x,
                                             y: path.currentPoint.y + controlCurrent.y),
                      controlPoint2: CGPoint(x: path.currentPoint.x + controlTarget.x,
                                             y: path.currentPoint.y + controlTarget.y))
      case .include(let shape):
        path.append(shape.compile())
    }
    #elseif os(macOS)
    switch self {
      case .move(let point):
        path.move(to: point)
      case .line(let point):
        path.line(to: point)
      case .curve(let target, let controlCurrent, let controlTarget):
        path.curve(to: target, controlPoint1: controlCurrent, controlPoint2: controlTarget)
      case .relativeMove(let point):
        path.relativeMove(to: point)
      case .relativeLine(let point):
        path.relativeLine(to: point)
      case .relativeCurve(let target, let controlCurrent, let controlTarget):
        path.relativeCurve(to: target, controlPoint1: controlCurrent, controlPoint2: controlTarget)
      case .include(let shape):
        path.append(shape.compile())
    }
    #endif
  }
}

#if os(iOS) || os(watchOS) || os(tvOS)
public typealias BezierPath = UIBezierPath
public typealias Font = UIFont
#elseif os(macOS)
public typealias BezierPath = NSBezierPath
public typealias Font = NSFont
#endif
