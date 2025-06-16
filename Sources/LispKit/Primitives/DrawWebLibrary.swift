//
//  DrawWebLibrary.swift
//  LispKit
//
//  Created by Matthias Zenger on 09/06/2025.
//  Copyright © 2025 ObjectHub. All rights reserved.
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
import WebKit

public final class DrawWebLibrary: NativeLibrary {
  
  // Crop modes
  private let all: Symbol
  private let trim: Symbol
  private let inset: Symbol
  private let insetTrimmed: Symbol
  private let rect: Symbol
  private let rectTrimmed: Symbol
  
  /// Initialize symbols.
  public required init(in context: Context) throws {
    self.all = context.symbols.intern("all")
    self.trim = context.symbols.intern("trim")
    self.inset = context.symbols.intern("inset")
    self.insetTrimmed = context.symbols.intern("inset-trimmed")
    self.rect = context.symbols.intern("rect")
    self.rectTrimmed = context.symbols.intern("rect-trimmed")
    try super.init(in: context)
  }
  
  /// Name of the library.
  public override class var name: [String] {
    return ["lispkit", "draw", "web"]
  }
  
  /// Dependencies of the library.
  public override func dependencies() {
  }
  
  /// Declarations of the library.
  public override func declarations() {
    self.define(Procedure("make-web-client", self.makeWebClient))
    self.define(Procedure("web-client?", self.isWebClient))
    self.define(Procedure("web-client-busy?", self.isWebClientBusy))
    self.define(Procedure("web-client-snapshot-html", self.webClientSnapshotHtml))
    self.define(Procedure("web-client-snapshot-data", self.webClientSnapshotData))
    self.define(Procedure("web-client-snapshot-file", self.webClientSnapshotFile))
    self.define(Procedure("web-client-snapshot-url", self.webClientSnapshotUrl))
    self.define(Procedure("web-client-pdf-snapshot-html", self.webClientSnapshotHtmlPdf))
    self.define(Procedure("web-client-pdf-snapshot-data", self.webClientSnapshotDataPdf))
    self.define(Procedure("web-client-pdf-snapshot-file", self.webClientSnapshotFilePdf))
    self.define(Procedure("web-client-pdf-snapshot-url", self.webClientSnapshotUrlPdf))
  }
  
  /// Initializations of the library.
  public override func initializations() {
  }
  
  private func webClient(from: Expr) throws -> WebClient {
    guard case .object(let obj) = from, let webClient = obj as? WebClient else {
      throw RuntimeError.type(from, expected: [WebClient.type])
    }
    return webClient
  }
  
  private func cropMode(from: Expr) throws -> WebClient.CropMode {
    switch from {
      case .symbol(self.all):
        return .all
      case .symbol(self.trim):
        return .trim
      case .pair(.symbol(self.inset), .pair(let top, .pair(let right,
                                                           .pair(let bottom, .pair(let left, .null))))):
        return .inset(top: try top.asDouble(coerce: true),
                      right: try right.asDouble(coerce: true),
                      bottom: try bottom.asDouble(coerce: true),
                      left: try left.asDouble(coerce: true))
      case .pair(.symbol(self.insetTrimmed), .pair(let top, .pair(let right,
                                                                  .pair(let bottom, .pair(let left, .null))))):
        return .insetTrimmed(top: try top.asDouble(coerce: true),
                             right: try right.asDouble(coerce: true),
                             bottom: try bottom.asDouble(coerce: true),
                             left: try left.asDouble(coerce: true))
      case .pair(.symbol(self.rect), .pair(let x, .pair(let y,
                                                        .pair(let width, .pair(let height, .null))))),
          .pair(.symbol(self.rect), .pair(.pair(let x, let y), .pair(let width, let height))):
        return .rect(x: try x.asDouble(coerce: true),
                     y: try y.asDouble(coerce: true),
                     width: try width.asDouble(coerce: true),
                     height: try height.asDouble(coerce: true))
      case .pair(.symbol(self.rectTrimmed), .pair(let x, .pair(let y,
                                                               .pair(let width, .pair(let height, .null))))),
          .pair(.symbol(self.rectTrimmed), .pair(.pair(let x, let y), .pair(let width, let height))):
        return .rectTrimmed(x: try x.asDouble(coerce: true),
                            y: try y.asDouble(coerce: true),
                            width: try width.asDouble(coerce: true),
                            height: try height.asDouble(coerce: true))
      case .pair(.pair(let x, let y), .pair(let width, let height)):
        return .rect(x: try x.asDouble(coerce: true),
                     y: try y.asDouble(coerce: true),
                     width: try width.asDouble(coerce: true),
                     height: try height.asDouble(coerce: true))
      default:
        throw RuntimeError.eval(.invalidCropMode, from)
    }
  }
  
