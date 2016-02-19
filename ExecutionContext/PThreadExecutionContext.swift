//===--- PThreadExecutionContext.swift ------------------------------------------------------===//
//Copyright (c) 2016 Daniel Leping (dileping)
//
//Licensed under the Apache License, Version 2.0 (the "License");
//you may not use this file except in compliance with the License.
//You may obtain a copy of the License at
//
//http://www.apache.org/licenses/LICENSE-2.0
//
//Unless required by applicable law or agreed to in writing, software
//distributed under the License is distributed on an "AS IS" BASIS,
//WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//See the License for the specific language governing permissions and
//limitations under the License.
//===----------------------------------------------------------------------===//





//////////////////////////////////////////////////////////////////////////
//This file is a temporary solution, just until Dispatch will run on Mac//
//////////////////////////////////////////////////////////////////////////
#if os(Linux)
    
    import Foundation
    import CoreFoundation
    import Result
    
    private func thread_proc(pm: UnsafeMutablePointer<Void>) -> UnsafeMutablePointer<Void> {
        let pthread = Unmanaged<PThread>.fromOpaque(COpaquePointer(pm)).takeRetainedValue()
        pthread.task?()
        return nil
    }

    private extension NSString {
        var cfString: CFString { return unsafeBitCast(self, CFString.self) }
    }
    
    private class PThread {
        let thread: UnsafeMutablePointer<pthread_t>
        let task:SafeTask?
        
        init(task:SafeTask? = nil) {
            self.task = task
            self.thread = UnsafeMutablePointer<pthread_t>.alloc(1)
        }
        deinit {
            self.thread.destroy()
            self.thread.dealloc(1)
        }
        
        func start() {
            pthread_create(thread, nil, thread_proc, UnsafeMutablePointer<Void>(Unmanaged.passRetained(self).toOpaque()))
        }
    }

    private func sourceMain(rls: UnsafeMutablePointer<Void>) -> Void {
            let runLoopSource = Unmanaged<RunLoopSource>.fromOpaque(COpaquePointer(rls)).takeUnretainedValue()
            runLoopSource.runTask()
    }

    private func sourceRelease(rls: UnsafePointer<Void>) -> Void {
        Unmanaged<RunLoopSource>.fromOpaque(COpaquePointer(rls)).release()
    }

    private class RunLoopSource {
        private var cfSource:CFRunLoopSource? = nil
        private let task:SafeTask?

        init(task: SafeTask? = nil) {
            self.task = task
        }

        deinit {
            if let s = cfSource {
                if CFRunLoopSourceIsValid(s) { CFRunLoopSourceInvalidate(s) }
            }
        }

        private func runTask() {
            task?()
            if let s = cfSource {
                if CFRunLoopSourceIsValid(s) { CFRunLoopSourceInvalidate(s) }
                cfSource = nil
            }
        }

        func addToRunLoop(runLoop:CFRunLoop, mode: CFString) {
            if cfSource == nil {
                if task != nil {
                    var source = CFRunLoopSourceContext(
                        version: 0,
                        info: UnsafeMutablePointer<Void>(Unmanaged.passRetained(self).toOpaque()),
                        retain: nil,
                        release: sourceRelease,
                        copyDescription: nil,
                        equal: nil,
                        hash: nil,
                        schedule: nil,
                        cancel: nil,
                        perform: sourceMain
                    )
                    self.cfSource = CFRunLoopSourceCreate(nil, 0, &source)
                } else {
                    return
                }
            }
            
            CFRunLoopAddSource(runLoop, cfSource!, mode)
            CFRunLoopSourceSignal(cfSource!)
        }
    }
    
    private extension ExecutionContextType {
        func syncThroughAsync<ReturnType>(task:() throws -> ReturnType) throws -> ReturnType {
            var result:Result<ReturnType, AnyError>?
            
            let cond = NSCondition()
            cond.lock()

            async {
                result = materialize(task)
                cond.signal()
            }
            
            cond.wait()
            cond.unlock()
            
            return try result!.dematerializeAnyError()
        }
    }
    
    private class ParallelContext : ExecutionContextBase, ExecutionContextType {
        func async(task:SafeTask) {
            let thread = PThread(task: task)
            thread.start()
        }
        
        func sync<ReturnType>(task:() throws -> ReturnType) throws -> ReturnType {
            return try syncThroughAsync(task)
        }
    }
    
    private class SerialContext : ExecutionContextBase, ExecutionContextType {
        private let rl:CFRunLoop!
        private static let defaultMode = "kCFRunLoopDefaultMode".bridge().cfString
        
        override init() {
            var runLoop:CFRunLoop?
            let cond = NSCondition()
            cond.lock()
            let thread = PThread(task: {
                runLoop = CFRunLoopGetCurrent()
                cond.signal()
                SerialContext.defaultLoop()
            })
            thread.start()
            cond.wait()
            cond.unlock()
            self.rl = runLoop!
        }
        
        init(runLoop:CFRunLoop!) {
            rl = runLoop
        }

        deinit {
            CFRunLoopStop(rl)
        }
        
        static func defaultLoop() {
            while CFRunLoopRunInMode(defaultMode, 0, true) != Int32(kCFRunLoopRunStopped) {}
        }

        private func performRunLoopSource(rls: RunLoopSource) {
            rls.addToRunLoop(rl, mode: SerialContext.defaultMode)
        }
        
        func async(task:SafeTask) {
            performRunLoopSource(RunLoopSource(task:task))
        }
        
        func sync<ReturnType>(task:() throws -> ReturnType) throws -> ReturnType {
            if rl === CFRunLoopGetCurrent() {
                return try task()
            } else {
                return try syncThroughAsync(task)
            }
        }
    }
    
    public class PThreadExecutionContext : ExecutionContextBase, ExecutionContextType, DefaultExecutionContextType {
        let inner:ExecutionContextType
        
        init(inner:ExecutionContextType) {
            self.inner = inner
        }
        
        public required init(kind:ExecutionContextKind) {
            switch kind {
            case .Serial: inner = SerialContext()
            case .Parallel: inner = ParallelContext()
            }
        }
        
        public func async(task:SafeTask) {
            inner.async(task)
        }
        
        public func sync<ReturnType>(task:() throws -> ReturnType) throws -> ReturnType {
            return try inner.sync(task)
        }
        
        public static let main:ExecutionContextType = PThreadExecutionContext(inner: SerialContext(runLoop: CFRunLoopGetMain()))
        public static let global:ExecutionContextType = PThreadExecutionContext(kind: .Parallel)
    }

#endif