//
//  main.swift
//  LispKitRepl
//
//  Created by Matthias Zenger on 14/04/2016.
//  Copyright © 2016-2020 ObjectHub. All rights reserved.
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
import LispKit
import LispKitTools

let repl = LispKitRepl(name: AppInfo.name,
                       version: AppInfo.version,
                       build: AppInfo.buildAnnotation,
                       copyright: AppInfo.copyright,
                       prompt: AppInfo.prompt)
let features = ["repl"]

guard repl.flagsValid() else {
  exit(1)
}

if repl.shouldRunRepl() {
  #if SPM
    guard repl.configurationSuccessfull(implementationName: "LispKit",
                                        implementationVersion: "1.9.0",
                                        includeInternalResources: false,
                                        defaultDocDirectory: "LispKit",
                                        features: features) else {
      exit(1)
    }
  #else
    guard repl.configurationSuccessfull(features: features) else {
      exit(1)
    }
  #endif
  guard repl.run() else {
    exit(1)
  }
}

repl.release()
exit(0)