  private func makeWebClient(width: Expr, args: Arguments) throws -> Expr {
    guard let (scripts, viewPort, appName, d) = args.optional(.null, .false, .false, .false) else {
      throw RuntimeError.argumentCount(of: "make-web-client",
                                       min: 1,
                                       max: 5,
                                       args: .pair(width, .makeList(args)))
    }
    let width = try width.asDouble(coerce: true)
    let applicationName = appName.isTrue ? try appName.asString() : nil
    let delay: TimeInterval? = d.isTrue ? max(0, try d.asDouble(coerce: true)) : nil
    var userScripts: [(source: String, injection: WKUserScriptInjectionTime, main: Bool)] = []
    switch viewPort {
      case .false:
        let viewport = """
          var meta = document.createElement('meta');
          meta.setAttribute('name', 'viewport');
          meta.setAttribute('content', 'width=\(width), initial-scale=1.0, maximum-scale=1.0, minimum-scale=1.0, user-scalable=no');
          document.getElementsByTagName('head')[0].appendChild(meta);
        """
        userScripts.append((source: viewport, injection: .atDocumentStart, main: true))
      case .true:
        let viewport = """
          var meta = document.createElement('meta');
          meta.setAttribute('name', 'viewport');
          meta.setAttribute('content', 'width=\(width)');
          document.getElementsByTagName('head')[0].appendChild(meta);
        """
        userScripts.append((source: viewport, injection: .atDocumentStart, main: true))
        let transparency = """
          var meta = document.createElement('meta');
          meta.setAttribute('name', 'transparent');
          meta.setAttribute('content', 'true');
          document.getElementsByTagName('head')[0].appendChild(meta);
        """
        userScripts.append((source: transparency, injection: .atDocumentStart, main: false))
      case .null:
        break
      default:
        let viewport = "var meta = document.createElement('meta');\n" +
                       "meta.setAttribute('name', 'viewport');\n" +
                       "meta.setAttribute('content', '\(try viewPort.asString())');\n" +
                       "document.getElementsByTagName('head')[0].appendChild(meta);"
        userScripts.append((source: viewport, injection: .atDocumentStart, main: true))
    }
    var list = scripts
    while case .pair(let script, let rest) = list {
      let userScript: (source: String, injection: WKUserScriptInjectionTime, main: Bool)
      switch script {
        case .string(let str):
          userScript = (source: str as String, injection: .atDocumentEnd, main: true)
        case .pair(let str, .null):
          userScript = (source: try str.asString(), injection: .atDocumentEnd, main: true)
        case .pair(let str, .pair(let beg, .null)):
          userScript = (source: try str.asString(),
                        injection: beg.isTrue ? .atDocumentStart : .atDocumentEnd,
                        main: true)
        case .pair(let str, .pair(let beg, .pair(let all, .null))):
          userScript = (source: try str.asString(),
                        injection: beg.isTrue ? .atDocumentStart : .atDocumentEnd,
                        main: all.isFalse)
        default:
          throw RuntimeError.eval(.invalidUserScript, script)
      }
      userScripts.append(userScript)
      list = rest
    }
    guard list.isNull else {
      throw RuntimeError.type(scripts, expected: [.properListType])
    }
    return DispatchQueue.main.sync {
      let config = WKWebViewConfiguration()
      if appName.isTrue {
        config.applicationNameForUserAgent = applicationName
      }
      config.limitsNavigationsToAppBoundDomains = false
      config.suppressesIncrementalRendering = true
      config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
      config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
      config.setValue(false, forKey: "sward".reversed() + "background".capitalized)
      let contentController = WKUserContentController()
      for (source, injection, main) in userScripts {
        contentController.addUserScript(WKUserScript(source: source,
                                                     injectionTime: injection,
                                                     forMainFrameOnly: main))
      }
      config.userContentController = contentController
      return .object(WebClient(width: width,
                               config: config,
                               delay: delay))
    }
  }
  
  private func isWebClient(expr: Expr) throws -> Expr {
    guard case .object(let obj) = expr, obj is WebClient else {
      return .false
    }
    return .true
  }
  
  private func isWebClientBusy(expr: Expr) throws -> Expr {
    return .makeBoolean(try self.webClient(from: expr).isBusy)
  }
  
  private func fail(future: Future, with error: Error) {
    do {
      _ = try future.setResult(in: context,
                               to: .error(RuntimeError.eval(.unableToReturnResultViaFuture,
                                                            .object(future),
                                                            .error(RuntimeError.os(error)))),
                               raise: true)
    } catch {}
  }
  
  private func webClientSnapshotHtml(expr: Expr,
                                     content: Expr,
                                     third: Expr,
                                     fourth: Expr?,
                                     width: Expr?) throws -> Expr {
    let wc = try self.webClient(from: expr)
    let str = try content.asString()
    let source: WebClient.ContentSource
    let crop: WebClient.CropMode
    let w: CGFloat?
    if let fourth {
      switch third {
        case .false:
          source = .html(content: str, baseURL: nil)
          crop = try self.cropMode(from: fourth)
          w = width == nil ? nil : try width!.asDouble(coerce: true)
        case .string(let baseUrl):
          source = .html(content: str, baseURL: URL(string: baseUrl as String))
          crop = try self.cropMode(from: fourth)
          w = width == nil ? nil : try width!.asDouble(coerce: true)
        default:
          source = .html(content: str, baseURL: nil)
          crop = try self.cropMode(from: third)
          w = try fourth.asDouble(coerce: true)
      }
    } else {
      source = .html(content: str, baseURL: nil)
      crop = try self.cropMode(from: third)
      w = nil
    }
    let result = Future(external: false)
    let context = self.context
    wc.image(source: source, crop: crop, width: w) { res in
      switch res {
        case .success(let image):
          do {
            _ = try result.setResult(in: context, to: .object(image), raise: false)
          } catch let error {
            self.fail(future: result, with: error)
          }
        case .failure(let error):
          self.fail(future: result, with: error)
      }
    }
    return .object(result)
  }
  
  private func webClientSnapshotData(expr: Expr,
                                     data: Expr,
                                     mt: Expr,
                                     args: Arguments) throws -> Expr {
    guard let (enc, base, crp, width) = args.optional(.makeString("UTF-8"),
                                                      .makeString("http://localhost"),
                                                      .symbol(self.all),
                                                      .false) else {
      throw RuntimeError.argumentCount(of: "web-client-snapshot-data",
                                       min: 3,
                                       max: 7,
                                       args: .pair(expr, .pair(data, .pair(mt, .makeList(args)))))
    }
    let wc = try self.webClient(from: expr)
    let baseUrl: URL
    if let url = URL(string: try base.asString()) {
      baseUrl = url
    } else {
      throw RuntimeError.eval(.invalidUrl, base)
    }
    let source: WebClient.ContentSource = .data(data: Data(try data.asByteVector().value),
                                                mimeType: try mt.asString(),
                                                charEnc: try enc.asString(),
                                                baseURL: baseUrl)
    let crop: WebClient.CropMode = try self.cropMode(from: crp)
    let w: CGFloat? = width.isFalse ? nil : try width.asDouble(coerce: true)
    let result = Future(external: false)
    let context = self.context
    wc.image(source: source, crop: crop, width: w) { res in
      switch res {
        case .success(let image):
          do {
            _ = try result.setResult(in: context, to: .object(image), raise: false)
          } catch let error {
            self.fail(future: result, with: error)
          }
        case .failure(let error):
          self.fail(future: result, with: error)
      }
    }
    return .object(result)
  }
  
  private func webClientSnapshotFile(expr: Expr,
                                     path: Expr,
                                     dir: Expr,
                                     crop: Expr?,
                                     width: Expr?) throws -> Expr {
    let wc = try self.webClient(from: expr)
    let url = URL(filePath: self.context.fileHandler.path(try path.asPath(),
                              relativeTo: self.context.evaluator.currentDirectoryPath))
    let dir = URL(filePath: self.context.fileHandler.path(try dir.asPath(),
                              relativeTo: self.context.evaluator.currentDirectoryPath),
                  directoryHint: .isDirectory)
    let source: WebClient.ContentSource = .file(url: url, allowReadAccessTo: dir)
    let crop = (crop == nil) ? .all : try self.cropMode(from: crop!)
    let width: CGFloat? = (width == nil) ? nil : try width!.asDouble(coerce: true)
    let result = Future(external: false)
    let context = self.context
    wc.image(source: source, crop: crop, width: width) { res in
      switch res {
        case .success(let image):
          do {
            _ = try result.setResult(in: context, to: .object(image), raise: false)
          } catch let error {
            self.fail(future: result, with: error)
          }
        case .failure(let error):
          self.fail(future: result, with: error)
      }
    }
    return .object(result)
  }
  
  private func webClientSnapshotUrl(expr: Expr, req: Expr, crop: Expr?, w: Expr?) throws -> Expr {
    let wc = try self.webClient(from: expr)
    let request: URLRequest
    switch req {
      case .object(let obj):
        if let req = obj as? HTTPRequest {
          request = req.request()
        } else {
          fallthrough
        }
      default:
        request = URLRequest(url: try req.asURL())
    }
    let source: WebClient.ContentSource = .url(request: request)
    let crop = (crop == nil) ? .all : try self.cropMode(from: crop!)
    let width: CGFloat? = (w == nil) ? nil : try w!.asDouble(coerce: true)
    let result = Future(external: false)
    let context = self.context
    wc.image(source: source, crop: crop, width: width) { res in
      switch res {
        case .success(let image):
          do {
            _ = try result.setResult(in: context, to: .object(image), raise: false)
          } catch let error {
            self.fail(future: result, with: error)
          }
        case .failure(let error):
          self.fail(future: result, with: error)
      }
    }
    return .object(result)
  }
  
  private func webClientSnapshotHtmlPdf(expr: Expr,
                                        content: Expr,
                                        third: Expr?,
                                        fourth: Expr?) throws -> Expr {
    let wc = try self.webClient(from: expr)
    let str = try content.asString()
    let source: WebClient.ContentSource
    let crop: WebClient.CropMode
    if let fourth {
      switch third {
        case .false:
          source = .html(content: str, baseURL: nil)
          crop = try self.cropMode(from: fourth)
        case .string(let baseUrl):
          source = .html(content: str, baseURL: URL(string: baseUrl as String))
          crop = try self.cropMode(from: fourth)
        default:
          source = .html(content: str, baseURL: nil)
          crop = try self.cropMode(from: third!)
      }
    } else {
      source = .html(content: str, baseURL: nil)
      if let third {
        crop = try self.cropMode(from: third)
      } else {
        crop = .all
      }
    }
    let result = Future(external: false)
    let context = self.context
    wc.pdf(source: source, crop: crop, transparent: true) { res in
      switch res {
        case .success(let data):
          do {
            _ = try result.setResult(in: context,
                                     to: BytevectorLibrary.bytevector(from: data),
                                     raise: false)
          } catch let error {
            self.fail(future: result, with: error)
          }
        case .failure(let error):
          self.fail(future: result, with: error)
      }
    }
    return .object(result)
  }
  
  private func webClientSnapshotDataPdf(expr: Expr,
                                        data: Expr,
                                        mt: Expr,
                                        args: Arguments) throws -> Expr {
    guard let (enc, base, crp) = args.optional(.makeString("UTF-8"),
                                               .makeString("http://localhost"),
                                               .symbol(self.all)) else {
      throw RuntimeError.argumentCount(of: "web-client-pdf-snapshot-data",
                                       min: 3,
                                       max: 6,
                                       args: .pair(expr, .pair(data, .pair(mt, .makeList(args)))))
    }
    let wc = try self.webClient(from: expr)
    let baseUrl: URL
    if let url = URL(string: try base.asString()) {
      baseUrl = url
    } else {
      throw RuntimeError.eval(.invalidUrl, base)
    }
    let source: WebClient.ContentSource = .data(data: Data(try data.asByteVector().value),
                                                mimeType: try mt.asString(),
                                                charEnc: try enc.asString(),
                                                baseURL: baseUrl)
    let crop: WebClient.CropMode = try self.cropMode(from: crp)
    let result = Future(external: false)
    let context = self.context
    wc.pdf(source: source, crop: crop, transparent: true) { res in
      switch res {
        case .success(let data):
          do {
            _ = try result.setResult(in: context,
                                     to: BytevectorLibrary.bytevector(from: data),
                                     raise: false)
          } catch let error {
            self.fail(future: result, with: error)
          }
        case .failure(let error):
          self.fail(future: result, with: error)
      }
    }
    return .object(result)
  }
  
  private func webClientSnapshotFilePdf(expr: Expr,
                                        path: Expr,
                                        dir: Expr,
                                        crop: Expr?) throws -> Expr {
    let wc = try self.webClient(from: expr)
    let url = URL(filePath: self.context.fileHandler.path(try path.asPath(),
                              relativeTo: self.context.evaluator.currentDirectoryPath))
    let dir = URL(filePath: self.context.fileHandler.path(try dir.asPath(),
                              relativeTo: self.context.evaluator.currentDirectoryPath),
                  directoryHint: .isDirectory)
    let source: WebClient.ContentSource = .file(url: url, allowReadAccessTo: dir)
    let crop = (crop == nil) ? .all : try self.cropMode(from: crop!)
    let result = Future(external: false)
    let context = self.context
    wc.pdf(source: source, crop: crop, transparent: true) { res in
      switch res {
        case .success(let data):
          do {
            _ = try result.setResult(in: context,
                                     to: BytevectorLibrary.bytevector(from: data),
                                     raise: false)
          } catch let error {
            self.fail(future: result, with: error)
          }
        case .failure(let error):
          self.fail(future: result, with: error)
      }
    }
    return .object(result)
  }
  
  private func webClientSnapshotUrlPdf(expr: Expr, req: Expr, crop: Expr?) throws -> Expr {
    let wc = try self.webClient(from: expr)
    let request: URLRequest
    switch req {
      case .object(let obj):
        if let req = obj as? HTTPRequest {
          request = req.request()
        } else {
          fallthrough
        }
      default:
        request = URLRequest(url: try req.asURL())
    }
    let source: WebClient.ContentSource = .url(request: request)
    let crop = (crop == nil) ? .all : try self.cropMode(from: crop!)
    let result = Future(external: false)
    let context = self.context
    wc.pdf(source: source, crop: crop, transparent: true) { res in
      switch res {
        case .success(let data):
          do {
            _ = try result.setResult(in: context,
                                     to: BytevectorLibrary.bytevector(from: data),
                                     raise: false)
          } catch let error {
            self.fail(future: result, with: error)
          }
        case .failure(let error):
          self.fail(future: result, with: error)
      }
    }
    return .object(result)
  }
}

public class WebClient: NSObject, WKNavigationDelegate, CustomExpr {
  public static let type = Type.objectType(Symbol(uninterned: "web-client"))
  
  public enum ContentSource {
    case html(content: String, baseURL: URL?)
    case data(data: Data, mimeType: String, charEnc: String, baseURL: URL)
    case file(url: URL, allowReadAccessTo: URL)
    case url(request: URLRequest)
  }
  
  public enum CropMode {
    case all
    case trim
    case inset(top: CGFloat, right: CGFloat, bottom: CGFloat, left: CGFloat)
    case insetTrimmed(top: CGFloat, right: CGFloat, bottom: CGFloat, left: CGFloat)
    case rect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)
    case rectTrimmed(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)
    case compute(proc: (WKWebView, Context) -> CGRect)
    
    func rect(in webView: WKWebView, context: Context) -> CGRect {
      switch self {
        case .all:
          return webView.bounds
        case .trim:
          return context.rect(in: webView)
        case .insetTrimmed(top: let top, right: let right, bottom: let bottom, left: let left):
          if case .parameters(left: let x, top: let y, width: let w, height: let h) = context {
            return CGRect(x: x + left,
                          y: y + top,
                          width: max(0.0, w - x - left - right),
                          height: max(0.0, h - 2 * y - top - bottom))
          } else {
            fallthrough
          }
        case .inset(top: let top, right: let right, bottom: let bottom, left: let left):
          return CGRect(x: webView.bounds.origin.x + left,
                        y: webView.bounds.origin.y + top,
                        width: max(0.0, webView.bounds.width - webView.bounds.origin.x - left - right),
                        height: max(0.0, webView.bounds.height - webView.bounds.origin.y - top - bottom))
        case .rectTrimmed(x: let x, y: let y, width: let width, height: let height):
          if case .parameters(left: let left, top: let top, width: _, height: _) = context {
            return CGRect(x: x + left, y: y + top, width: max(0.0, width), height: max(0.0, height))
          } else {
            fallthrough
          }
        case .rect(x: let x, y: let y, width: let width, height: let height):
          return CGRect(x: x, y: y, width: max(0.0, width), height: max(0.0, height))
        case .compute(proc: let proc):
          return proc(webView, context)
      }
    }
  }
  
  private enum ExportMethod {
    case image(crop: CropMode, width: CGFloat?, handler: (Result<NativeImage, Error>) -> Void)
    case pdf(crop: CropMode, transparent: Bool, handler: (Result<Data, Error>) -> Void)
  }
  
  public enum ExportError: Error {
    case noResponse
    case simultaneousUse
    case unableToCreatePng
    case unableToCreatePdf
  }
  
  public enum Context {
    case parameters(left: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat)
    case error(any Error)
    
    func rect(in webView: WKWebView) -> CGRect {
      switch self {
        case .parameters(left: let left, top: let top, width: let width, height: let height):
          return CGRect(x: left, y: top, width: width - left, height: height - 2 * top)
        case .error(_):
          return webView.bounds
      }
    }
  }
  
  private let webView: WKWebView
  private let width: CGFloat
  private var delay: TimeInterval?
  private var method: ExportMethod?
  private var queue: [(ContentSource, ExportMethod)]
  
  public init(width: CGFloat,
              config: WKWebViewConfiguration = WKWebViewConfiguration(),
              delay: TimeInterval? = nil) {
    self.width = width
    self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 0),
                             configuration: config)
    #if os(iOS) || os(watchOS) || os(tvOS)
    self.webView.setMinimumViewportInset(.zero, maximumViewportInset: .zero)
    #elseif os(macOS)
    self.webView.setValue(false, forKey: "sward".reversed() + "background".capitalized)
    self.webView.setMinimumViewportInset(NSEdgeInsetsZero, maximumViewportInset: NSEdgeInsetsZero)
    #endif
    self.method = nil
    self.queue = []
    self.delay = delay
    super.init()
    self.webView.navigationDelegate = self
  }
  
  public var type: Type {
    return Self.type
  }
  
  public var tagString: String {
    let res = "web-client \(self.identityString): width=\(self.width)"
    return delay == nil ? res : (res + ", delay=\(self.delay!)")
  }
  
  public var identity: UInt {
    return UInt(bitPattern: ObjectIdentifier(self))
  }
  
  public var identityString: String {
    return String(self.identity, radix: 16)
  }
  
  public func equals(to expr: Expr) -> Bool {
    guard case .object(let obj) = expr,
          let other = obj as? WebClient else {
      return false
    }
    return self === other
  }
  
  public func unpack(in context: LispKit.Context) -> Exprs {
    return [.makeString(self.identityString),
            .makeNumber(self.width),
            delay == nil ? .false : .makeNumber(self.delay!)]
  }
  
  private func nextSnapshot() {
    if self.queue.isEmpty {
      self.method = nil
    } else {
      let (source, method) = self.queue.removeFirst()
      self.method = method
      self.webView.frame = CGRect(x: 0, y: 0, width: self.width, height: 0)
      switch source {
        case .html(content: let content, baseURL: let baseURL):
          self.webView.loadHTMLString(content, baseURL: baseURL)
        case .data(data: let data, mimeType: let mime, charEnc: let enc, baseURL: let baseURL):
          self.webView.load(data, mimeType: mime, characterEncodingName: enc, baseURL: baseURL)
        case .file(url: let url, allowReadAccessTo: let allowReadAccessTo):
          self.webView.loadFileURL(url, allowingReadAccessTo: allowReadAccessTo)
        case .url(request: let request):
          self.webView.load(request)
      }
    }
  }
  
  private func configure(source: ContentSource, method: ExportMethod) {
    return Self.onMainThread {
      if self.method == nil {
        self.queue.append((source, method))
        self.nextSnapshot()
      } else {
        self.queue.append((source, method))
      }
    }
  }
  
  public var isBusy: Bool {
    return Self.onMainThread {
      return self.method != nil
    }
  }
  
  public func pdf(source: ContentSource,
                  crop: CropMode = .all,
                  transparent: Bool = true,
                  handler: @escaping (Result<Data, Error>) -> Void) {
    self.configure(source: source,
                   method: .pdf(crop: crop, transparent: transparent, handler: { result in
                     handler(result)
                     self.nextSnapshot()
                   }))
  }
  
  public func image(source: ContentSource,
                    crop: CropMode = .all,
                    width: CGFloat? = nil,
                    handler: @escaping (Result<NativeImage, Error>) -> Void) {
    self.configure(source: source,
                   method: .image(crop: crop, width: width, handler: { result in
                     handler(result)
                     self.nextSnapshot()
                   }))
  }
  
  public func webView(_ webView: WKWebView, didFail: WKNavigation!, withError error: any Error) {
    switch self.method {
      case .none:
        break
      case .pdf(crop: _, transparent: _, handler: let completionHandler):
        completionHandler(.failure(error))
      case .image(crop: _, width: _, handler: let completionHandler):
        completionHandler(.failure(error))
    }
  }
  
  public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    // Don't do anything
  }
  
  public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    let callback = { (context: Context) in
      Self.doOnMainThread {
        switch self.method {
          case .none:
            break
          case .image(crop: let crop, width: let widthOverride, handler: let completionHandler):
            switch context {
              case .error(let error):
                completionHandler(.failure(error))
              case .parameters(left: _, top: _, width: _, height: _):
                let snapshotConfig = WKSnapshotConfiguration()
                snapshotConfig.rect = crop.rect(in: webView, context: context)
                snapshotConfig.afterScreenUpdates = false
                if let widthOverride {
                  snapshotConfig.snapshotWidth = NSNumber(value: max(0.0, widthOverride).native)
                }
                webView.takeSnapshot(with: snapshotConfig) { image, error in
                  if let image {
                    completionHandler(.success(NativeImage(image)))
                  } else {
                    completionHandler(.failure(error ?? ExportError.noResponse))
                  }
                }
            }
          case .pdf(crop: let crop, transparent: _, handler: let completionHandler):
            switch context {
              case .error(let error):
                completionHandler(.failure(error))
              case .parameters(left: _, top: _, width: _, height: _):
                let pdfConfig = WKPDFConfiguration()
                if case .all = crop {
                  pdfConfig.rect = nil
                } else {
                  pdfConfig.rect = crop.rect(in: webView, context: context)
                }
                webView.createPDF(configuration: pdfConfig, completionHandler: completionHandler)
            }
        }
      }
    }
    self.executeDelayed {
      webView.evaluateJavaScript("document.readyState", completionHandler: { (complete, error) in
        if complete != nil {
          let dimensions = PageDimensions()
          webView.evaluateJavaScript("document.body.children[0].offsetTop",
                                     completionHandler: dimensions.setTop)
          webView.evaluateJavaScript("document.body.children[0].offsetLeft",
                                     completionHandler: dimensions.setLeft)
          webView.evaluateJavaScript("document.body.scrollWidth",
                                     completionHandler: dimensions.setWidth)
          webView.evaluateJavaScript("document.body.scrollHeight",
                                     completionHandler: { (height, error) in
            do {
              if let h = height as? CGFloat {
                let (left, top, width) = try dimensions.dimensions
                webView.frame = CGRect(x: 0,
                                       y: 0,
                                       width: webView.frame.width,
                                       height: h)
                callback(.parameters(left: left, top: top, width: width, height: h))
              } else {
                callback(.error(error ?? ExportError.noResponse))
              }
            } catch let error {
              callback(.error(error))
            }
          })
        } else {
          callback(.error(error ?? ExportError.noResponse))
        }
      })
    }
  }
  
  private func executeDelayed(_ execute: @escaping () -> Void) {
    if let delay {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: execute)
    } else {
      execute()
    }
  }
  
  private static func doOnMainThread(_ execute: @escaping () -> Void) {
    if Thread.isMainThread {
      execute()
    } else {
      DispatchQueue.main.async {
        execute()
      }
    }
  }
  
  private static func onMainThread<T>(_ execute: @escaping () -> T) -> T {
    if Thread.isMainThread {
      return execute()
    } else {
      return DispatchQueue.main.sync {
        return execute()
      }
    }
  }
}

internal class PageDimensions {
  private let condition: NSCondition = NSCondition()
  private var leftValue: CGFloat? = nil
  private var topValue: CGFloat? = nil
  private var widthValue: CGFloat? = nil
  private var errorValue: (any Error)? = nil
  
  internal var dimensions: (left: CGFloat, top: CGFloat, width: CGFloat) {
    get throws {
      self.condition.lock()
      defer { self.condition.unlock() }
      while (((self.widthValue == nil) || (self.leftValue == nil) || (self.topValue == nil)) &&
             (self.errorValue == nil)) {
        self.condition.wait()
      }
      if let errorValue {
        throw errorValue
      }
      return (left: self.leftValue!, top: self.topValue!, width: self.widthValue!)
    }
  }
  
  internal func setLeft(_ newValue: Any, _ error: (any Error)?) {
    self.condition.lock()
    defer { self.condition.unlock() }
    if let value = newValue as? CGFloat {
      self.leftValue = value
    } else {
      self.errorValue = error ?? WebClient.ExportError.noResponse
    }
    self.condition.broadcast()
  }
  
  internal func setTop(_ newValue: Any, _ error: (any Error)?) {
    self.condition.lock()
    defer { self.condition.unlock() }
    if let value = newValue as? CGFloat {
      self.topValue = value
    } else {
      self.errorValue = error ?? WebClient.ExportError.noResponse
    }
    self.condition.broadcast()
  }
  
  internal func setWidth(_ newValue: Any, _ error: (any Error)?) {
    self.condition.lock()
    defer { self.condition.unlock() }
    if let value = newValue as? CGFloat {
      self.widthValue = value
    } else {
      self.errorValue = error ?? WebClient.ExportError.noResponse
    }
    self.condition.broadcast()
  }
}
